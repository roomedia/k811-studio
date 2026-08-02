import Foundation

public enum K811Layer: Int, CaseIterable, Codable, Sendable {
  case standard = 0
  case function = 1
}

public struct K811PhysicalKey: Codable, Equatable, Identifiable, Sendable {
  public let label: String
  public let vendorLookupUsage: UInt8
  public let observedFactoryOutputUsage: UInt8?
  public let slot: Int

  public var id: Int { slot }

  public var supportsDirectKeyboardOverride: Bool {
    K811KeymapProtocol.directKeyboardSlots.contains(slot)
  }

  public init(
    label: String,
    vendorLookupUsage: UInt8,
    observedFactoryOutputUsage: UInt8? = nil,
    slot: Int
  ) {
    self.label = label
    self.vendorLookupUsage = vendorLookupUsage
    self.observedFactoryOutputUsage = observedFactoryOutputUsage
    self.slot = slot
  }
}

public struct K811KeyRecord: Codable, Equatable, Sendable {
  public let key: K811PhysicalKey
  public let layer: K811Layer
  public let bytes: [UInt8]
}

public enum K811KeymapError: LocalizedError, Equatable {
  case invalidSnapshotLength(Int)
  case responseTooShort(Int)
  case unexpectedResponse([UInt8])
  case invalidModifierUsage(UInt8)
  case invalidMacroIndex(Int)
  case invalidPhysicalSlot(Int)
  case unsupportedDirectKeyboardOverride(Int)
  case duplicateAssignment(physicalSlot: Int, layer: K811Layer)

  public var errorDescription: String? {
    switch self {
    case .invalidSnapshotLength(let length):
      "K811 keymap snapshot 길이가 올바르지 않습니다 (\(length))."
    case .responseTooShort(let length):
      "K811 keymap 응답이 너무 짧습니다 (\(length))."
    case .unexpectedResponse(let bytes):
      "K811 응답 header가 예상과 다릅니다: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))"
    case .invalidModifierUsage(let usage):
      "modifier usage는 E0...E7이어야 합니다 (실제: \(String(format: "%02X", usage)))."
    case .invalidMacroIndex(let index):
      "macro index가 지원 범위를 벗어났습니다 (실제: \(index))."
    case .invalidPhysicalSlot(let slot):
      "physical slot이 write payload 범위를 벗어났습니다 (실제: \(slot))."
    case .unsupportedDirectKeyboardOverride(let slot):
      "이 control은 key-up이 보장되는 macro 경로 없이 직접 keyboard override할 수 없습니다 (slot: \(slot))."
    case .duplicateAssignment(let physicalSlot, let layer):
      "같은 key/layer assignment가 중복되었습니다 (slot: \(physicalSlot), layer: \(layer.rawValue))."
    }
  }
}

public struct K811KeymapWriteImage: Equatable, Sendable {
  public private(set) var bytes: [UInt8]

  public init() {
    bytes = [UInt8](repeating: 0, count: K811KeymapProtocol.writeImageLength)
  }

  public mutating func setKeyboardOverride(
    for key: K811PhysicalKey,
    layer: K811Layer,
    outputUsage: UInt8,
    modifierUsage: UInt8? = nil
  ) throws {
    let offset = (key.slot * 2 + layer.rawValue) * 4
    guard offset >= 0, offset + 4 <= K811KeymapProtocol.writeImageLength else {
      throw K811KeymapError.invalidPhysicalSlot(key.slot)
    }

    guard key.supportsDirectKeyboardOverride else {
      throw K811KeymapError.unsupportedDirectKeyboardOverride(key.slot)
    }

    let modifierMask: UInt8
    if let modifierUsage {
      guard (0xE0...0xE7).contains(modifierUsage) else {
        throw K811KeymapError.invalidModifierUsage(modifierUsage)
      }
      modifierMask = 1 << (modifierUsage - 0xE0)
    } else {
      modifierMask = 0
    }

    bytes.replaceSubrange(
      offset..<(offset + 4),
      with: [0x10, modifierMask, outputUsage, 0x00]
    )
  }

  public mutating func setOneShotMacroOverride(
    for key: K811PhysicalKey,
    layer: K811Layer,
    macroIndex: Int
  ) throws {
    guard (0..<K811MacroTableImage.maximumMacroCount).contains(macroIndex) else {
      throw K811KeymapError.invalidMacroIndex(macroIndex)
    }

    let offset = (key.slot * 2 + layer.rawValue) * 4
    guard offset >= 0, offset + 4 <= K811KeymapProtocol.writeImageLength else {
      throw K811KeymapError.invalidPhysicalSlot(key.slot)
    }
    bytes.replaceSubrange(
      offset..<(offset + 4),
      with: [0x70, UInt8(macroIndex), 0x00, 0x00]
    )
  }
}

public struct K811KeymapSnapshot: Equatable, Sendable {
  public let bytes: [UInt8]

  public init(bytes: [UInt8]) throws {
    guard bytes.count == K811KeymapProtocol.readPayloadLength else {
      throw K811KeymapError.invalidSnapshotLength(bytes.count)
    }
    self.bytes = bytes
  }

  public func record(for key: K811PhysicalKey, layer: K811Layer) -> K811KeyRecord? {
    let offset = (key.slot * 2 + layer.rawValue) * 4
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    return K811KeyRecord(
      key: key,
      layer: layer,
      bytes: Array(bytes[offset..<(offset + 4)])
    )
  }

}

