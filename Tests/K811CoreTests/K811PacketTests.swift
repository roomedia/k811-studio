import Foundation
import XCTest

@testable import K811Core

final class K811PacketTests: XCTestCase {
  func testHandshakePacketsMatchReverseEngineeredProtocol() {
    XCTAssertEqual(
      Array(K811Packet.handshakeStart.bytes.prefix(5)), [0x55, 0x01, 0x00, 0x00, 0x00])
    XCTAssertEqual(
      Array(K811Packet.handshakeConfigure.bytes.prefix(5)), [0x55, 0x05, 0x00, 0x20, 0x20])
    XCTAssertEqual(Array(K811Packet.commit.bytes.prefix(5)), [0x55, 0x02, 0x00, 0x00, 0x00])
  }

  func testLightingPacketMatchesDocumentedLayoutAndChecksum() {
    let packet = K811Packet.lighting(
      mode: .wave1,
      red: 0x12,
      green: 0x34,
      blue: 0x56,
      brightness: 0x80,
      speed: 3,
      autoColor: false
    )

    XCTAssertEqual(packet.bytes.count, 64)
    XCTAssertEqual(packet.bytes[0], 0x55)
    XCTAssertEqual(packet.bytes[1], 0x06)
    XCTAssertEqual(packet.bytes[4], 0x20)
    XCTAssertEqual(packet.bytes[10], K811LightingMode.wave1.rawValue)
    XCTAssertEqual(packet.bytes[11], 0x80)
    XCTAssertEqual(packet.bytes[12], 3)
    XCTAssertEqual(packet.bytes[14], 0)
    XCTAssertEqual(Array(packet.bytes[16...18]), [0x12, 0x34, 0x56])
    XCTAssertEqual(packet.bytes[3], K811Packet.checksum(of: packet.bytes))
  }

  func testModesWithFixedFirmwareSpeedNormalizeToOne() {
    let packet = K811Packet.lighting(
      mode: .fixed,
      red: 0,
      green: 0,
      blue: 0,
      brightness: 0xFF,
      speed: 4,
      autoColor: false
    )

    XCTAssertEqual(packet.bytes[12], 1)
  }

  func testLightingSequenceUsesHandshakeCommandAndCommitOrder() {
    let packets = K811LightingSequence.packets(
      mode: .spectrum,
      red: 1,
      green: 2,
      blue: 3,
      brightness: 4,
      speed: 2,
      autoColor: true
    )

    XCTAssertEqual(packets.map { $0.bytes[1] }, [0x01, 0x05, 0x06, 0x02])
  }

  func testPacketRejectsUnexpectedReportLength() {
    XCTAssertThrowsError(try K811Packet(bytes: [0x55])) { error in
      XCTAssertEqual(error as? K811PacketError, .invalidLength(1))
    }
  }

  func testKeymapReadPageFraming() throws {
    let first = try K811Packet.keymapReadPage(0)
    XCTAssertEqual(Array(first.bytes[0...6]), [0x55, 0x07, 0x00, 0x38, 0x38, 0, 0])

    let last = try K811Packet.keymapReadPage(13)
    XCTAssertEqual(Array(last.bytes[0...6]), [0x55, 0x07, 0x00, 0x02, 0x28, 0xD8, 0x02])
    XCTAssertEqual(K811Packet.checksum(of: last.bytes), last.bytes[3])
  }

  func testKeymapWritePageFramingMatchesVerifiedDeviceTransaction() throws {
    let escape = K811KeymapProtocol.physicalKeys.first { $0.label == "ESC" }!
    var image = K811KeymapWriteImage()
    try image.setKeyboardOverride(for: escape, layer: .standard, outputUsage: 0x05)

    let first = try K811Packet.keymapWritePage(0, image: image.bytes)
    XCTAssertEqual(
      Array(first.bytes.prefix(12)),
      [0x55, 0x09, 0x00, 0x4D, 0x38, 0x00, 0x00, 0x00, 0x10, 0x00, 0x05, 0x00]
    )

    let last = try K811Packet.keymapWritePage(16, image: image.bytes)
    XCTAssertEqual(
      Array(last.bytes.prefix(8)),
      [0x55, 0x09, 0x00, 0xAB, 0x28, 0x80, 0x03, 0x00]
    )
    XCTAssertEqual(K811Packet.checksum(of: first.bytes), first.bytes[3])
    XCTAssertEqual(K811Packet.checksum(of: last.bytes), last.bytes[3])
    XCTAssertThrowsError(try K811Packet.keymapWritePage(0, image: [0])) { error in
      XCTAssertEqual(error as? K811PacketError, .invalidPayloadLength(1))
    }
  }

