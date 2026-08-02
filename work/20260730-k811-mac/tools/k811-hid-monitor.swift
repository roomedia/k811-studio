import Darwin
import Foundation
import IOKit.hid

private let vendorID = 0x5566
private let productID = 0x000A
private let keyboardUsagePage = 0x01
private let keyboardUsage = 0x06
private let keyboardKeyUsagePage = 0x07

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
    guard usagePage == keyboardKeyUsagePage else {
        return
    }

    let usage = Int(IOHIDElementGetUsage(element))
    let integerValue = IOHIDValueGetIntegerValue(value)
    let device = IOHIDElementGetDevice(element)
    let locationID = propertyInt(device, kIOHIDLocationIDKey)

    printJSON([
        "type": "key",
        "usagePage": usagePage,
        "usage": usage,
        "value": integerValue,
        "locationID": String(format: "0x%08X", locationID),
        "timestamp": IOHIDValueGetTimeStamp(value),
    ])
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
let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: vendorID,
    kIOHIDProductIDKey as String: productID,
    kIOHIDPrimaryUsagePageKey as String: keyboardUsagePage,
    kIOHIDPrimaryUsageKey as String: keyboardUsage,
]
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
