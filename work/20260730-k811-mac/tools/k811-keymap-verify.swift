import Darwin
import CoreGraphics
import Foundation
import IOKit.hid

private let macroPulseHoldMilliseconds: UInt16 = 50
private let f13Usage: UInt8 = 0x68
private let f13CGKeyCode: Int64 = 105

private enum VerifierError: LocalizedError {
    case invalidArguments
    case invalidImageLength(Int)
    case invalidPhysicalSlot(Int)
    case baselineNotZero(Int)
    case unexpectedRecord(stage: String, bytes: [UInt8])
    case rawObserverOpen(IOReturn)
    case rawKeyTimeout
    case rawPulseTimeout
    case unexpectedPulseKeyDownCount(Int)
    case cgEventTapUnavailable
    case cgEventRunLoopSourceUnavailable
    case cgEventPulseTimeout
    case unexpectedCGEventPulse(downCount: Int, upCount: Int, autorepeatCount: Int)
    case unexpectedRawUsage(expected: UInt32, observed: UInt32)
    case shortResponse(Int)
    case unexpectedResponse([UInt8])

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "usage: k811-keymap-verify backup-only [backup-path] | apply-slot-key[-external] <slot> <usage> [seconds] [backup-path] | apply-slot-macro-pulse[-external|-cgevent] <slot> <usage> [seconds] [keymap-backup-path] [macro-image-path] | inspect-macro-framing | inspect-cgevent-observer | inspect-cgevent-pulse-state | apply-esc-b [seconds] [backup-path] | restore-zero"
        case let .invalidImageLength(length):
            "write image must be 952 bytes, got \(length)"
        case let .invalidPhysicalSlot(slot):
            "physical slot is outside the writable keymap payload: \(slot)"
        case let .baselineNotZero(count):
            "refusing mutation: readable baseline contains \(count) non-zero bytes"
        case let .unexpectedRecord(stage, bytes):
            "\(stage) record mismatch: \(hex(bytes))"
        case let .rawObserverOpen(code):
            "raw K811 keyboard observer open failed: 0x\(String(format: "%08X", UInt32(bitPattern: code)))"
        case .rawKeyTimeout:
            "no raw K811 key-down was observed before timeout"
        case .rawPulseTimeout:
            "no complete raw K811 key-down/key-up pulse was observed before timeout"
        case let .unexpectedPulseKeyDownCount(count):
            "expected exactly one key-down during the macro pulse probe, observed \(count)"
        case .cgEventTapUnavailable:
            "CGEvent listen-only tap is unavailable"
        case .cgEventRunLoopSourceUnavailable:
            "CGEvent run-loop source creation failed"
        case .cgEventPulseTimeout:
            "no complete F13 CGEvent key-down/key-up pulse was observed before timeout"
        case let .unexpectedCGEventPulse(downCount, upCount, autorepeatCount):
            "expected one non-repeating F13 CGEvent pulse; observed down=\(downCount), up=\(upCount), autorepeat=\(autorepeatCount)"
        case let .unexpectedRawUsage(expected, observed):
            "overlay did not produce expected raw usage 0x\(String(format: "%02X", expected)); observed 0x\(String(format: "%02X", observed))"
        case let .shortResponse(length):
            "response is too short: \(length)"
        case let .unexpectedResponse(bytes):
            "unexpected response: \(hex(bytes))"
        }
    }
}

private let writePageCount = 17
private let writePageSize = 56
private let writeImageLength = writePageCount * writePageSize
private let finalWritePageSize = 40
private let writePayloadLength = (writePageCount - 1) * writePageSize + finalWritePageSize
private let escapeToB: [UInt8] = [0x10, 0x00, 0x05, 0x00]

private struct RawKeyEvent {
    let usage: UInt32
    let timestamp: UInt64
    let locationID: Int
}

private struct RawKeyTransition {
    let event: RawKeyEvent
    let value: Int
}

