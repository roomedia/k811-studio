import Darwin
import Foundation

public struct K811AgentState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let signal: K811AgentSignal
        public let updatedAt: Date
        /// 완료 알림이 스스로 꺼질 시각. 완료가 아니면 nil.
        /// 예전 상태 파일에는 없는 키라 옵셔널로 둔다.
        public let expiresAt: Date?
    }

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public mutating func apply(
        _ signal: K811AgentSignal,
        at date: Date = Date(),
        expiresAt: Date? = nil
    ) {
        prune(before: date.addingTimeInterval(-86_400))
        if signal.kind == .clear {
            if signal.sessionID == nil {
                entries = entries.filter { $0.value.signal.source != signal.source }
            } else {
                entries.removeValue(forKey: signal.key)
            }
        } else {
            entries[signal.key] = Entry(signal: signal, updatedAt: date, expiresAt: expiresAt)
        }
    }

    /// 이 키에 걸려 있는 완료 만료 시각. 완료가 아니거나 만료를 안 걸었으면 nil.
    public func completedExpiry(forKey key: String) -> Date? {
        guard let entry = entries[key], entry.signal.kind == .completed else {
            return nil
        }
        return entry.expiresAt
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// 완료 알림만 시간으로 만료시킨다.
    ///
    /// 질문·승인·실패는 에이전트가 사람을 기다리는 상태라 시간으로 지우지 않는다.
    /// 새 완료가 덮어쓰면 만료 시각도 함께 미뤄지므로, 기한 전이면 아무것도 하지 않는다.
    @discardableResult
    public mutating func expireCompleted(key: String, asOf now: Date) -> Bool {
        guard
            let entry = entries[key],
            entry.signal.kind == .completed,
            let expiresAt = entry.expiresAt,
            expiresAt <= now
        else {
            return false
        }
        entries.removeValue(forKey: key)
        return true
    }

    public mutating func prune(before cutoff: Date) {
        entries = entries.filter { $0.value.updatedAt >= cutoff }
    }

    public var activeSignal: K811AgentSignal? {
        entries.values.max { lhs, rhs in
            let left = K811AgentPattern.pattern(for: lhs.signal.kind)?.importance ?? .none
            let right = K811AgentPattern.pattern(for: rhs.signal.kind)?.importance ?? .none
            if left == right {
                return lhs.updatedAt < rhs.updatedAt
            }
            return left < right
        }?.signal
    }
}

public final class K811AgentStateStore {
    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/K811 Studio", isDirectory: true)
    }

    private let directoryURL: URL
    private let stateURL: URL
    private let lockURL: URL

    public init(directoryURL: URL = K811AgentStateStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
        stateURL = directoryURL.appendingPathComponent("agent-state.json")
        lockURL = directoryURL.appendingPathComponent("agent-state.lock")
    }

    @discardableResult
    public func update(
        with signal: K811AgentSignal,
        expiresAt: Date? = nil,
        render: (K811AgentSignal?) throws -> Void
    ) throws -> K811AgentSignal? {
        try withLock {
            var state = try load()
            state.apply(signal, expiresAt: expiresAt)
            let active = state.activeSignal
            try render(active)
            try save(state)
            return active
        }
    }

    @discardableResult
    public func clearAll(
        render: (K811AgentSignal?) throws -> Void
    ) throws -> K811AgentSignal? {
        try withLock {
            var state = try load()
            state.removeAll()
            try render(nil)
            try save(state)
            return nil
        }
    }

    /// 예약된 만료 시점에 호출된다. 지울 게 없으면 LED 를 건드리지 않는다.
    @discardableResult
    public func expireCompleted(
        key: String,
        asOf now: Date = Date(),
        render: (K811AgentSignal?) throws -> Void
    ) throws -> Bool {
        try withLock {
            var state = try load()
            guard state.expireCompleted(key: key, asOf: now) else {
                return false
            }
            try render(state.activeSignal)
            try save(state)
            return true
        }
    }

    /// 이 키에 걸려 있는 완료 만료 시각. 만료 담당 자식이 기한 연장을 확인할 때 쓴다.
    public func completedExpiry(forKey key: String) throws -> Date? {
        try withLock { try load().completedExpiry(forKey: key) }
    }

    public func snapshot() throws -> K811AgentState {
        try withLock { try load() }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(directoryURL.path, mode_t(0o700))

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func load() throws -> K811AgentState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return K811AgentState()
        }
        return try JSONDecoder().decode(K811AgentState.self, from: Data(contentsOf: stateURL))
    }

    private func save(_ state: K811AgentState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
        chmod(stateURL.path, mode_t(0o600))
    }
}
