import Foundation

public enum K811AgentSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case orca
    case claude
    case codex
    case opencode
    case pi
    case antigravity
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .orca: "Orca"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .antigravity: "Antigravity"
        case .custom: "Custom"
        }
    }

    public var isRequired: Bool {
        switch self {
        case .orca, .claude, .codex: true
        case .opencode, .pi, .antigravity, .custom: false
        }
    }
}

public enum K811AgentEventKind: String, CaseIterable, Codable, Sendable {
    case clear
    case completed
    case question
    case approval
    case failure
}

public enum K811AgentImportance: Int, Comparable, Codable, Sendable {
    case none = 0
    case completed = 1
    case question = 2
    case approval = 3
    case failure = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct K811AgentPattern: Equatable, Sendable {
    /// 훅 조명 기본 밝기. 알림은 눈에 띄는 게 목적이라 심각도와 무관하게 최대로 낸다.
    /// 심각도는 색과 펄스 횟수로 이미 구분된다.
    public static let maxBrightness: UInt8 = 255

    public let importance: K811AgentImportance
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let brightness: UInt8
    public let mode: K811LightingMode
    public let pulseCount: Int
    public let onMilliseconds: UInt64
    public let offMilliseconds: UInt64

    public static func pattern(for kind: K811AgentEventKind) -> K811AgentPattern? {
        switch kind {
        case .clear:
            nil
        case .completed:
            K811AgentPattern(
                importance: .completed,
                red: 0,
                green: 255,
                blue: 0,
                brightness: maxBrightness,
                mode: .fixed,
                pulseCount: 2,
                onMilliseconds: 180,
                offMilliseconds: 180
            )
        case .question:
            K811AgentPattern(
                importance: .question,
                red: 10,
                green: 132,
                blue: 255,
                brightness: maxBrightness,
                mode: .fixed,
                pulseCount: 3,
                onMilliseconds: 260,
                offMilliseconds: 260
            )
        case .approval:
            K811AgentPattern(
                importance: .approval,
                red: 255,
                green: 80,
                blue: 0,
                brightness: maxBrightness,
                mode: .fixed,
                pulseCount: 4,
                onMilliseconds: 180,
                offMilliseconds: 180
            )
        case .failure:
            K811AgentPattern(
                importance: .failure,
                red: 255,
                green: 0,
                blue: 0,
                brightness: maxBrightness,
                mode: .fixed,
                pulseCount: 6,
                onMilliseconds: 100,
                offMilliseconds: 100
            )
        }
    }
}

public struct K811AgentSignal: Equatable, Codable, Sendable {
    public let source: K811AgentSource
    public let kind: K811AgentEventKind
    public let sessionID: String?

    public init(source: K811AgentSource, kind: K811AgentEventKind, sessionID: String? = nil) {
        self.source = source
        self.kind = kind
        self.sessionID = sessionID?.isEmpty == false ? sessionID : nil
    }

    public var key: String {
        "\(source.rawValue):\(sessionID ?? "global")"
    }
}