private final class K811RawKeyObserver {
    private let manager: IOHIDManager
    private(set) var event: RawKeyEvent?
    private(set) var transitions: [RawKeyTransition] = []
    private var runLoop: CFRunLoop?

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: K811HIDTransport.vendorID,
            kIOHIDProductIDKey: K811HIDTransport.productID,
            kIOHIDPrimaryUsagePageKey: 0x01,
            kIOHIDPrimaryUsageKey: 0x06,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    }

    func start() throws {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, k811RawValueCallback, context)
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: 0x07] as CFDictionary)
        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            throw VerifierError.rawKeyTimeout
        }
        IOHIDManagerScheduleWithRunLoop(manager, currentRunLoop, CFRunLoopMode.defaultMode.rawValue)
        runLoop = currentRunLoop
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw VerifierError.rawObserverOpen(result)
        }
        let matchedCount = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
        emit(["event": "raw-observer-ready", "matchedDevices": matchedCount])
    }

    func waitForKeyDown(seconds: Int) -> RawKeyEvent? {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while event == nil, Date() < deadline {
            CFRunLoopRunInMode(
                CFRunLoopMode.defaultMode,
                min(max(deadline.timeIntervalSinceNow, 0), 0.05),
                true
            )
        }
        return event
    }

    func waitForKeyPulse(usage: UInt32, seconds: Int) -> (down: RawKeyEvent, up: RawKeyEvent)? {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            var down: RawKeyEvent?
            for transition in transitions where transition.event.usage == usage {
                if transition.value == 1, down == nil {
                    down = transition.event
                } else if transition.value == 0, let down {
                    return (down, transition.event)
                }
            }
            CFRunLoopRunInMode(
                CFRunLoopMode.defaultMode,
                min(max(deadline.timeIntervalSinceNow, 0), 0.05),
                true
            )
        }
        return nil
    }

    func settle(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            CFRunLoopRunInMode(
                CFRunLoopMode.defaultMode,
                min(max(deadline.timeIntervalSinceNow, 0), 0.05),
                true
            )
        }
    }

    func keyDownCount(for usage: UInt32) -> Int {
        transitions.filter { $0.event.usage == usage && $0.value == 1 }.count
    }

    func reset() {
        event = nil
        transitions.removeAll(keepingCapacity: true)
    }

    func stop() {
        if let runLoop {
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }
        runLoop = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    fileprivate func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let integerValue = IOHIDValueGetIntegerValue(value)
        guard
            usagePage == 0x07,
            usage <= 0xFF,
            integerValue == 0 || integerValue == 1
        else { return }

        let device = IOHIDElementGetDevice(element)
        let locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let rawEvent = RawKeyEvent(
            usage: usage,
            timestamp: IOHIDValueGetTimeStamp(value),
            locationID: locationID
        )
        transitions.append(RawKeyTransition(event: rawEvent, value: integerValue))
        if event == nil, integerValue == 1 {
            event = rawEvent
        }
    }
}

private func k811RawValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<K811RawKeyObserver>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(value)
}

private struct CGEventPulse {
    let downTimestamp: UInt64
    let upTimestamp: UInt64
}

private final class F13CGEventPulseObserver {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private(set) var keyDownCount = 0
    private(set) var keyUpCount = 0
    private(set) var autorepeatCount = 0
    private var firstDownTimestamp: UInt64?
    private var firstUpTimestamp: UInt64?

    func start() throws {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: k811F13CGEventCallback,
            userInfo: context
        ) else {
            throw VerifierError.cgEventTapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw VerifierError.cgEventRunLoopSourceUnavailable
        }

        let runLoop = CFRunLoopGetCurrent()
        self.tap = tap
        self.source = source
        self.runLoop = runLoop
        CFRunLoopAddSource(runLoop, source, CFRunLoopMode.defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        emit([
            "event": "cgevent-observer-ready",
            "keyCode": f13CGKeyCode,
        ])
    }

    func reset() {
        keyDownCount = 0
        keyUpCount = 0
        autorepeatCount = 0
        firstDownTimestamp = nil
        firstUpTimestamp = nil
    }

