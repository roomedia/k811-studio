import Foundation
import IOKit.hid

public struct K811DeviceInfo: Codable, Equatable, Identifiable, Sendable {
    public let vendorID: Int
    public let productID: Int
    public let product: String
    public let manufacturer: String
    public let serialNumber: String
    public let locationID: Int
    public let usagePage: Int
    public let usage: Int
    public let maxInputReportSize: Int
    public let maxOutputReportSize: Int

    public var id: String {
        "\(vendorID):\(productID):\(locationID):\(usagePage):\(usage)"
    }
}

public enum K811HIDError: LocalizedError {
    case deviceNotFound
    case deviceOpen(IOReturn)
    case notConnected
    case invalidOutputReportSize(Int)
    case send(IOReturn)
    case receive(IOReturn)
    case receiveTimeout

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "K811 vendor 인터페이스(5566:000A, Usage Page FF00)를 찾지 못했습니다."
        case let .deviceOpen(code):
            "K811 vendor 인터페이스를 열지 못했습니다 (\(Self.hex(code)))."
        case .notConnected:
            "K811이 연결되어 있지 않습니다."
        case let .invalidOutputReportSize(size):
            "예상한 64바이트 output report가 아닙니다 (실제: \(size))."
        case let .send(code):
            "K811 report 전송에 실패했습니다 (\(Self.hex(code)))."
        case let .receive(code):
            "K811 report 수신에 실패했습니다 (\(Self.hex(code)))."
        case .receiveTimeout:
            "K811 응답을 제한 시간 안에 받지 못했습니다."
        }
    }

    private static func hex(_ code: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: code))
    }
}

public final class K811HIDTransport {
    public static let vendorID = 0x5566
    public static let productID = 0x000A
    public static let vendorUsagePage = 0xFF00
    public static let vendorUsage = 0x0001

    private let manager: IOHIDManager
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private let collector = K811ReportCollector()
    private var device: IOHIDDevice?
    private var reportRunLoop: CFRunLoop?
    private var reportRunLoopMode: CFRunLoopMode?

    public init() {
        reportBuffer = .allocate(capacity: K811Packet.length)
        reportBuffer.initialize(repeating: 0, count: K811Packet.length)
        manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )

        let match: [String: Any] = [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    }

    deinit {
        disconnect()
        reportBuffer.deinitialize(count: K811Packet.length)
        reportBuffer.deallocate()
    }

    @discardableResult
    public func connect() throws -> K811DeviceInfo {
        if let device {
            return makeInfo(for: device)
        }

        guard
            let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
            let selected = devices.first(where: isVendorInterface)
        else {
            throw K811HIDError.deviceNotFound
        }

        let info = makeInfo(for: selected)
        guard info.maxOutputReportSize == K811Packet.length else {
            throw K811HIDError.invalidOutputReportSize(info.maxOutputReportSize)
        }

        let result = IOHIDDeviceOpen(
            selected,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard result == kIOReturnSuccess else {
            throw K811HIDError.deviceOpen(result)
        }

        device = selected
        return info
    }

    public func disconnect() {
        if let device {
            if let reportRunLoop, let reportRunLoopMode {
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    reportBuffer,
                    K811Packet.length,
                    nil,
                    nil
                )
                IOHIDDeviceUnscheduleFromRunLoop(
                    device,
                    reportRunLoop,
                    reportRunLoopMode.rawValue
                )
            }
            self.reportRunLoop = nil
            self.reportRunLoopMode = nil
            collector.runLoop = nil
            collector.report = nil
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.device = nil
        }
    }

    public func send(_ packet: K811Packet) throws {
        guard let device else {
            throw K811HIDError.notConnected
        }

        let result = packet.bytes.withUnsafeBytes { rawBuffer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                0,
                rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
                packet.bytes.count
            )
        }

        guard result == kIOReturnSuccess else {
            throw K811HIDError.send(result)
        }
    }

    public func request(
        _ packet: K811Packet,
        timeout: TimeInterval = 1
    ) throws -> [UInt8] {
        guard let device else {
            throw K811HIDError.notConnected
        }

        try ensureReportReception(for: device)
        guard reportRunLoop != nil, let runLoopMode = reportRunLoopMode else {
            throw K811HIDError.receiveTimeout
        }

        collector.result = kIOReturnSuccess
        collector.report = nil
        try send(packet)

        let deadline = Date().addingTimeInterval(timeout)
        while collector.report == nil, Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            CFRunLoopRunInMode(
                runLoopMode,
                min(max(remaining, 0), 0.05),
                true
            )
        }

        if collector.result != kIOReturnSuccess {
            throw K811HIDError.receive(collector.result)
        }
        guard let report = collector.report else {
            throw K811HIDError.receiveTimeout
        }
        return report
    }

    private func ensureReportReception(for device: IOHIDDevice) throws {
        if reportRunLoop != nil {
            return
        }
        guard let runLoop = CFRunLoopGetCurrent(),
              let runLoopMode = CFRunLoopMode.defaultMode
        else {
            throw K811HIDError.receiveTimeout
        }

        collector.runLoop = runLoop
        let context = Unmanaged.passUnretained(collector).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            K811Packet.length,
            k811InputReportCallback,
            context
        )
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, runLoopMode.rawValue)
        reportRunLoop = runLoop
        reportRunLoopMode = runLoopMode
    }

    private func isVendorInterface(_ device: IOHIDDevice) -> Bool {
        intProperty(kIOHIDPrimaryUsagePageKey, of: device) == Self.vendorUsagePage
            && intProperty(kIOHIDPrimaryUsageKey, of: device) == Self.vendorUsage
            && intProperty(kIOHIDMaxInputReportSizeKey, of: device) == K811Packet.length
            && intProperty(kIOHIDMaxOutputReportSizeKey, of: device) == K811Packet.length
    }

    private func makeInfo(for device: IOHIDDevice) -> K811DeviceInfo {
        K811DeviceInfo(
            vendorID: intProperty(kIOHIDVendorIDKey, of: device),
            productID: intProperty(kIOHIDProductIDKey, of: device),
            product: stringProperty(kIOHIDProductKey, of: device),
            manufacturer: stringProperty(kIOHIDManufacturerKey, of: device),
            serialNumber: stringProperty(kIOHIDSerialNumberKey, of: device),
            locationID: intProperty(kIOHIDLocationIDKey, of: device),
            usagePage: intProperty(kIOHIDPrimaryUsagePageKey, of: device),
            usage: intProperty(kIOHIDPrimaryUsageKey, of: device),
            maxInputReportSize: intProperty(kIOHIDMaxInputReportSizeKey, of: device),
            maxOutputReportSize: intProperty(kIOHIDMaxOutputReportSizeKey, of: device)
        )
    }

    private func intProperty(_ key: String, of device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private func stringProperty(_ key: String, of device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, key as CFString) as? String ?? ""
    }
}

private final class K811ReportCollector {
    var runLoop: CFRunLoop?
    var result: IOReturn = kIOReturnSuccess
    var report: [UInt8]?
}

private func k811InputReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context else { return }
    let collector = Unmanaged<K811ReportCollector>
        .fromOpaque(context)
        .takeUnretainedValue()
    collector.result = result

    if reportLength > 0 {
        collector.report = Array(
            UnsafeBufferPointer(start: report, count: reportLength)
        )
    }
    if let runLoop = collector.runLoop {
        CFRunLoopStop(runLoop)
    }
}
