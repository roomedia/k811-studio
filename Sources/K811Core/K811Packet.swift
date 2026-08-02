import Foundation

public enum K811PacketError: Error, Equatable {
    case invalidLength(Int)
    case invalidPage(Int)
    case invalidPayloadLength(Int)
}

public struct K811Packet: Equatable, Sendable {
    public static let length = 64
    public static let prefix: UInt8 = 0x55
    public static let acknowledgement: UInt8 = 0xAA

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.length else {
            throw K811PacketError.invalidLength(bytes.count)
        }
        self.bytes = bytes
    }

    public static var handshakeStart: K811Packet {
        make(opcode: 0x01)
    }

    public static var handshakeConfigure: K811Packet {
        make(opcode: 0x05) { bytes in
            bytes[4] = 0x20
        }
    }

    public static var commit: K811Packet {
        make(opcode: 0x02)
    }

    public static func keymapReadPage(_ page: Int) throws -> K811Packet {
        guard (0..<K811KeymapProtocol.readPageCount).contains(page) else {
            throw K811PacketError.invalidPage(page)
        }

        let offset = page * K811KeymapProtocol.pageSize
        let length = page == K811KeymapProtocol.readPageCount - 1
            ? K811KeymapProtocol.finalPageSize
            : K811KeymapProtocol.pageSize
        return make(opcode: 0x07) { bytes in
            bytes[4] = UInt8(length)
            bytes[5] = UInt8(truncatingIfNeeded: offset)
            bytes[6] = UInt8(truncatingIfNeeded: offset >> 8)
        }
    }

    public static func keymapWritePage(
        _ page: Int,
        image: [UInt8]
    ) throws -> K811Packet {
        guard image.count == K811KeymapProtocol.writeImageLength else {
            throw K811PacketError.invalidPayloadLength(image.count)
        }
        guard (0..<K811KeymapProtocol.writePageCount).contains(page) else {
            throw K811PacketError.invalidPage(page)
        }

        let offset = page * K811KeymapProtocol.pageSize
        let declaredLength = page == K811KeymapProtocol.writePageCount - 1
            ? K811KeymapProtocol.finalPageSize
            : K811KeymapProtocol.pageSize
        return make(opcode: 0x09) { bytes in
            bytes[4] = UInt8(declaredLength)
            bytes[5] = UInt8(truncatingIfNeeded: offset)
            bytes[6] = UInt8(truncatingIfNeeded: offset >> 8)
            bytes.replaceSubrange(
                K811KeymapProtocol.responsePayloadOffset..<Self.length,
                with: image[offset..<(offset + K811KeymapProtocol.pageSize)]
            )
        }
    }

    public static func macroWritePage(
        _ page: Int,
        image: K811MacroTableImage
    ) throws -> K811Packet {
        guard (0..<image.pageCount).contains(page) else {
            throw K811PacketError.invalidPage(page)
        }

        let offset = page * K811MacroTableImage.pageSize
        return make(opcode: 0x0D) { bytes in
            bytes[4] = UInt8(K811MacroTableImage.pageSize)
            bytes[5] = UInt8(truncatingIfNeeded: offset)
            bytes[6] = UInt8(truncatingIfNeeded: offset >> 8)
            bytes.replaceSubrange(
                8..<Self.length,
                with: image.bytes[offset..<(offset + K811MacroTableImage.pageSize)]
            )
        }
    }

    public static var macroFinalize: K811Packet {
        var bytes = [UInt8](repeating: 0, count: Self.length)
        bytes[0] = Self.prefix
        bytes[1] = 0x10
        bytes[2] = 0xA5
        bytes[3] = 0x22
        return try! K811Packet(bytes: bytes)
    }

    public static func lighting(
        mode: K811LightingMode,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        speed: UInt8,
        autoColor: Bool
    ) -> K811Packet {
        make(opcode: 0x06) { bytes in
            bytes[4] = 0x20
            bytes[10] = mode.rawValue
            bytes[11] = brightness
            bytes[12] = mode.requiresFixedSpeed ? 1 : max(1, min(speed, 4))
            bytes[13] = 0
            bytes[14] = autoColor ? 1 : 0
            bytes[16] = red
            bytes[17] = green
            bytes[18] = blue
        }
    }

    public static func checksum(of bytes: [UInt8]) -> UInt8 {
        precondition(bytes.count == Self.length)
        return bytes[4..<Self.length].reduce(0, &+)
    }

    static func make(
        opcode: UInt8,
        configure: (inout [UInt8]) -> Void = { _ in }
    ) -> K811Packet {
        var bytes = [UInt8](repeating: 0, count: Self.length)
        bytes[0] = Self.prefix
        bytes[1] = opcode
        configure(&bytes)
        bytes[3] = checksum(of: bytes)
        return try! K811Packet(bytes: bytes)
    }
}

public enum K811LightingMode: UInt8, CaseIterable, Identifiable, Sendable {
    case wave1 = 0x00
    case waveLight = 0x01
    case spectrum = 0x02
    case wave2 = 0x03
    case mutant = 0x04
    case breathe = 0x05
    case fixed = 0x06
    case proliferate = 0x07
    case radial = 0x08
    case shining = 0x09
    case ringRunning = 0x0A
    case runnersLamp = 0x0B

    public var id: UInt8 { rawValue }

    public var displayName: String {
        switch self {
        case .wave1: "웨이브 1"
        case .waveLight: "웨이브 라이트"
        case .spectrum: "스펙트럼"
        case .wave2: "웨이브 2"
        case .mutant: "뮤턴트"
        case .breathe: "브리드"
        case .fixed: "고정 색상"
        case .proliferate: "프로리퍼레이트"
        case .radial: "라인 라디얼"
        case .shining: "샤이닝"
        case .ringRunning: "링 러닝"
        case .runnersLamp: "러너 램프"
        }
    }

    fileprivate var requiresFixedSpeed: Bool {
        switch self {
        case .mutant, .breathe, .fixed, .proliferate, .radial, .shining:
            true
        default:
            false
        }
    }
}

public enum K811LightingSequence {
    public static func packets(
        mode: K811LightingMode,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        speed: UInt8,
        autoColor: Bool
    ) -> [K811Packet] {
        [
            .handshakeStart,
            .handshakeConfigure,
            .lighting(
                mode: mode,
                red: red,
                green: green,
                blue: blue,
                brightness: brightness,
                speed: speed,
                autoColor: autoColor
            ),
            .commit,
        ]
    }
}