public enum K811KeymapProtocol {
  public static let pageSize = 56
  public static let readPageCount = 14
  public static let writePageCount = 17
  public static let finalPageSize = 40
  public static let responsePayloadOffset = 8
  public static let readPayloadLength = 13 * pageSize + finalPageSize
  public static let writePayloadLength = (writePageCount - 1) * pageSize + finalPageSize
  public static let writeImageLength = writePageCount * pageSize
  static let directKeyboardSlots: Set<Int> = [
    0, 37, 39, 40, 41, 42, 51, 59, 60, 61, 71, 76, 78, 79, 80, 95, 97, 98, 108,
  ]

  public static let physicalKeys: [K811PhysicalKey] = [
    .init(label: "ESC", vendorLookupUsage: 0x29, observedFactoryOutputUsage: 0x29, slot: 0),
    .init(label: "W", vendorLookupUsage: 0x1A, slot: 39),
    .init(label: "E", vendorLookupUsage: 0x08, slot: 40),
    .init(label: "R", vendorLookupUsage: 0x15, slot: 41),
    .init(label: "T", vendorLookupUsage: 0x17, slot: 42),
    .init(label: "DELETE", vendorLookupUsage: 0x4C, slot: 51),
    .init(label: "JOYSTICK UP", vendorLookupUsage: 0x52, slot: 90),
    .init(label: "TAB", vendorLookupUsage: 0x2B, slot: 37),
    .init(label: "A", vendorLookupUsage: 0x04, slot: 59),
    .init(label: "S", vendorLookupUsage: 0x16, slot: 60),
    .init(label: "D", vendorLookupUsage: 0x07, slot: 61),
    .init(label: "JOYSTICK LEFT", vendorLookupUsage: 0x50, slot: 104),
    .init(label: "JOYSTICK DOWN", vendorLookupUsage: 0x51, slot: 105),
    .init(label: "JOYSTICK RIGHT", vendorLookupUsage: 0x4F, slot: 106),
    .init(label: "LEFT SHIFT", vendorLookupUsage: 0xE1, slot: 76),
    .init(label: "Z", vendorLookupUsage: 0x1D, slot: 78),
    .init(label: "X", vendorLookupUsage: 0x1B, slot: 79),
    .init(label: "C", vendorLookupUsage: 0x06, slot: 80),
    .init(label: "ENTER", vendorLookupUsage: 0x28, slot: 71),
    .init(label: "LEFT CTRL", vendorLookupUsage: 0xE0, slot: 95),
    .init(label: "LEFT ALT", vendorLookupUsage: 0xE2, slot: 97),
    .init(label: "SPACE", vendorLookupUsage: 0x2C, slot: 98),
    .init(label: "PERIOD", vendorLookupUsage: 0x63, observedFactoryOutputUsage: 0x63, slot: 108),
    .init(label: "ROLLER UP", vendorLookupUsage: 0x45, slot: 110),
    .init(label: "ROLLER DOWN", vendorLookupUsage: 0x46, slot: 112),
    .init(label: "VOLUME UP", vendorLookupUsage: 0x09, slot: 113),
    .init(label: "VOLUME DOWN", vendorLookupUsage: 0x0A, slot: 114),
    .init(label: "PREVIOUS", vendorLookupUsage: 0x0B, slot: 115),
    .init(label: "NEXT", vendorLookupUsage: 0x0D, slot: 116),
    .init(label: "PLAY/PAUSE", vendorLookupUsage: 0x0E, slot: 117),
  ]

  public static let directKeyboardKeys: [K811PhysicalKey] = physicalKeys.filter {
    $0.supportsDirectKeyboardOverride
  }

  public static func readSnapshot(using transport: K811HIDTransport) throws -> K811KeymapSnapshot {
    _ = try validated(transport.request(.handshakeStart))
    var completed = false
    defer {
      if !completed {
        try? transport.send(.commit)
      }
    }

    var payload = [UInt8](repeating: 0, count: readPayloadLength)
    for page in 0..<readPageCount {
      let response = try validated(
        transport.request(try .keymapReadPage(page))
      )
      let length = page == readPageCount - 1 ? finalPageSize : pageSize
      guard response.count >= responsePayloadOffset + length else {
        throw K811KeymapError.responseTooShort(response.count)
      }
      let offset = page * pageSize
      payload.replaceSubrange(
        offset..<(offset + length),
        with: response[responsePayloadOffset..<(responsePayloadOffset + length)]
      )
    }

    _ = try validated(transport.request(.commit))
    completed = true
    return try K811KeymapSnapshot(bytes: payload)
  }

  public static func writeImage(
    _ image: K811KeymapWriteImage,
    using transport: K811HIDTransport
  ) throws {
    _ = try validated(transport.request(.handshakeStart))
    var completed = false
    defer {
      if !completed {
        try? transport.send(.commit)
      }
    }

    for page in 0..<writePageCount {
      Thread.sleep(forTimeInterval: 0.02)
      _ = try validated(
        transport.request(try .keymapWritePage(page, image: image.bytes))
      )
    }

    Thread.sleep(forTimeInterval: 0.02)
    _ = try validated(transport.request(.commit))
    completed = true
  }

  private static func validated(_ response: [UInt8]) throws -> [UInt8] {
    guard response.count == K811Packet.length else {
      throw K811KeymapError.responseTooShort(response.count)
    }
    guard response.first == K811Packet.acknowledgement else {
      throw K811KeymapError.unexpectedResponse(Array(response.prefix(16)))
    }
    return response
  }
}
