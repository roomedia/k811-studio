import CoreGraphics
import Darwin
import Foundation

private final class PulseState {
    var keyDownCount = 0
    var keyUpCount = 0
    var autorepeatCount = 0
    var firstDownTimestamp: UInt64?
    var firstUpTimestamp: UInt64?
    var settleDeadline: Date?
}

private func emit(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private let f13KeyCode: Int64 = 105

private let eventCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else {
        return Unmanaged.passUnretained(event)
    }
    let state = Unmanaged<PulseState>.fromOpaque(context).takeUnretainedValue()
    guard type == .keyDown || type == .keyUp else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == f13KeyCode else {
        return Unmanaged.passUnretained(event)
    }

    let autorepeatValue = event.getIntegerValueField(.keyboardEventAutorepeat)
    let timestamp = event.timestamp
    if type == .keyDown {
        state.keyDownCount += 1
        if autorepeatValue != 0 {
            state.autorepeatCount += 1
        }
        if state.firstDownTimestamp == nil {
            state.firstDownTimestamp = timestamp
        }
        emit([
            "event": "f13-key-down",
            "keyCode": keyCode,
            "autorepeat": autorepeatValue != 0,
            "timestamp": timestamp,
        ])
    } else {
        state.keyUpCount += 1
        if state.firstUpTimestamp == nil {
            state.firstUpTimestamp = timestamp
            state.settleDeadline = Date().addingTimeInterval(2)
        }
        emit([
            "event": "f13-key-up",
            "keyCode": keyCode,
            "timestamp": timestamp,
        ])
    }
    return Unmanaged.passUnretained(event)
}

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 30
guard (5...600).contains(seconds) else {
    fputs("usage: k811-f13-pulse-monitor [seconds: 5...600]\n", stderr)
    exit(2)
}

setbuf(stdout, nil)
private let state = PulseState()
let context = Unmanaged.passUnretained(state).toOpaque()
let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
    | (CGEventMask(1) << CGEventType.keyUp.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: eventCallback,
    userInfo: context
) else {
    fputs("k811-f13-pulse-monitor: CGEvent listen-only tap unavailable\n", stderr)
    exit(3)
}

guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
    fputs("k811-f13-pulse-monitor: run-loop source creation failed\n", stderr)
    exit(4)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
CGEvent.tapEnable(tap: tap, enable: true)

emit([
    "event": "monitor-ready",
    "keyCode": f13KeyCode,
    "timeoutSeconds": seconds,
    "settleSeconds": 2,
])

let timeoutDeadline = Date().addingTimeInterval(TimeInterval(seconds))
while Date() < timeoutDeadline {
    if let settleDeadline = state.settleDeadline, Date() >= settleDeadline {
        break
    }
    let activeDeadline = min(timeoutDeadline, state.settleDeadline ?? timeoutDeadline)
    CFRunLoopRunInMode(
        .defaultMode,
        min(max(activeDeadline.timeIntervalSinceNow, 0), 0.05),
        true
    )
}

CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
CGEvent.tapEnable(tap: tap, enable: false)

let passed = state.keyDownCount == 1
    && state.keyUpCount >= 1
    && state.autorepeatCount == 0
    && state.firstDownTimestamp != nil
    && state.firstUpTimestamp != nil
    && state.firstDownTimestamp! <= state.firstUpTimestamp!
emit([
    "event": "monitor-completed",
    "passed": passed,
    "keyDownCount": state.keyDownCount,
    "keyUpCount": state.keyUpCount,
    "autorepeatCount": state.autorepeatCount,
    "firstDownTimestamp": state.firstDownTimestamp ?? 0,
    "firstUpTimestamp": state.firstUpTimestamp ?? 0,
])
exit(passed ? 0 : 1)
