import Darwin
import Foundation

public struct K811KeyAssignment: Codable, Equatable, Identifiable, Sendable {
  public let physicalSlot: Int
  public let layer: K811Layer
  public let outputUsage: UInt8
  public let modifierUsage: UInt8?

  public var id: String {
    "\(physicalSlot):\(layer.rawValue)"
  }

  public init(
    physicalSlot: Int,
    layer: K811Layer,
    outputUsage: UInt8,
    modifierUsage: UInt8? = nil
  ) {
    self.physicalSlot = physicalSlot
    self.layer = layer
    self.outputUsage = outputUsage
    self.modifierUsage = modifierUsage
  }
}

public struct K811KeymapProfile: Codable, Equatable, Sendable {
  public private(set) var assignments: [K811KeyAssignment]

  public init(assignments: [K811KeyAssignment] = []) {
    self.assignments = assignments
  }

  public var isEmpty: Bool {
    assignments.isEmpty
  }

  public func assignment(
    for key: K811PhysicalKey,
    layer: K811Layer
  ) -> K811KeyAssignment? {
    assignments.first {
      $0.physicalSlot == key.slot && $0.layer == layer
    }
  }

  public mutating func setAssignment(
    for key: K811PhysicalKey,
    layer: K811Layer,
    outputUsage: UInt8,
    modifierUsage: UInt8? = nil
  ) throws {
    try Self.validate(key: key, modifierUsage: modifierUsage)
    removeAssignment(for: key, layer: layer)
    assignments.append(
      K811KeyAssignment(
        physicalSlot: key.slot,
        layer: layer,
        outputUsage: outputUsage,
        modifierUsage: modifierUsage
      )
    )
    sortAssignments()
  }

  public mutating func removeAssignment(
    for key: K811PhysicalKey,
    layer: K811Layer
  ) {
    assignments.removeAll {
      $0.physicalSlot == key.slot && $0.layer == layer
    }
  }

  public mutating func removeAll() {
    assignments.removeAll()
  }

  public func makeWriteImage() throws -> K811KeymapWriteImage {
    var image = K811KeymapWriteImage()
    var seen = Set<String>()

    for assignment in assignments {
      guard seen.insert(assignment.id).inserted else {
        throw K811KeymapError.duplicateAssignment(
          physicalSlot: assignment.physicalSlot,
          layer: assignment.layer
        )
      }
      guard
        let key = K811KeymapProtocol.physicalKeys.first(where: {
          $0.slot == assignment.physicalSlot
        })
      else {
        throw K811KeymapError.invalidPhysicalSlot(assignment.physicalSlot)
      }
      try Self.validate(key: key, modifierUsage: assignment.modifierUsage)
      try image.setKeyboardOverride(
        for: key,
        layer: assignment.layer,
        outputUsage: assignment.outputUsage,
        modifierUsage: assignment.modifierUsage
      )
    }

    return image
  }

  private static func validate(
    key: K811PhysicalKey,
    modifierUsage: UInt8?
  ) throws {
    guard K811KeymapProtocol.physicalKeys.contains(where: { $0.slot == key.slot }) else {
      throw K811KeymapError.invalidPhysicalSlot(key.slot)
    }
    guard key.supportsDirectKeyboardOverride else {
      throw K811KeymapError.unsupportedDirectKeyboardOverride(key.slot)
    }
    if let modifierUsage, !(0xE0...0xE7).contains(modifierUsage) {
      throw K811KeymapError.invalidModifierUsage(modifierUsage)
    }
  }

  private mutating func sortAssignments() {
    assignments.sort {
      if $0.physicalSlot == $1.physicalSlot {
        return $0.layer.rawValue < $1.layer.rawValue
      }
      return $0.physicalSlot < $1.physicalSlot
    }
  }
}

public struct K811KeymapProfileStore: Sendable {
  public static var defaultDirectoryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/K811 Studio", isDirectory: true)
  }

  private let directoryURL: URL
  private let profileURL: URL
  private let appliedProfileURL: URL

  public init(directoryURL: URL = K811KeymapProfileStore.defaultDirectoryURL) {
    self.directoryURL = directoryURL
    profileURL = directoryURL.appendingPathComponent("keymap-profile.json")
    appliedProfileURL = directoryURL.appendingPathComponent("keymap-applied-profile.json")
  }

  public func load() throws -> K811KeymapProfile {
    try prepareDirectory()
    return try loadProfile(at: profileURL) ?? K811KeymapProfile()
  }

  public func save(_ profile: K811KeymapProfile) throws {
    try saveProfile(profile, at: profileURL)
  }

  public func loadApplied() throws -> K811KeymapProfile? {
    try prepareDirectory()
    return try loadProfile(at: appliedProfileURL)
  }

  public func saveApplied(_ profile: K811KeymapProfile) throws {
    try saveProfile(profile, at: appliedProfileURL)
  }

  public func invalidateApplied() throws {
    try prepareDirectory()
    guard FileManager.default.fileExists(atPath: appliedProfileURL.path) else { return }
    try FileManager.default.removeItem(at: appliedProfileURL)
  }

  private func loadProfile(at url: URL) throws -> K811KeymapProfile? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let profile = try JSONDecoder().decode(
      K811KeymapProfile.self,
      from: Data(contentsOf: url)
    )
    _ = try profile.makeWriteImage()
    return profile
  }

  private func saveProfile(_ profile: K811KeymapProfile, at url: URL) throws {
    _ = try profile.makeWriteImage()
    try prepareDirectory()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(profile).write(to: url, options: .atomic)
    chmod(url.path, mode_t(0o600))
  }

  private func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directoryURL.path, mode_t(0o700))
  }
}

public struct K811KeymapBackupStore: Sendable {
  public static var defaultDirectoryURL: URL {
    K811KeymapProfileStore.defaultDirectoryURL
      .appendingPathComponent("Keymap Backups", isDirectory: true)
  }

  private let directoryURL: URL

  public init(directoryURL: URL = K811KeymapBackupStore.defaultDirectoryURL) {
    self.directoryURL = directoryURL
  }

  public func save(_ snapshot: K811KeymapSnapshot, date: Date = Date()) throws -> URL {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directoryURL.path, mode_t(0o700))

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
    let filename = "base-map-\(formatter.string(from: date))-\(UUID().uuidString).bin"
    let backupURL = directoryURL.appendingPathComponent(filename)
    try Data(snapshot.bytes).write(to: backupURL, options: .atomic)
    chmod(backupURL.path, mode_t(0o600))
    return backupURL
  }
}
