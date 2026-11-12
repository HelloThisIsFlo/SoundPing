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
    guard FileManager.default.fileExists(atPath: url.path) else { return SetupsFile() }

    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw unreadable(url, "cannot read it (\(error.localizedDescription))")
    }

    // Read the version alone first, so a file from another schema reports its version rather
    // than whatever field happened to fail to decode.
    struct Header: Decodable { var schemaVersion: Int }
    do {
      let header = try JSONDecoder().decode(Header.self, from: data)
      guard header.schemaVersion == SetupsFile.currentSchemaVersion else {
        throw unreadable(
          url,
          "it has schemaVersion \(header.schemaVersion), this build reads \(SetupsFile.currentSchemaVersion)"
        )
      }
      return try JSONDecoder().decode(SetupsFile.self, from: data)
    } catch let error as SoundPingError {
      throw error
    } catch {
      throw unreadable(url, "it is not valid setups JSON (\(error.localizedDescription))")
    }
  }

  /// Writes atomically, so a crash never leaves half a file.
  public static func save(_ file: SetupsFile, to url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var data = try RunJSON.fileEncoder().encode(file)
      data.append(0x0A)
      try data.write(to: url, options: .atomic)
    } catch {
      throw SoundPingError.usage(
        "setupsUnwritable",
        "cannot write the saved setups to '\(url.path)': \(error.localizedDescription)",
        context: ["path": url.path])
    }
  }

  private static func unreadable(_ url: URL, _ reason: String) -> SoundPingError {
    SoundPingError.usage(
      "setupsUnreadable", "the saved setups file '\(url.path)' is unusable: \(reason)",
      context: ["path": url.path])
  }
}
