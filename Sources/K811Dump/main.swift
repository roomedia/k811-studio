import Foundation
import K811Core

struct DumpRow: Codable {
    let label: String
    let vendorLookupUsage: Int
    let observedFactoryOutputUsage: Int?
    let slot: Int
    let standard: String?
    let function: String?
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

let transport = K811HIDTransport()

do {
    _ = try transport.connect()
    let snapshot = try K811KeymapProtocol.readSnapshot(using: transport)
    let rows = K811KeymapProtocol.physicalKeys.map { key in
        DumpRow(
            label: key.label,
            vendorLookupUsage: Int(key.vendorLookupUsage),
            observedFactoryOutputUsage: key.observedFactoryOutputUsage.map(Int.init),
            slot: key.slot,
            standard: snapshot.record(for: key, layer: .standard).map { hex($0.bytes) },
            function: snapshot.record(for: key, layer: .function).map { hex($0.bytes) }
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(rows))
    FileHandle.standardOutput.write(Data("\n".utf8))
    transport.disconnect()
} catch {
    fputs("k811-dump: \(error.localizedDescription)\n", stderr)
    transport.disconnect()
    exit(1)
}
