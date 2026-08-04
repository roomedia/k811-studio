import Foundation
import K811Core

private enum Exit: Error {
    case usage(String)
}

private struct HookPayload {
    let values: [String: Any]

    init() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            values = [:]
            return
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Exit.usage("hook stdin must be a JSON object")
        }
        values = object
    }

    var hookEventName: String? { values["hook_event_name"] as? String }
    var notificationType: String? { values["notification_type"] as? String }
    var sessionID: String? { values["session_id"] as? String }
    var lastAssistantMessage: String? { values["last_assistant_message"] as? String }
    var notificationMessage: String? { values["message"] as? String }
}

private func sourceIsEnabled(_ source: K811AgentSource) -> Bool {
    switch source {
    case .orca, .claude, .codex, .custom:
        true
    case .opencode:
        UserDefaults(suiteName: "com.local.k811studio")?.bool(forKey: "agentSourceOpenCode") == true
    case .pi:
        UserDefaults(suiteName: "com.local.k811studio")?.bool(forKey: "agentSourcePi") == true
    case .antigravity:
        UserDefaults(suiteName: "com.local.k811studio")?.bool(forKey: "agentSourceAntigravity") == true
    }
}

private func render(_ signal: K811AgentSignal?) throws {
    guard let signal, let pattern = K811AgentPattern.pattern(for: signal.kind) else {
        try K811LightingWriter.turnOff()
        return
    }

    let on = K811LightingFrame(
        mode: pattern.mode,
        red: pattern.red,
        green: pattern.green,
        blue: pattern.blue,
        brightness: pattern.brightness,
        holdMilliseconds: pattern.onMilliseconds
    )
    let off = K811LightingFrame(
        mode: .fixed,
        red: 0,
        green: 0,
        blue: 0,
        brightness: 255,
        holdMilliseconds: pattern.offMilliseconds
    )
    var frames = Array(repeating: [on, off], count: pattern.pulseCount).flatMap { $0 }
    frames.append(K811LightingFrame(
        mode: .fixed,
        red: pattern.red,
        green: pattern.green,
        blue: pattern.blue,
        brightness: pattern.brightness
    ))
    try K811LightingWriter.apply(frames: frames)
}

private func apply(_ signal: K811AgentSignal) throws -> K811AgentSignal? {
    let seconds = signal.kind == .completed ? completedTimeoutSeconds() : 0
    let expiresAt = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
    let active = try K811AgentStateStore().update(
        with: signal,
        expiresAt: expiresAt,
        render: render
    )
    if expiresAt != nil {
        scheduleCompletedExpiry(for: signal)
    }
    return active
}

private func environmentFlag(_ name: String, default defaultValue: Bool) -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[name]?.lowercased() else {
        return defaultValue
    }
    return !["0", "false", "no", "off"].contains(raw)
}

/// 완료 알림이 스스로 꺼지기까지의 시간. `0` 이하면 자동 소등을 끈다.
private func completedTimeoutSeconds() -> Double {
    guard
        let raw = ProcessInfo.processInfo.environment["K811_COMPLETED_TIMEOUT_SECONDS"],
        let seconds = Double(raw)
    else {
        return 600
    }
    return seconds
}

private func helperExecutableURL() -> URL {
    if let path = Bundle.main.executablePath {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: CommandLine.arguments[0])
}

/// 완료 알림만 시간이 지나면 스스로 꺼지도록 분리된 자식 프로세스를 띄운다.
///
/// 상주 데몬을 두지 않는다는 설계를 유지하기 위해, 자식은 만료 한 건만 담당하고 끝난다.
/// 표준 입출력을 모두 끊어 훅 러너가 자식의 EOF 를 기다리지 않게 한다.
/// 같은 키에 이미 담당 자식이 있으면 새 자식은 잠금을 못 잡고 즉시 물러난다.
private func scheduleCompletedExpiry(for signal: K811AgentSignal) {
    let process = Process()
    process.executableURL = helperExecutableURL()
    process.arguments = ["expire", "--key", signal.key]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    // 기다리지 않는다. 부모가 끝나면 자식은 launchd 로 재부모화된다.
}