    func waitForPulse(seconds: Int) -> CGEventPulse? {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while firstUpTimestamp == nil, Date() < deadline {
            CFRunLoopRunInMode(
                CFRunLoopMode.defaultMode,
                min(max(deadline.timeIntervalSinceNow, 0), 0.05),
                true
            )
        }
        guard
            let downTimestamp = firstDownTimestamp,
            let upTimestamp = firstUpTimestamp
        else { return nil }
        return CGEventPulse(
            downTimestamp: downTimestamp,
            upTimestamp: upTimestamp
        )
    }

    func stop() {
        if let runLoop, let source {
            CFRunLoopRemoveSource(runLoop, source, CFRunLoopMode.defaultMode)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoop = nil
        source = nil
        tap = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == f13CGKeyCode else { return }

        let timestamp = event.timestamp
        if type == .keyDown {
            keyDownCount += 1
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                autorepeatCount += 1
            }
            if firstDownTimestamp == nil {
                firstDownTimestamp = timestamp
            }
            emit([
                "event": "f13-cgevent-key-down",
                "keyCode": keyCode,
                "timestamp": timestamp,
            ])
        } else if type == .keyUp {
            keyUpCount += 1
            if firstUpTimestamp == nil {
                firstUpTimestamp = timestamp
            }
            emit([
                "event": "f13-cgevent-key-up",
                "keyCode": keyCode,
                "timestamp": timestamp,
            ])
        }
    }
}

