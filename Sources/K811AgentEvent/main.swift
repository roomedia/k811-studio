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
    private var extra: [String: Any] { values["extra"] as? [String: Any] ?? [:] }
    var hermesSessionID: String? {
        let direct = sessionID?.isEmpty == false ? sessionID : nil
        let sessionKey = extra["session_key"] as? String
        return direct ?? (sessionKey?.isEmpty == false ? sessionKey : nil)
    }
    var hermesAssistantResponse: String? { extra["assistant_response"] as? String }
}

private func sourceIsEnabled(_ source: K811AgentSource) -> Bool {
    switch source {
    case .orca, .hermes, .claude, .codex, .custom:
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
    try K811AgentStateStore().update(with: signal, render: render)
}

private func clearAll() throws {
    try K811AgentStateStore().clearAll(render: render)
}

private func claudeSignal(from payload: HookPayload) -> K811AgentSignal? {
    let kind: K811AgentEventKind?
    switch payload.hookEventName {
    case "UserPromptSubmit", "SessionStart":
        kind = .clear
    case "StopFailure":
        kind = .failure
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

    return kind.map {
        K811AgentSignal(
            source: .claude,
            kind: $0,
            sessionID: payload.hookEventName == "SessionStart" ? nil : payload.sessionID
        )
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
        K811AgentSignal(
            source: .codex,
            kind: $0,
            sessionID: payload.hookEventName == "SessionStart" ? nil : payload.sessionID
        )
    }
}

private func hermesSignal(from payload: HookPayload) -> K811AgentSignal? {
    guard let eventName = payload.hookEventName else { return nil }
    return K811AgentSignal.hermesHook(
        eventName: eventName,
        sessionID: payload.hermesSessionID,
        assistantResponse: payload.hermesAssistantResponse
    )
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
            throw Exit.usage("hook requires claude, codex, or hermes")
        }
        let payload = try HookPayload()
        let signal: K811AgentSignal?
        switch arguments[1] {
        case "claude": signal = claudeSignal(from: payload)
        case "codex": signal = codexSignal(from: payload)
        case "hermes": signal = hermesSignal(from: payload)
        default: throw Exit.usage("unsupported hook source: \(arguments[1])")
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

    case "--help", "help":
        print("""
        k811-agent-event emit --source SOURCE --event EVENT [--session ID]
        k811-agent-event hook claude|codex|hermes
        k811-agent-event clear --all

        Sources: \(K811AgentSource.allCases.map(\.rawValue).joined(separator: ", "))
        Events:  \(K811AgentEventKind.allCases.map(\.rawValue).joined(separator: ", "))
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