  func testF13KeyboardPulseMacroMatchesVendorSerializer() throws {
    let image = try K811MacroTableImage(macros: [
      K811Macro(events: [
        .keyDown(usage: 0x68, delayMilliseconds: 1),
        .keyUp(usage: 0x68, delayMilliseconds: 1),
      ])
    ])

    XCTAssertEqual(image.usedLength, 72)
    XCTAssertEqual(image.pageCount, 2)
    XCTAssertEqual(Array(image.bytes.prefix(2)), [0x40, 0x00])
    XCTAssertEqual(
      Array(image.bytes[64..<72]),
      [0x01, 0x00, 0x42, 0x68, 0x01, 0x00, 0x82, 0x68]
    )
  }

  func testMacroTablePacketsMatchVendorTransaction() throws {
    let image = try K811MacroTableImage(macros: [
      K811Macro(events: [
        .keyDown(usage: 0x68, delayMilliseconds: 1),
        .keyUp(usage: 0x68, delayMilliseconds: 1),
      ])
    ])

    let packets = try K811MacroProtocol.packets(for: image)

    XCTAssertEqual(packets.count, 5)
    XCTAssertEqual(packets[0], .handshakeStart)
    XCTAssertEqual(
      Array(packets[1].bytes.prefix(10)),
      [0x55, 0x0D, 0x00, 0x78, 0x38, 0x00, 0x00, 0x00, 0x40, 0x00]
    )
    XCTAssertEqual(
      Array(packets[2].bytes.prefix(8)),
      [0x55, 0x0D, 0x00, 0x06, 0x38, 0x38, 0x00, 0x00]
    )
    XCTAssertEqual(
      Array(packets[2].bytes[16..<24]),
      [0x01, 0x00, 0x42, 0x68, 0x01, 0x00, 0x82, 0x68]
    )
    XCTAssertEqual(Array(packets[3].bytes.prefix(5)), [0x55, 0x10, 0xA5, 0x22, 0x00])
    XCTAssertEqual(packets[4], .commit)
  }

  func testSpecialControlCanReferenceOneShotMacro() throws {
    let volumeDown = try XCTUnwrap(
      K811KeymapProtocol.physicalKeys.first { $0.label == "VOLUME DOWN" }
    )
    var image = K811KeymapWriteImage()

    try image.setOneShotMacroOverride(
      for: volumeDown,
      layer: .standard,
      macroIndex: 0
    )

    let offset = (volumeDown.slot * 2 + K811Layer.standard.rawValue) * 4
    XCTAssertEqual(Array(image.bytes[offset..<(offset + 4)]), [0x70, 0x00, 0x00, 0x00])
    XCTAssertThrowsError(
      try image.setOneShotMacroOverride(
        for: volumeDown,
        layer: .standard,
        macroIndex: K811MacroTableImage.maximumMacroCount
      )
    ) { error in
      XCTAssertEqual(error as? K811KeymapError, .invalidMacroIndex(32))
    }
  }

