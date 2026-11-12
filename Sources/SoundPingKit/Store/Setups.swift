import Foundation

/// One saved binding: every device is stored as UID + name so a changed UID can still be found by
/// name (D-09). Kept deliberately small; the selection model is provisional (D-07).
public struct SetupBinding: Codable, Sendable, Equatable {
  public struct StoredDevice: Codable, Sendable, Equatable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
      self.uid = uid
      self.name = name
    }
  }

  public var output: StoredDevice
  public var input: StoredDevice
  public var inChannel: Int?
  public var outChannels: [Int]?
  public var midiOut: MIDIRef?

  public init(
    output: StoredDevice, input: StoredDevice, inChannel: Int? = nil,
    outChannels: [Int]? = nil, midiOut: MIDIRef? = nil
  ) {
    self.output = output
    self.input = input
    self.inChannel = inChannel
    self.outChannels = outChannels
    self.midiOut = midiOut
  }

  /// What `--save-setup` stores for a resolved run.
  public init(resolved setup: ResolvedSetup) {
    self.init(
      output: StoredDevice(uid: setup.output.uid, name: setup.output.name),
      input: StoredDevice(uid: setup.input.uid, name: setup.input.name),
      inChannel: setup.inChannel,
      outChannels: setup.outChannels,
      midiOut: setup.midiOut)
  }
}

/// `<store>/setups.json` (schemaVersion 1).
public struct SetupsFile: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var setups: [String: SetupBinding]

  public init(setups: [String: SetupBinding] = [:]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.setups = setups
  }
}

public enum Setups {
  /// A missing file is an empty file. Anything unreadable, malformed or of another schema
  /// version is a usage error naming the file, never a crash (T-01-17).
  public static func load(from url: URL) throws -> SetupsFile {
    try VersionedFile.load(
      SetupsFile.self, from: url, supportedVersion: SetupsFile.currentSchemaVersion,
      errorCode: "setupsUnreadable", noun: "saved setups") ?? SetupsFile()
  }

  /// Writes atomically, so a crash never leaves half a file.
  public static func save(_ file: SetupsFile, to url: URL) throws {
    try VersionedFile.save(file, to: url, errorCode: "setupsUnwritable", noun: "saved setups")
  }
}