/// 이 키의 만료를 담당할 권리를 잡는다. 이미 담당 자식이 있으면 false.
///
/// 잠금은 프로세스가 살아 있는 동안 유지돼야 하므로 성공 시 파일 기술자를 닫지 않는다.
private func acquireExpiryLock(for key: String) -> Bool {
    let directory = K811AgentStateStore.defaultDirectoryURL
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let safeKey = String(key.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    let url = directory.appendingPathComponent("expire-\(safeKey).lock")

    let descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
    guard descriptor >= 0 else { return false }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        return false
    }
    return true
}

/// 담당 자식의 본체. 기한까지 자고 일어나 다시 확인한다.
///
/// 자는 사이에 새 완료가 들어오면 기한이 미뤄지므로, 깨어나서 기한을 다시 읽고
/// 남아 있으면 그만큼 더 잔다. 그래서 완료가 몇 번을 오든 자식은 키마다 하나뿐이다.
private func runExpiryWatch(key: String) throws {
    let store = K811AgentStateStore()
    while true {
        guard let deadline = try store.completedExpiry(forKey: key) else {
            return // 이미 해제됐거나 다른 신호가 덮어썼다
        }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 { break }
        Thread.sleep(forTimeInterval: remaining)
    }
    try store.expireCompleted(key: key, render: render)
}

private func clearAll() throws {
    try K811AgentStateStore().clearAll(render: render)
}

private func claudeSignal(from payload: HookPayload) -> K811AgentSignal? {
    let kind: K811AgentEventKind?
    switch payload.hookEventName {
    // SessionEnd 가 없으면 세션을 그냥 닫았을 때 그 세션의 알림이 계속 남는다.
    case "UserPromptSubmit", "SessionStart", "SessionEnd":
        kind = .clear
    case "StopFailure":
        kind = .failure
    // Codex 는 종료 시점에 질문 여부를 알 길이 없어 응답 끝의 물음표로 추측하지만,
    // Claude 는 질문·승인을 Notification 으로 따로 보내주므로 추측할 이유가 없다.
    // 여기서 같은 추측을 하면 물음표가 섞인 보통 응답까지 질문으로 잡힌다.
    case "Stop":
        kind = .completed
    case "Notification":
        switch payload.notificationType {
        case "idle_prompt":
            kind = .completed
        case "agent_completed":
            let message = payload.notificationMessage?.lowercased() ?? ""
            kind = message.contains("fail") || message.contains("error") ? .failure : .completed
        case "permission_prompt":
            kind = .approval
        case "elicitation_dialog", "agent_needs_input":
            kind = .question
        case "elicitation_complete", "elicitation_response":
            kind = .clear
        default:
            kind = nil
        }
    default:
        kind = nil
    }

    // SessionStart 도 자기 세션만 지운다. 새 창을 여는 것이 다른 세션의
    // 미확인 승인·실패 알림을 봤다는 뜻은 아니다.
    return kind.map {
        K811AgentSignal(source: .claude, kind: $0, sessionID: payload.sessionID)
    }
}

private func codexSignal(from payload: HookPayload) -> K811AgentSignal? {
    let kind: K811AgentEventKind?
    switch payload.hookEventName {
    case "UserPromptSubmit", "SessionStart":
        kind = .clear
    case "PermissionRequest":
        kind = .approval
    case "Stop":
        let suffix = String((payload.lastAssistantMessage ?? "").suffix(400))
        kind = suffix.contains("?") || suffix.contains("？") ? .question : .completed
    default:
        kind = nil
    }

    return kind.map {
        K811AgentSignal(source: .codex, kind: $0, sessionID: payload.sessionID)
    }
}