  func testPhysicalControlSlotsMatchVendorK811Layout() {
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: K811KeymapProtocol.physicalKeys.map { ($0.label, $0.slot) }),
      [
        "ESC": 0,
        "W": 39,
        "E": 40,
        "R": 41,
        "T": 42,
        "DELETE": 51,
        "TAB": 37,
        "A": 59,
        "S": 60,
        "D": 61,
        "JOYSTICK UP": 90,
        "JOYSTICK LEFT": 104,
        "JOYSTICK DOWN": 105,
        "JOYSTICK RIGHT": 106,
        "ENTER": 71,
        "LEFT SHIFT": 76,
        "Z": 78,
        "X": 79,
        "C": 80,
        "LEFT CTRL": 95,
        "LEFT ALT": 97,
        "SPACE": 98,
        "PERIOD": 108,
        "ROLLER UP": 110,
        "ROLLER DOWN": 112,
        "VOLUME UP": 113,
        "VOLUME DOWN": 114,
        "PREVIOUS": 115,
        "NEXT": 116,
        "PLAY/PAUSE": 117,
      ]
    )
  }

  func testDirectKeyboardOverridesAreLimitedToMainNineteenKeys() throws {
    XCTAssertEqual(
      Set(
        K811KeymapProtocol.physicalKeys
          .filter { $0.supportsDirectKeyboardOverride }
          .map(\.label)
      ),
      Set([
        "ESC", "W", "E", "R", "T", "DELETE", "TAB", "A", "S", "D",
        "LEFT SHIFT", "Z", "X", "C", "ENTER", "LEFT CTRL", "LEFT ALT", "SPACE",
        "PERIOD",
      ])
    )

    let volumeDown = try XCTUnwrap(
      K811KeymapProtocol.physicalKeys.first { $0.label == "VOLUME DOWN" }
    )
    var image = K811KeymapWriteImage()

    XCTAssertThrowsError(
      try image.setKeyboardOverride(
        for: volumeDown,
        layer: .standard,
        outputUsage: 0x68
      )
    ) { error in
      XCTAssertEqual(
        error as? K811KeymapError,
        .unsupportedDirectKeyboardOverride(114)
      )
    }

    var profile = K811KeymapProfile()
    XCTAssertThrowsError(
      try profile.setAssignment(
        for: volumeDown,
        layer: .standard,
        outputUsage: 0x68
      )
    ) { error in
      XCTAssertEqual(
        error as? K811KeymapError,
        .unsupportedDirectKeyboardOverride(114)
      )
    }
  }

  func testLastVendorControlFitsWriteImageButRejectsDirectKeyboardOverride() throws {
    let playPause = try XCTUnwrap(
      K811KeymapProtocol.physicalKeys.first { $0.label == "PLAY/PAUSE" }
    )
    let functionRecordOffset = (playPause.slot * 2 + K811Layer.function.rawValue) * 4

    XCTAssertLessThanOrEqual(functionRecordOffset + 4, K811KeymapProtocol.writeImageLength)

    var image = K811KeymapWriteImage()
    XCTAssertThrowsError(
      try image.setKeyboardOverride(
        for: playPause,
        layer: .function,
        outputUsage: 0x68
      )
    ) { error in
      XCTAssertEqual(
        error as? K811KeymapError,
        .unsupportedDirectKeyboardOverride(117)
      )
    }
  }

  func testKeyboardOverrideRecordAndModifierEncoding() throws {
    let escape = K811KeymapProtocol.physicalKeys.first { $0.label == "ESC" }!
    var image = K811KeymapWriteImage()
    try image.setKeyboardOverride(
      for: escape,
      layer: .function,
      outputUsage: 0x04,
      modifierUsage: 0xE2
    )

    XCTAssertEqual(Array(image.bytes[4..<8]), [0x10, 0x04, 0x04, 0x00])
    XCTAssertThrowsError(
      try image.setKeyboardOverride(
        for: escape,
        layer: .standard,
        outputUsage: 0x04,
        modifierUsage: 0x04
      )
    ) { error in
      XCTAssertEqual(error as? K811KeymapError, .invalidModifierUsage(0x04))
    }

    let invalidKey = K811PhysicalKey(
      label: "OUT OF RANGE",
      vendorLookupUsage: 0x04,
      slot: 1_000
    )
    XCTAssertThrowsError(
      try image.setKeyboardOverride(
        for: invalidKey,
        layer: .standard,
        outputUsage: 0x04
      )
    ) { error in
      XCTAssertEqual(error as? K811KeymapError, .invalidPhysicalSlot(1_000))
    }
  }

  func testKeymapProfileBuildsAndRemovesKeyboardAssignments() throws {
    let escape = K811KeymapProtocol.physicalKeys.first { $0.label == "ESC" }!
    var profile = K811KeymapProfile()

    try profile.setAssignment(
      for: escape,
      layer: .standard,
      outputUsage: 0x05,
      modifierUsage: 0xE1
    )

    XCTAssertEqual(
      profile.assignment(for: escape, layer: .standard),
      K811KeyAssignment(
        physicalSlot: escape.slot,
        layer: .standard,
        outputUsage: 0x05,
        modifierUsage: 0xE1
      )
    )
    XCTAssertEqual(Array(try profile.makeWriteImage().bytes[0..<4]), [0x10, 0x02, 0x05, 0x00])

    profile.removeAssignment(for: escape, layer: .standard)
    XCTAssertNil(profile.assignment(for: escape, layer: .standard))
    XCTAssertEqual(Array(try profile.makeWriteImage().bytes[0..<4]), [0, 0, 0, 0])
  }

  func testKeymapProfileStoreRoundTripsWithPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("k811-keymap-profile-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = K811KeymapProfileStore(directoryURL: directory)
    let escape = K811KeymapProtocol.physicalKeys.first { $0.label == "ESC" }!
    var profile = K811KeymapProfile()
    try profile.setAssignment(
      for: escape,
      layer: .standard,
      outputUsage: 0x05
    )

    XCTAssertEqual(try store.load(), K811KeymapProfile())
    try store.save(profile)
    XCTAssertEqual(try store.load(), profile)

    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber
    let profileURL = directory.appendingPathComponent("keymap-profile.json")
    let profileMode =
      try FileManager.default.attributesOfItem(atPath: profileURL.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(directoryMode?.intValue, 0o700)
    XCTAssertEqual(profileMode?.intValue, 0o600)
  }

  func testKeymapProfileRejectsDuplicateAndUnsupportedAssignments() throws {
    let duplicate = K811KeyAssignment(
      physicalSlot: 0,
      layer: .standard,
      outputUsage: 0x05
    )
    let duplicateProfile = K811KeymapProfile(assignments: [duplicate, duplicate])
    XCTAssertThrowsError(try duplicateProfile.makeWriteImage()) { error in
      XCTAssertEqual(
        error as? K811KeymapError,
        .duplicateAssignment(physicalSlot: 0, layer: .standard)
      )
    }

    let unsupportedProfile = K811KeymapProfile(
      assignments: [
        K811KeyAssignment(
          physicalSlot: 1_000,
          layer: .standard,
          outputUsage: 0x05
        )
      ]
    )
    XCTAssertThrowsError(try unsupportedProfile.makeWriteImage()) { error in
      XCTAssertEqual(error as? K811KeymapError, .invalidPhysicalSlot(1_000))
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("k811-invalid-keymap-profile-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = K811KeymapProfileStore(directoryURL: directory)
    XCTAssertThrowsError(try store.save(unsupportedProfile))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("keymap-profile.json").path
      )
    )
  }

  func testAppliedKeymapProfileRoundTripsAndCanBeInvalidated() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("k811-applied-profile-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = K811KeymapProfileStore(directoryURL: directory)
    let escape = K811KeymapProtocol.physicalKeys.first { $0.label == "ESC" }!
    var profile = K811KeymapProfile()
    try profile.setAssignment(for: escape, layer: .standard, outputUsage: 0x05)

    XCTAssertNil(try store.loadApplied())
    try store.saveApplied(profile)
    XCTAssertEqual(try store.loadApplied(), profile)

    let appliedURL = directory.appendingPathComponent("keymap-applied-profile.json")
    let profileMode =
      try FileManager.default.attributesOfItem(atPath: appliedURL.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(profileMode?.intValue, 0o600)

    try store.invalidateApplied()
    XCTAssertNil(try store.loadApplied())
  }

  func testKeymapBackupStorePersistsExactPrivateSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("k811-keymap-backups-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = K811KeymapBackupStore(directoryURL: directory)
    let snapshot = try K811KeymapSnapshot(
      bytes: [UInt8](repeating: 0xA5, count: K811KeymapProtocol.readPayloadLength)
    )

    let backupURL = try store.save(
      snapshot,
      date: Date(timeIntervalSince1970: 1_786_000_000)
    )

    XCTAssertEqual(try Data(contentsOf: backupURL), Data(snapshot.bytes))
    XCTAssertTrue(backupURL.lastPathComponent.hasPrefix("base-map-"))
    XCTAssertEqual(backupURL.pathExtension, "bin")
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber
    let backupMode =
      try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(directoryMode?.intValue, 0o700)
    XCTAssertEqual(backupMode?.intValue, 0o600)
  }

  func testKeymapRecoveryCoordinatorDoesNotWriteWhenBackupFails() {
    enum TestFailure: LocalizedError {
      case backup

      var errorDescription: String? { "backup failed" }
    }

    var writes = 0
    var persisted = false
    var invalidated = false

    XCTAssertThrowsError(
      try K811KeymapRecoveryCoordinator.apply(
        target: K811KeymapProfile(),
        recovery: K811KeymapProfile(),
        backupBaseSnapshot: { throw TestFailure.backup },
        write: { _ in writes += 1 },
        persistApplied: { _ in persisted = true },
        invalidateApplied: { invalidated = true }
      )
    ) { error in
      XCTAssertEqual(
        error as? K811KeymapApplyError,
        .baseSnapshotBackupFailed("backup failed")
      )
    }

    XCTAssertEqual(writes, 0)
    XCTAssertFalse(persisted)
    XCTAssertFalse(invalidated)
  }

  func testKeymapRecoveryCoordinatorRestoresPreviousImageAfterWriteFailure() throws {
    enum TestFailure: LocalizedError {
      case target

      var errorDescription: String? { "target failed" }
    }

    let escape = K811KeymapProtocol.physicalKeys.first { $0.label == "ESC" }!
    var target = K811KeymapProfile()
    try target.setAssignment(for: escape, layer: .standard, outputUsage: 0x05)
    let recovery = K811KeymapProfile()
    let backupURL = URL(fileURLWithPath: "/tmp/k811-base-map.bin")
    var writes: [K811KeymapWriteImage] = []
    var persisted = false
    var invalidated = false

    XCTAssertThrowsError(
      try K811KeymapRecoveryCoordinator.apply(
        target: target,
        recovery: recovery,
        backupBaseSnapshot: { backupURL },
        write: { image in
          writes.append(image)
          if writes.count == 1 { throw TestFailure.target }
        },
        persistApplied: { _ in persisted = true },
        invalidateApplied: { invalidated = true }
      )
    ) { error in
      XCTAssertEqual(
        error as? K811KeymapApplyError,
        .targetWriteFailedRecovered("target failed", backupURL: backupURL)
      )
    }

    XCTAssertEqual(writes.count, 2)
    XCTAssertEqual(writes[0], try target.makeWriteImage())
    XCTAssertEqual(writes[1], try recovery.makeWriteImage())
    XCTAssertFalse(persisted)
    XCTAssertFalse(invalidated)
  }

  func testKeymapRecoveryCoordinatorInvalidatesBaselineWhenRecoveryFails() throws {
    enum TestFailure: LocalizedError {
      case write(Int)

      var errorDescription: String? {
        switch self {
        case .write(let attempt): "write \(attempt) failed"
        }
      }
    }

    let backupURL = URL(fileURLWithPath: "/tmp/k811-base-map.bin")
    var attempts = 0
    var invalidated = false

    XCTAssertThrowsError(
      try K811KeymapRecoveryCoordinator.apply(
        target: K811KeymapProfile(),
        recovery: K811KeymapProfile(),
        backupBaseSnapshot: { backupURL },
        write: { _ in
          attempts += 1
          throw TestFailure.write(attempts)
        },
        persistApplied: { _ in XCTFail("persist must not run") },
        invalidateApplied: { invalidated = true }
      )
    ) { error in
      XCTAssertEqual(
        error as? K811KeymapApplyError,
        .targetWriteAndRecoveryFailed(
          target: "write 1 failed",
          recovery: "write 2 failed",
          backupURL: backupURL
        )
      )
    }

    XCTAssertEqual(attempts, 2)
    XCTAssertTrue(invalidated)
  }

  func testKeymapRecoveryCoordinatorRollsBackWhenAppliedProfileSaveFails() throws {
    enum TestFailure: LocalizedError {
      case persistence

      var errorDescription: String? { "profile save failed" }
    }

    let backupURL = URL(fileURLWithPath: "/tmp/k811-base-map.bin")
    var writes = 0
    var invalidated = false

    XCTAssertThrowsError(
      try K811KeymapRecoveryCoordinator.apply(
        target: K811KeymapProfile(),
        recovery: K811KeymapProfile(),
        backupBaseSnapshot: { backupURL },
        write: { _ in writes += 1 },
        persistApplied: { _ in throw TestFailure.persistence },
        invalidateApplied: { invalidated = true }
      )
    ) { error in
      XCTAssertEqual(
        error as? K811KeymapApplyError,
        .appliedProfileSaveFailedRecovered("profile save failed", backupURL: backupURL)
      )
    }

    XCTAssertEqual(writes, 2)
    XCTAssertFalse(invalidated)
  }

  func testVendorLayoutUsageMatchesObservedFactoryOutputWhereKnown() {
    let escape = K811KeymapProtocol.physicalKeys.first { $0.label == "ESC" }!
    let period = K811KeymapProtocol.physicalKeys.first { $0.label == "PERIOD" }!

    XCTAssertEqual(escape.vendorLookupUsage, 0x29)
    XCTAssertEqual(escape.observedFactoryOutputUsage, 0x29)
    XCTAssertEqual(period.vendorLookupUsage, 0x63)
    XCTAssertEqual(period.observedFactoryOutputUsage, 0x63)
  }

  func testPhysicalControlSlotsAreUniqueAndRespectReadWriteBounds() throws {
    let keys = K811KeymapProtocol.physicalKeys
    XCTAssertEqual(Set(keys.map(\.slot)).count, keys.count)
    XCTAssertTrue(
      keys.allSatisfy { key in
        (key.slot * 2 + K811Layer.function.rawValue) * 4 + 4
          <= K811KeymapProtocol.writeImageLength
      }
    )

    let snapshot = try K811KeymapSnapshot(
      bytes: [UInt8](repeating: 0, count: K811KeymapProtocol.readPayloadLength)
    )
    XCTAssertTrue(
      keys.allSatisfy { key in
        let offset = (key.slot * 2 + K811Layer.function.rawValue) * 4
        return (snapshot.record(for: key, layer: .function) != nil)
          == (offset + 4 <= K811KeymapProtocol.readPayloadLength)
      }
    )
  }

  func testAgentPatternsIncreaseInImportanceAndUseFixedColorPulses() {
    let completed = K811AgentPattern.pattern(for: .completed)!
    let question = K811AgentPattern.pattern(for: .question)!
    let approval = K811AgentPattern.pattern(for: .approval)!
    let failure = K811AgentPattern.pattern(for: .failure)!

    XCTAssertLessThan(completed.importance, question.importance)
    XCTAssertLessThan(question.importance, approval.importance)
    XCTAssertLessThan(approval.importance, failure.importance)
    XCTAssertEqual(
      [completed.mode, question.mode, approval.mode, failure.mode],
      [.fixed, .fixed, .fixed, .fixed])
    // 밝기는 심각도 구분에 쓰지 않는다. 알림은 눈에 띄는 게 목적이라 전부 최대로 낸다.
    XCTAssertEqual(
      [completed.brightness, question.brightness, approval.brightness, failure.brightness],
      [
        K811AgentPattern.maxBrightness, K811AgentPattern.maxBrightness,
        K811AgentPattern.maxBrightness, K811AgentPattern.maxBrightness,
      ])
    XCTAssertEqual(K811AgentPattern.maxBrightness, 255)
    XCTAssertEqual([completed.red, completed.green, completed.blue], [0, 255, 0])
    XCTAssertEqual([question.red, question.green, question.blue], [10, 132, 255])
    XCTAssertEqual([approval.red, approval.green, approval.blue], [255, 80, 0])
    XCTAssertEqual([failure.red, failure.green, failure.blue], [255, 0, 0])
    XCTAssertEqual(
      [completed.pulseCount, question.pulseCount, approval.pulseCount, failure.pulseCount],
      [2, 3, 4, 6])
    XCTAssertEqual(
      [
        completed.onMilliseconds, question.onMilliseconds, approval.onMilliseconds,
        failure.onMilliseconds,
      ], [180, 260, 180, 100])
    XCTAssertEqual(
      [
        completed.offMilliseconds, question.offMilliseconds, approval.offMilliseconds,
        failure.offMilliseconds,
      ], [180, 260, 180, 100])
  }

  func testAgentSignalEncodingContainsNoMessageContent() throws {
    let signal = K811AgentSignal(source: .claude, kind: .approval, sessionID: "session-1")
    let data = try JSONEncoder().encode(signal)
    let decoded = try JSONDecoder().decode(K811AgentSignal.self, from: data)
    let encoded = String(decoding: data, as: UTF8.self)

    XCTAssertEqual(decoded, signal)
    XCTAssertEqual(signal.key, "claude:session-1")
    XCTAssertFalse(encoded.contains("message"))
    XCTAssertFalse(encoded.contains("prompt"))
  }

  func testRequiredSourcesAreTheOnesWithDirectHooks() {
    XCTAssertEqual(
      K811AgentSource.allCases.filter(\.isRequired),
      [.orca, .claude, .codex])
    XCTAssertEqual(K811AgentSource.claude.displayName, "Claude Code")
    XCTAssertNil(K811AgentSource(rawValue: "hermes"))
  }

  func testAgentStateKeepsHighestImportanceAndRestoresLowerSignalsOnClear() {
    var state = K811AgentState()
    let date = Date(timeIntervalSince1970: 1_000_000)
    state.apply(K811AgentSignal(source: .orca, kind: .completed, sessionID: "done"), at: date)
    state.apply(
      K811AgentSignal(source: .codex, kind: .question, sessionID: "question"),
      at: date.addingTimeInterval(1))
    state.apply(
      K811AgentSignal(source: .claude, kind: .approval, sessionID: "approval"),
      at: date.addingTimeInterval(2))
    state.apply(
      K811AgentSignal(source: .claude, kind: .failure, sessionID: "failure"),
      at: date.addingTimeInterval(3))

    XCTAssertEqual(state.activeSignal?.kind, .failure)
    state.apply(
      K811AgentSignal(source: .claude, kind: .clear, sessionID: "failure"),
      at: date.addingTimeInterval(4))
    XCTAssertEqual(state.activeSignal?.kind, .approval)
    state.apply(
      K811AgentSignal(source: .claude, kind: .clear, sessionID: "approval"),
      at: date.addingTimeInterval(5))
    XCTAssertEqual(state.activeSignal?.kind, .question)
    state.apply(
      K811AgentSignal(source: .codex, kind: .clear, sessionID: "question"),
      at: date.addingTimeInterval(6))
    XCTAssertEqual(state.activeSignal?.kind, .completed)
    state.apply(
      K811AgentSignal(source: .orca, kind: .clear, sessionID: "done"),
      at: date.addingTimeInterval(7))
    XCTAssertNil(state.activeSignal)
  }

  func testAgentStatePrunesStaleSignalsAndClearWithoutSessionIsSourceScoped() {
    var state = K811AgentState()
    let date = Date(timeIntervalSince1970: 1_000_000)
    state.apply(K811AgentSignal(source: .claude, kind: .failure, sessionID: "old"), at: date)
    state.apply(
      K811AgentSignal(source: .codex, kind: .question, sessionID: "live"),
      at: date.addingTimeInterval(86_401))
    XCTAssertEqual(state.entries.count, 1)
    XCTAssertEqual(state.activeSignal?.source, .codex)

    state.apply(
      K811AgentSignal(source: .claude, kind: .approval, sessionID: "one"),
      at: date.addingTimeInterval(86_402))
    state.apply(
      K811AgentSignal(source: .claude, kind: .question, sessionID: "two"),
      at: date.addingTimeInterval(86_403))
    state.apply(K811AgentSignal(source: .claude, kind: .clear), at: date.addingTimeInterval(86_404))
    XCTAssertTrue(state.entries.values.allSatisfy { $0.signal.source != .claude })
    XCTAssertEqual(state.activeSignal?.source, .codex)
  }

  func testAgentStateStorePersistsOnlyAfterRendererSucceeds() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("k811-agent-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = K811AgentStateStore(directoryURL: directory)
    let completed = K811AgentSignal(source: .orca, kind: .completed, sessionID: "done")

    XCTAssertThrowsError(
      try store.update(with: completed) { _ in
        throw CocoaError(.fileWriteUnknown)
      })
    XCTAssertTrue(try store.snapshot().entries.isEmpty)

    var rendered: K811AgentSignal?
    try store.update(with: completed) { rendered = $0 }
    XCTAssertEqual(rendered, completed)
    XCTAssertEqual(try store.snapshot().activeSignal, completed)

    try store.clearAll { rendered = $0 }
    XCTAssertNil(rendered)
    XCTAssertTrue(try store.snapshot().entries.isEmpty)
  }
}
