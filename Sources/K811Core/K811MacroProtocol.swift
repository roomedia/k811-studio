import Foundation

public enum K811MacroError: Error, Equatable {
  case emptyMacro(Int)
  case tooManyMacros(Int)
  case imageOverflow(Int)
}

public enum K811MacroKeyAction: Sendable {
  case down
  case up
}

public struct K811MacroEvent: Sendable {
  public let action: K811MacroKeyAction
  public let serializedUsage: UInt8
  public let delayMilliseconds: UInt16

  public static func keyDown(
    usage: UInt8,
    delayMilliseconds: UInt16
  ) -> K811MacroEvent {
    K811MacroEvent(
      action: .down,
      serializedUsage: usage,
      delayMilliseconds: delayMilliseconds
    )
  }

  public static func keyUp(
    usage: UInt8,
    delayMilliseconds: UInt16
  ) -> K811MacroEvent {
    K811MacroEvent(
      action: .up,
      serializedUsage: usage,
      delayMilliseconds: delayMilliseconds
    )
  }
}

public struct K811Macro: Sendable {
  public let events: [K811MacroEvent]

  public init(events: [K811MacroEvent]) {
    self.events = events
  }
}

public struct K811MacroTableImage: Sendable {
  public static let offsetTableLength = 64
  public static let maximumMacroCount = offsetTableLength / 2
  public static let maximumLength = 0x0E00
  public static let eventRecordLength = 4
  public static let pageSize = 56

  public let bytes: [UInt8]
  public let usedLength: Int

  public var pageCount: Int {
    (usedLength + Self.pageSize - 1) / Self.pageSize
  }

  public init(macros: [K811Macro]) throws {
    guard macros.count <= Self.maximumMacroCount else {
      throw K811MacroError.tooManyMacros(macros.count)
    }

    var bytes = [UInt8](repeating: 0, count: Self.maximumLength)
    var eventOffset = Self.offsetTableLength

    for (macroIndex, macro) in macros.enumerated() {
      guard !macro.events.isEmpty else {
        throw K811MacroError.emptyMacro(macroIndex)
      }

      let requiredLength = eventOffset + macro.events.count * Self.eventRecordLength
      guard requiredLength <= Self.maximumLength else {
        throw K811MacroError.imageOverflow(requiredLength)
      }

      bytes[macroIndex * 2] = UInt8(truncatingIfNeeded: eventOffset)
      bytes[macroIndex * 2 + 1] = UInt8(truncatingIfNeeded: eventOffset >> 8)

      for (eventIndex, event) in macro.events.enumerated() {
        let delay = max(event.delayMilliseconds, 1)
        bytes[eventOffset] = UInt8(truncatingIfNeeded: delay)
        bytes[eventOffset + 1] = UInt8(truncatingIfNeeded: delay >> 8)

        var flags: UInt8 = event.action == .down ? 0x40 : 0x00
        flags |= (0xE0...0xE7).contains(event.serializedUsage) ? 0x01 : 0x02
        if eventIndex == macro.events.count - 1 {
          flags |= 0x80
        }
        bytes[eventOffset + 2] = flags
        bytes[eventOffset + 3] = event.serializedUsage
        eventOffset += Self.eventRecordLength
      }
    }

    self.bytes = bytes
    self.usedLength = eventOffset
  }
}

public enum K811MacroProtocol {
  public static func packets(for image: K811MacroTableImage) throws -> [K811Packet] {
    var packets: [K811Packet] = [.handshakeStart]
    for page in 0..<image.pageCount {
      packets.append(try .macroWritePage(page, image: image))
    }
    packets.append(.macroFinalize)
    packets.append(.commit)
    return packets
  }
}
