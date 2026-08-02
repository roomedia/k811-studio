import Foundation
import K811Core

let transport = K811HIDTransport()

do {
    let device = try transport.connect()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(device)
    print(String(decoding: data, as: UTF8.self))
    transport.disconnect()
} catch {
    fputs("k811-probe: \(error.localizedDescription)\n", stderr)
    exit(1)
}