private let k811F13CGEventCallback: CGEventTapCallBack = { _, type, event, context in
    guard
        let context,
        type == .keyDown || type == .keyUp
    else {
        return Unmanaged.passUnretained(event)
    }
    Unmanaged<F13CGEventPulseObserver>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

private func emit(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func validated(_ response: [UInt8]) throws {
    guard response.count == K811Packet.length else {
        throw VerifierError.shortResponse(response.count)
    }
    guard response.first == K811Packet.acknowledgement else {
        throw VerifierError.unexpectedResponse(Array(response.prefix(16)))
    }
}

private extension K811Packet {
    static func experimentalKeymapWritePage(
        _ page: Int,
        image: [UInt8]
    ) throws -> K811Packet {
        guard image.count == writeImageLength else {
            throw VerifierError.invalidImageLength(image.count)
        }
        guard (0..<writePageCount).contains(page) else {
            throw K811PacketError.invalidPage(page)
        }

        let offset = page * writePageSize
        let declaredLength = page == writePageCount - 1
            ? finalWritePageSize
            : writePageSize
        return make(opcode: 0x09) { bytes in
            bytes[4] = UInt8(declaredLength)
            bytes[5] = UInt8(truncatingIfNeeded: offset)
            bytes[6] = UInt8(truncatingIfNeeded: offset >> 8)
            bytes.replaceSubrange(
                8..<K811Packet.length,
                with: image[offset..<(offset + writePageSize)]
            )
        }
    }
}

private func writeImage(_ image: [UInt8], using transport: K811HIDTransport) throws {
    try validated(transport.request(.handshakeStart))
    var committed = false
    defer {
        if !committed {
            try? transport.send(.commit)
        }
    }

    for page in 0..<writePageCount {
        Thread.sleep(forTimeInterval: 0.02)
        let response = try transport.request(
            try .experimentalKeymapWritePage(page, image: image)
        )
        try validated(response)
        emit([
            "event": "write-page-ack",
            "page": page,
            "offset": page * writePageSize,
            "declaredLength": page == writePageCount - 1 ? finalWritePageSize : writePageSize,
            "ackPrefix": hex(Array(response.prefix(16))),
        ])
    }

    Thread.sleep(forTimeInterval: 0.02)
    try validated(transport.request(.commit))
    committed = true
    emit(["event": "commit-ack"])
}

private func writeMacroImage(
    _ image: K811MacroTableImage,
    using transport: K811HIDTransport
) throws {
    let packets = try K811MacroProtocol.packets(for: image)
    var completed = false
    defer {
        if !completed {
            try? transport.send(.commit)
        }
    }

    for (index, packet) in packets.enumerated() {
        if index > 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let response = try transport.request(packet)
        try validated(response)
        emit([
            "event": "macro-packet-ack",
            "index": index,
            "opcode": String(format: "0x%02X", packet.bytes[1]),
            "offset": packet.bytes[1] == 0x0D
                ? Int(packet.bytes[5]) | (Int(packet.bytes[6]) << 8)
                : -1,
            "ackPrefix": hex(Array(response.prefix(16))),
        ])
    }
    completed = true
}

private func saveBackup(_ bytes: [UInt8], path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(bytes).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: path
    )
    emit(["event": "backup-saved", "bytes": bytes.count, "path": path])
}

private func restoreZero(using transport: K811HIDTransport) throws {
    try writeImage([UInt8](repeating: 0, count: writeImageLength), using: transport)
    let restored = try K811KeymapProtocol.readSnapshot(using: transport)
    let record = Array(restored.bytes.prefix(4))
    guard record == [0, 0, 0, 0] else {
        throw VerifierError.unexpectedRecord(stage: "restore", bytes: record)
    }
    emit([
        "event": "restore-verified",
        "nonZeroReadableBytes": restored.bytes.filter { $0 != 0 }.count,
        "record": hex(record),
    ])
}

private func applyKeyAssignment(
    slot: Int,
    outputUsage: UInt8,
    seconds: Int,
    backupPath: String,
    requiresRawObservation: Bool = true,
    using transport: K811HIDTransport
) throws {
    let recordOffset = slot * 2 * 4
    guard slot >= 0, recordOffset + 4 <= writePayloadLength else {
        throw VerifierError.invalidPhysicalSlot(slot)
    }
    let expectedRecord: [UInt8] = [0x10, 0x00, outputUsage, 0x00]

    let baseline = try K811KeymapProtocol.readSnapshot(using: transport)
    let nonZeroCount = baseline.bytes.filter { $0 != 0 }.count
    guard nonZeroCount == 0 else {
        throw VerifierError.baselineNotZero(nonZeroCount)
    }
    try saveBackup(baseline.bytes, path: backupPath)
    emit([
        "event": "baseline-verified",
        "bytes": baseline.bytes.count,
        "nonZeroReadableBytes": nonZeroCount,
        "slot": slot,
        "record": recordOffset + 4 <= baseline.bytes.count
            ? hex(Array(baseline.bytes[recordOffset..<(recordOffset + 4)]))
            : "unavailable-write-only-slot",
    ])

    var image = [UInt8](repeating: 0, count: writeImageLength)
    image.replaceSubrange(recordOffset..<(recordOffset + 4), with: expectedRecord)

    let rawObserver = requiresRawObservation ? K811RawKeyObserver() : nil
    try rawObserver?.start()
    defer { rawObserver?.stop() }

    var mutationApplied = false
    defer {
        if mutationApplied {
            emit(["event": "fallback-restore-started"])
            do {
                try restoreZero(using: transport)
                emit(["event": "fallback-restore-completed"])
            } catch {
                emit(["event": "fallback-restore-failed", "error": error.localizedDescription])
            }
        }
    }

    try writeImage(image, using: transport)
    mutationApplied = true

    let applied = try K811KeymapProtocol.readSnapshot(using: transport)
    let record = recordOffset + 4 <= applied.bytes.count
        ? Array(applied.bytes[recordOffset..<(recordOffset + 4)])
        : []
    emit([
        "event": "apply-readback-observed",
        "slot": slot,
        "record": record.isEmpty ? "unavailable-write-only-slot" : hex(record),
        "matchesWriteOverlay": record.isEmpty ? false : record == expectedRecord,
        "note": "0x07 is not treated as an authoritative read-back for the 0x09 overlay",
        "expectedRawUsage": outputUsage,
        "windowSeconds": seconds,
    ])

    let observedEvent: RawKeyEvent?
    if let rawObserver {
        rawObserver.reset()
        emit(["event": "observation-window-opened", "oracle": "raw-iohid", "seconds": seconds])
        observedEvent = rawObserver.waitForKeyDown(seconds: seconds)
        if let observedEvent {
            emit([
                "event": "raw-key-down-observed",
                "usage": observedEvent.usage,
                "usageHex": String(format: "0x%02X", observedEvent.usage),
                "timestamp": observedEvent.timestamp,
                "locationID": String(format: "0x%08X", observedEvent.locationID),
            ])
        } else {
            emit(["event": "raw-key-down-timeout"])
        }
    } else {
        emit(["event": "observation-window-opened", "oracle": "external", "seconds": seconds])
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        observedEvent = nil
    }

    try restoreZero(using: transport)
    mutationApplied = false

    guard requiresRawObservation else {
        emit(["event": "external-observation-window-completed"])
        return
    }
    guard let observedEvent else {
        throw VerifierError.rawKeyTimeout
    }
    guard observedEvent.usage == outputUsage else {
        throw VerifierError.unexpectedRawUsage(
            expected: UInt32(outputUsage),
            observed: observedEvent.usage
        )
    }
    emit([
        "event": "physical-assignment-verified",
        "slot": slot,
        "usage": observedEvent.usage,
    ])
}

private func applyMacroPulseAssignment(
    slot: Int,
    outputUsage: UInt8,
    seconds: Int,
    keymapBackupPath: String,
    macroImagePath: String,
    requiresRawObservation: Bool = true,
    requiresCGEventObservation: Bool = false,
    using transport: K811HIDTransport
) throws {
    let recordOffset = slot * 2 * 4
    guard slot >= 0, recordOffset + 4 <= writeImageLength else {
        throw VerifierError.invalidPhysicalSlot(slot)
    }
    let expectedRecord: [UInt8] = [0x70, 0x00, 0x00, 0x00]
    let macroImage = try K811MacroTableImage(macros: [
        K811Macro(events: [
            .keyDown(usage: outputUsage, delayMilliseconds: 1),
            .keyUp(
                usage: outputUsage,
                delayMilliseconds: macroPulseHoldMilliseconds
            ),
        ])
    ])

    let baseline = try K811KeymapProtocol.readSnapshot(using: transport)
    let nonZeroCount = baseline.bytes.filter { $0 != 0 }.count
    guard nonZeroCount == 0 else {
        throw VerifierError.baselineNotZero(nonZeroCount)
    }
    try saveBackup(baseline.bytes, path: keymapBackupPath)
    try saveBackup(macroImage.bytes, path: macroImagePath)
    emit([
        "event": "macro-probe-baseline-verified",
        "keymapBytes": baseline.bytes.count,
        "nonZeroReadableBytes": nonZeroCount,
        "macroImageBytes": macroImage.bytes.count,
        "macroUsedLength": macroImage.usedLength,
        "macroPageCount": macroImage.pageCount,
        "macroPulseHoldMilliseconds": macroPulseHoldMilliseconds,
        "slot": slot,
        "recordOffset": recordOffset,
        "expectedRecord": hex(expectedRecord),
    ])

    let rawObserver: K811RawKeyObserver? = requiresRawObservation
        ? K811RawKeyObserver()
        : nil
    let cgEventObserver: F13CGEventPulseObserver? = requiresCGEventObservation
        ? F13CGEventPulseObserver()
        : nil
    if requiresCGEventObservation, outputUsage != f13Usage {
        throw VerifierError.invalidArguments
    }
    try rawObserver?.start()
    defer { rawObserver?.stop() }
    try cgEventObserver?.start()
    defer { cgEventObserver?.stop() }

    var keymapMutationApplied = false
    defer {
        if keymapMutationApplied {
            emit(["event": "fallback-restore-started"])
            do {
                try restoreZero(using: transport)
                emit(["event": "fallback-restore-completed"])
            } catch {
                emit(["event": "fallback-restore-failed", "error": error.localizedDescription])
            }
        }
    }

    try writeMacroImage(macroImage, using: transport)
    emit([
        "event": "macro-known-baseline-applied",
        "macroIndex": 0,
        "pulseUsage": String(format: "0x%02X", outputUsage),
    ])

    var keymapImage = [UInt8](repeating: 0, count: writeImageLength)
    keymapImage.replaceSubrange(
        recordOffset..<(recordOffset + expectedRecord.count),
        with: expectedRecord
    )
    try writeImage(keymapImage, using: transport)
    keymapMutationApplied = true

    rawObserver?.reset()
    cgEventObserver?.reset()
    let oracle: String
    if requiresRawObservation {
        oracle = "raw-iohid-down-up"
    } else if requiresCGEventObservation {
        oracle = "internal-cgevent-down-up"
    } else {
        oracle = "external-cgevent-down-up"
    }
    emit([
        "event": "observation-window-opened",
        "oracle": oracle,
        "seconds": seconds,
        "slot": slot,
        "expectedUsage": String(format: "0x%02X", outputUsage),
    ])

    let rawPulse: (down: RawKeyEvent, up: RawKeyEvent)?
    let cgEventPulse: CGEventPulse?
    if let rawObserver {
        rawPulse = rawObserver.waitForKeyPulse(
            usage: UInt32(outputUsage),
            seconds: seconds
        )
        cgEventPulse = nil
        if let rawPulse {
            emit([
                "event": "raw-key-pulse-observed",
                "usage": outputUsage,
                "usageHex": String(format: "0x%02X", outputUsage),
                "downTimestamp": rawPulse.down.timestamp,
                "upTimestamp": rawPulse.up.timestamp,
                "downLocationID": String(format: "0x%08X", rawPulse.down.locationID),
                "upLocationID": String(format: "0x%08X", rawPulse.up.locationID),
            ])
        } else {
            emit(["event": "raw-key-pulse-timeout"])
        }
    } else if let cgEventObserver {
        rawPulse = nil
        cgEventPulse = cgEventObserver.waitForPulse(seconds: seconds)
        if let cgEventPulse {
            emit([
                "event": "f13-cgevent-pulse-observed",
                "usage": outputUsage,
                "usageHex": String(format: "0x%02X", outputUsage),
                "downTimestamp": cgEventPulse.downTimestamp,
                "upTimestamp": cgEventPulse.upTimestamp,
                "keyDownCount": cgEventObserver.keyDownCount,
                "keyUpCount": cgEventObserver.keyUpCount,
                "autorepeatCount": cgEventObserver.autorepeatCount,
            ])
        } else {
            emit(["event": "f13-cgevent-pulse-timeout"])
        }
    } else {
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        rawPulse = nil
        cgEventPulse = nil
        emit(["event": "external-observation-window-completed"])
    }

    let keyDownCount: Int
    if let rawObserver {
        rawObserver.settle(seconds: 2)
        keyDownCount = rawObserver.keyDownCount(for: UInt32(outputUsage))
        emit([
            "event": "post-pulse-settle-completed",
            "seconds": 2,
            "keyDownCount": keyDownCount,
        ])
    } else {
        keyDownCount = -1
    }

    try restoreZero(using: transport)
    keymapMutationApplied = false

    guard requiresRawObservation || requiresCGEventObservation else {
        emit([
            "event": "external-macro-probe-restored",
            "slot": slot,
            "usage": outputUsage,
        ])
        return
    }

    if let cgEventObserver {
        guard cgEventPulse != nil else {
            throw VerifierError.cgEventPulseTimeout
        }
        guard
            cgEventObserver.keyDownCount == 1,
            cgEventObserver.keyUpCount >= 1,
            cgEventObserver.autorepeatCount == 0
        else {
            throw VerifierError.unexpectedCGEventPulse(
                downCount: cgEventObserver.keyDownCount,
                upCount: cgEventObserver.keyUpCount,
                autorepeatCount: cgEventObserver.autorepeatCount
            )
        }
        emit([
            "event": "physical-macro-pulse-verified",
            "oracle": "internal-cgevent-down-up",
            "slot": slot,
            "usage": outputUsage,
            "keyDownCount": cgEventObserver.keyDownCount,
            "keyUpCount": cgEventObserver.keyUpCount,
            "autorepeatCount": cgEventObserver.autorepeatCount,
        ])
        return
    }

    guard rawPulse != nil else {
        throw VerifierError.rawPulseTimeout
    }
    guard keyDownCount == 1 else {
        throw VerifierError.unexpectedPulseKeyDownCount(keyDownCount)
    }
    emit([
        "event": "physical-macro-pulse-verified",
        "slot": slot,
        "usage": outputUsage,
        "keyDownCount": keyDownCount,
        "keyUpObserved": true,
    ])
}

private func parseUsage(_ value: String) -> UInt8? {
    if value.lowercased().hasPrefix("0x") {
        return UInt8(String(value.dropFirst(2)), radix: 16)
    }
    return UInt8(value)
}

@main
private enum K811KeymapVerifier {
    static func main() {
        setbuf(stdout, nil)

        let arguments = Array(CommandLine.arguments.dropFirst())
        let transport = K811HIDTransport()

        do {
            guard let mode = arguments.first else {
                throw VerifierError.invalidArguments
            }

            if mode == "inspect-framing" {
                var image = [UInt8](repeating: 0, count: writeImageLength)
                image.replaceSubrange(0..<4, with: escapeToB)
                let first = try K811Packet.experimentalKeymapWritePage(0, image: image)
                let last = try K811Packet.experimentalKeymapWritePage(16, image: image)
                emit([
                    "event": "framing-inspected",
                    "firstPrefix": hex(Array(first.bytes.prefix(12))),
                    "firstChecksumValid": K811Packet.checksum(of: first.bytes) == first.bytes[3],
                    "lastPrefix": hex(Array(last.bytes.prefix(12))),
                    "lastChecksumValid": K811Packet.checksum(of: last.bytes) == last.bytes[3],
                ])
                return
            }

            if mode == "inspect-macro-framing" {
                let macroImage = try K811MacroTableImage(macros: [
                    K811Macro(events: [
                        .keyDown(usage: 0x68, delayMilliseconds: 1),
                        .keyUp(
                            usage: 0x68,
                            delayMilliseconds: macroPulseHoldMilliseconds
                        ),
                    ])
                ])
                let packets = try K811MacroProtocol.packets(for: macroImage)
                guard let control = K811KeymapProtocol.physicalKeys.first(where: { $0.slot == 114 }) else {
                    throw VerifierError.invalidPhysicalSlot(114)
                }
                var keymapImage = K811KeymapWriteImage()
                try keymapImage.setOneShotMacroOverride(
                    for: control,
                    layer: .standard,
                    macroIndex: 0
                )
                let recordOffset = control.slot * 2 * 4
                emit([
                    "event": "macro-framing-inspected",
                    "usedLength": macroImage.usedLength,
                    "pageCount": macroImage.pageCount,
                    "holdMilliseconds": macroPulseHoldMilliseconds,
                    "events": hex(Array(macroImage.bytes[64..<72])),
                    "firstPagePrefix": hex(Array(packets[1].bytes.prefix(10))),
                    "secondPagePrefix": hex(Array(packets[2].bytes.prefix(8))),
                    "finalizePrefix": hex(Array(packets[3].bytes.prefix(5))),
                    "referenceRecord": hex(Array(keymapImage.bytes[recordOffset..<(recordOffset + 4)])),
                ])
                return
            }

            if mode == "inspect-cgevent-observer" {
                let observer = F13CGEventPulseObserver()
                try observer.start()
                observer.stop()
                emit([
                    "event": "cgevent-observer-inspected",
                    "keyCode": f13CGKeyCode,
                ])
                return
            }

            if mode == "inspect-cgevent-pulse-state" {
                let observer = F13CGEventPulseObserver()
                guard
                    let down = CGEvent(
                        keyboardEventSource: nil,
                        virtualKey: CGKeyCode(f13CGKeyCode),
                        keyDown: true
                    ),
                    let up = CGEvent(
                        keyboardEventSource: nil,
                        virtualKey: CGKeyCode(f13CGKeyCode),
                        keyDown: false
                    )
                else {
                    throw VerifierError.cgEventTapUnavailable
                }
                observer.receive(type: .keyDown, event: down)
                observer.receive(type: .keyUp, event: up)
                guard
                    observer.waitForPulse(seconds: 5) != nil,
                    observer.keyDownCount == 1,
                    observer.keyUpCount == 1,
                    observer.autorepeatCount == 0
                else {
                    throw VerifierError.unexpectedCGEventPulse(
                        downCount: observer.keyDownCount,
                        upCount: observer.keyUpCount,
                        autorepeatCount: observer.autorepeatCount
                    )
                }
                emit([
                    "event": "cgevent-pulse-state-inspected",
                    "keyDownCount": observer.keyDownCount,
                    "keyUpCount": observer.keyUpCount,
                    "autorepeatCount": observer.autorepeatCount,
                ])
                return
            }

            let info = try transport.connect()
            emit([
                "event": "connected",
                "locationID": info.locationID,
                "product": info.product,
                "usagePage": info.usagePage,
            ])

            switch mode {
            case "backup-only":
                guard arguments.count <= 2 else {
                    throw VerifierError.invalidArguments
                }
                let backupPath = arguments.count == 2
                    ? arguments[1]
                    : "work/20260730-k811-mac/evidence/keymap-readable-backup.bin"
                let snapshot = try K811KeymapProtocol.readSnapshot(using: transport)
                try saveBackup(snapshot.bytes, path: backupPath)
                emit([
                    "event": "baseline-inspected",
                    "bytes": snapshot.bytes.count,
                    "nonZeroReadableBytes": snapshot.bytes.filter { $0 != 0 }.count,
                ])
            case "apply-slot-key", "apply-slot-key-external":
                guard
                    arguments.count >= 3,
                    let slot = Int(arguments[1]),
                    let outputUsage = parseUsage(arguments[2])
                else {
                    throw VerifierError.invalidArguments
                }
                let seconds = arguments.count > 3 ? Int(arguments[3]) ?? 30 : 30
                guard (5...600).contains(seconds) else {
                    throw VerifierError.invalidArguments
                }
                let backupPath = arguments.count > 4
                    ? arguments[4]
                    : "work/20260730-k811-mac/evidence/keymap-before-slot-\(slot)-usage-\(String(format: "%02X", outputUsage)).bin"
                try applyKeyAssignment(
                    slot: slot,
                    outputUsage: outputUsage,
                    seconds: seconds,
                    backupPath: backupPath,
                    requiresRawObservation: mode == "apply-slot-key",
                    using: transport
                )
            case "apply-slot-macro-pulse", "apply-slot-macro-pulse-external", "apply-slot-macro-pulse-cgevent":
                guard
                    arguments.count >= 3,
                    let slot = Int(arguments[1]),
                    let outputUsage = parseUsage(arguments[2])
                else {
                    throw VerifierError.invalidArguments
                }
                let seconds = arguments.count > 3 ? Int(arguments[3]) ?? 30 : 30
                guard (5...600).contains(seconds) else {
                    throw VerifierError.invalidArguments
                }
                let keymapBackupPath = arguments.count > 4
                    ? arguments[4]
                    : "work/20260730-k811-mac/evidence/keymap-before-slot-\(slot)-macro-pulse.bin"
                let macroImagePath = arguments.count > 5
                    ? arguments[5]
                    : "work/20260730-k811-mac/evidence/macro-known-baseline-f13.bin"
                try applyMacroPulseAssignment(
                    slot: slot,
                    outputUsage: outputUsage,
                    seconds: seconds,
                    keymapBackupPath: keymapBackupPath,
                    macroImagePath: macroImagePath,
                    requiresRawObservation: mode == "apply-slot-macro-pulse",
                    requiresCGEventObservation: mode == "apply-slot-macro-pulse-cgevent",
                    using: transport
                )
            case "apply-esc-b":
                let seconds = arguments.count > 1 ? Int(arguments[1]) ?? 30 : 30
                guard (5...600).contains(seconds) else {
                    throw VerifierError.invalidArguments
                }
                let backupPath = arguments.count > 2
                    ? arguments[2]
                    : "work/20260730-k811-mac/evidence/keymap-before-esc-b.bin"
                try applyKeyAssignment(
                    slot: 0,
                    outputUsage: 0x05,
                    seconds: seconds,
                    backupPath: backupPath,
                    using: transport
                )
            case "restore-zero":
                try restoreZero(using: transport)
            default:
                throw VerifierError.invalidArguments
            }

            transport.disconnect()
            emit(["event": "completed", "mode": mode])
        } catch {
            fputs("k811-keymap-verify: \(error.localizedDescription)\n", stderr)
            transport.disconnect()
            exit(1)
        }
    }
}
