import Foundation

public struct K811LightingFrame: Sendable {
    public let mode: K811LightingMode
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let brightness: UInt8
    public let speed: UInt8
    public let autoColor: Bool
    public let holdMilliseconds: UInt64

    public init(
        mode: K811LightingMode,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        speed: UInt8 = 1,
        autoColor: Bool = false,
        holdMilliseconds: UInt64 = 0
    ) {
        self.mode = mode
        self.red = red
        self.green = green
        self.blue = blue
        self.brightness = brightness
        self.speed = speed
        self.autoColor = autoColor
        self.holdMilliseconds = holdMilliseconds
    }
}

public enum K811LightingWriter {
    @discardableResult
    public static func apply(
        mode: K811LightingMode,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        speed: UInt8 = 1,
        autoColor: Bool = false
    ) throws -> K811DeviceInfo {
        try apply(frames: [K811LightingFrame(
            mode: mode,
            red: red,
            green: green,
            blue: blue,
            brightness: brightness,
            speed: speed,
            autoColor: autoColor
        )])
    }

    @discardableResult
    public static func apply(frames: [K811LightingFrame]) throws -> K811DeviceInfo {
        precondition(!frames.isEmpty)
        let transport = K811HIDTransport()
        let device = try transport.connect()
        defer { transport.disconnect() }

        for frame in frames {
            for packet in K811LightingSequence.packets(
                mode: frame.mode,
                red: frame.red,
                green: frame.green,
                blue: frame.blue,
                brightness: frame.brightness,
                speed: frame.speed,
                autoColor: frame.autoColor
            ) {
                try transport.send(packet)
                Thread.sleep(forTimeInterval: 0.01)
            }
            if frame.holdMilliseconds > 0 {
                Thread.sleep(forTimeInterval: Double(frame.holdMilliseconds) / 1_000)
            }
        }
        return device
    }

    @discardableResult
    public static func turnOff() throws -> K811DeviceInfo {
        try apply(
            mode: .fixed,
            red: 0,
            green: 0,
            blue: 0,
            brightness: 220
        )
    }
}
