import Darwin
import Foundation
import IOKit.hid

private let vendorID = 0x5566
private let productID = 0x000A
private let keyboardUsagePage = 0x01
private let keyboardUsage = 0x06
private let keyboardKeyUsagePage = 0x07
private let genericDesktopUsagePage = 0x01
private let consumerUsagePage = 0x0C

/// `--all` 일 때 볼 페이지. 벤더 페이지(0xFF00)는 조명·키맵 트래픽이라 제외한다.
private let allPages = [genericDesktopUsagePage, keyboardKeyUsagePage, consumerUsagePage]
private let watchesEveryPage = CommandLine.arguments.contains("--all")

/// 로그를 읽을 때 usage 번호를 세지 않도록 이름을 붙인다.
private func label(page: Int, usage: Int) -> String? {
    switch (page, usage) {
    case (keyboardKeyUsagePage, 0x4F): "arrow-right"
    case (keyboardKeyUsagePage, 0x50): "arrow-left"
    case (keyboardKeyUsagePage, 0x51): "arrow-down"
    case (keyboardKeyUsagePage, 0x52): "arrow-up"
    case (consumerUsagePage, 0xCD): "play-pause"
    case (consumerUsagePage, 0xB5): "next-track"
    case (consumerUsagePage, 0xB6): "prev-track"
    case (consumerUsagePage, 0xE9): "volume-up"
    case (consumerUsagePage, 0xEA): "volume-down"
    case (genericDesktopUsagePage, 0x30): "mouse-x"
    case (genericDesktopUsagePage, 0x31): "mouse-y"
    case (genericDesktopUsagePage, 0x38): "mouse-wheel"
    default: nil
    }
}

private func propertyInt(_ device: IOHIDDevice, _ key: String) -> Int {
    guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
        return 0
    }
    return (value as? NSNumber)?.intValue ?? 0
}

private func printJSON(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private let inputValueCallback: IOHIDValueCallback = { _, result, _, value in
    guard result == kIOReturnSuccess else {
        printJSON([
            "type": "callback-error",
            "result": String(format: "0x%08X", UInt32(bitPattern: result)),
        ])
        return
    }

    let element = IOHIDValueGetElement(value)
    let usagePage = Int(IOHIDElementGetUsagePage(element))
    if watchesEveryPage {
        guard allPages.contains(usagePage) else { return }
    } else {
        guard usagePage == keyboardKeyUsagePage else { return }
    }

    let usage = Int(IOHIDElementGetUsage(element))
    let integerValue = IOHIDValueGetIntegerValue(value)
    // 상대축은 움직이지 않을 때도 0 을 흘리므로 로그를 덮는다.
    if usagePage == genericDesktopUsagePage, integerValue == 0 {
        return
    }
    let device = IOHIDElementGetDevice(element)
    let locationID = propertyInt(device, kIOHIDLocationIDKey)

    var record: [String: Any] = [
        "type": "key",
        "usagePage": usagePage,
        "usage": usage,
        "value": integerValue,
        "locationID": String(format: "0x%08X", locationID),
        "timestamp": IOHIDValueGetTimeStamp(value),
    ]
    if let name = label(page: usagePage, usage: usage) {
        record["name"] = name
    }
    printJSON(record)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let duration: TimeInterval
if let secondsIndex = arguments.firstIndex(of: "--seconds"), secondsIndex + 1 < arguments.count,
   let seconds = TimeInterval(arguments[secondsIndex + 1]), seconds > 0
{
    duration = seconds
} else {
    duration = 30
}

setbuf(stdout, nil)

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
// --all 은 노드를 가리지 않는다. 재생/일시정지와 마우스 축은 키보드 컬렉션을
// primary 로 내세운 노드가 아닌 쪽에 실려 오기도 한다.
var matching: [String: Any] = [
    kIOHIDVendorIDKey as String: vendorID,
    kIOHIDProductIDKey as String: productID,
]
if !watchesEveryPage {
    matching[kIOHIDPrimaryUsagePageKey as String] = keyboardUsagePage
    matching[kIOHIDPrimaryUsageKey as String] = keyboardUsage
}
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
    fputs("k811-hid-monitor: IOHIDManagerOpen failed: \(String(format: "0x%08X", UInt32(bitPattern: openResult)))\n", stderr)
    exit(1)
}

defer {
    IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
}

let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
printJSON([
    "type": "ready",
    "matchedDevices": devices.count,
    "durationSeconds": duration,
    "observer": "IOHIDManager input-value callback; independent of Orca/TUI stdin",
])

guard !devices.isEmpty else {
    exit(2)
}

let deadline = Date().addingTimeInterval(duration)
while Date() < deadline {
    let remaining = deadline.timeIntervalSinceNow
    CFRunLoopRunInMode(.defaultMode, min(max(remaining, 0), 0.1), true)
}

printJSON(["type": "complete"])