private func value(after name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func printJSON(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw Exit.usage("expected: emit or hook")
    }

    switch command {
    case "emit":
        guard
            let sourceValue = value(after: "--source", in: arguments),
            let source = K811AgentSource(rawValue: sourceValue),
            let eventValue = value(after: "--event", in: arguments),
            let kind = K811AgentEventKind(rawValue: eventValue)
        else {
            throw Exit.usage("emit requires --source and --event")
        }
        let signal = K811AgentSignal(
            source: source,
            kind: kind,
            sessionID: value(after: "--session", in: arguments)
        )
        guard signal.kind == .clear || sourceIsEnabled(signal.source) else {
            printJSON([
                "applied": false,
                "reason": "source-disabled",
                "source": signal.source.rawValue,
            ])
            return
        }
        let active = try apply(signal)
        printJSON([
            "applied": true,
            "active": active.map { "\($0.source.rawValue):\($0.kind.rawValue)" } ?? "off",
            "event": signal.kind.rawValue,
            "source": signal.source.rawValue,
        ])

    case "hook":
        guard arguments.count >= 2 else {
            throw Exit.usage("hook requires claude or codex")
        }
        let payload = try HookPayload()
        let signal: K811AgentSignal?
        switch arguments[1] {
        case "claude": signal = claudeSignal(from: payload)
        case "codex": signal = codexSignal(from: payload)
        default: throw Exit.usage("unsupported hook source: \(arguments[1])")
        }
        // 이 훅을 띄운 터미널을 사용자가 보고 있으면 알릴 이유가 없다.
        // clear 는 상태를 되돌리는 동작이라 항상 처리한다.
        if let signal,
           signal.kind != .clear,
           environmentFlag("K811_AGENT_SUPPRESS_WHEN_FOCUSED", default: true),
           K811Presence.hookHostIsFrontmost() {
            printJSON([:])
            return
        }
        if let signal {
            do {
                _ = try apply(signal)
            } catch {
                FileHandle.standardError.write(
                    Data(("k811-agent-event: direct HID update failed: \(error.localizedDescription)\n").utf8)
                )
            }
        }
        // Supported hook runners accept an empty JSON object as a no-op response.
        printJSON([:])

    case "clear":
        guard arguments.contains("--all") else {
            throw Exit.usage("clear requires --all")
        }
        try clearAll()
        printJSON(["applied": true, "active": "off"])

    case "expire":
        guard let key = value(after: "--key", in: arguments) else {
            throw Exit.usage("expire requires --key")
        }
        // 훅 러너의 프로세스 그룹에서 분리해, 훅이 끝날 때 같이 죽지 않게 한다.
        setsid()
        guard acquireExpiryLock(for: key) else {
            return // 이미 담당 자식이 있다. 그쪽이 연장된 기한까지 처리한다
        }
        try runExpiryWatch(key: key)

    case "--help", "help":
        print("""
        k811-agent-event emit --source SOURCE --event EVENT [--session ID]
        k811-agent-event hook claude|codex
        k811-agent-event clear --all
        k811-agent-event expire --key KEY                   (내부용: 완료 알림 자동 소등)

        Sources: \(K811AgentSource.allCases.map(\.rawValue).joined(separator: ", "))
        Events:  \(K811AgentEventKind.allCases.map(\.rawValue).joined(separator: ", "))

        Environment:
          K811_COMPLETED_TIMEOUT_SECONDS    완료 알림 자동 소등까지의 초. 0 이하면 끔 (기본 600)
          K811_AGENT_SUPPRESS_WHEN_FOCUSED  훅을 띄운 터미널이 최전면이면 켜지 않음 (기본 on)
        """)

    default:
        throw Exit.usage("unknown command: \(command)")
    }
}

do {
    try run()
} catch Exit.usage(let message) {
    FileHandle.standardError.write(Data(("k811-agent-event: \(message)\n").utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data(("k811-agent-event: \(error.localizedDescription)\n").utf8))
    exit(1)
}
