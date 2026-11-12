import Foundation

/// Reads and writes a small JSON file that carries a `schemaVersion`. A file that is missing is
/// simply absent; one that is unreadable, malformed or from another schema is a usage error that
/// names the file, never a crash (T-01-21, ASVS V5).
private struct VersionHeader: Decodable { var schemaVersion: Int }

enum VersionedFile {
  static func load<File: Decodable>(
    _ type: File.Type, from url: URL, supportedVersion: Int, alsoReads: Set<Int> = [],
    errorCode: String, noun: String
  ) throws -> File? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }

    func unreadable(_ reason: String) -> SoundPingError {
      SoundPingError.usage(
        errorCode, "the \(noun) file '\(url.path)' is unusable: \(reason)",
        context: ["path": url.path])
    }

    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw unreadable("cannot read it (\(error.localizedDescription))")
    }

    // The version alone first, so a file from another schema reports its version rather than
    // whichever field happened to fail to decode.
    do {
      let header = try JSONDecoder().decode(VersionHeader.self, from: data)
      guard header.schemaVersion == supportedVersion || alsoReads.contains(header.schemaVersion)
      else {
        throw unreadable(
          "it has schemaVersion \(header.schemaVersion), this build reads \(supportedVersion)")
      }
      return try RunJSON.decoder().decode(File.self, from: data)
    } catch let error as SoundPingError {
      throw error
    } catch {
      throw unreadable("it is not valid JSON of the expected shape (\(error.localizedDescription))")
    }
  }

  /// Atomic, so a crash never leaves half a file.
  static func save<File: Encodable>(
    _ file: File, to url: URL, errorCode: String, noun: String
  ) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var data = try RunJSON.fileEncoder().encode(file)
      data.append(0x0A)
      try data.write(to: url, options: .atomic)
    } catch {
      throw SoundPingError.usage(
        errorCode, "cannot write the \(noun) file '\(url.path)': \(error.localizedDescription)",
        context: ["path": url.path])
    }
  }
}

/// What a clock self-test result is stored under: the device, its rate and the buffer SoundPing
/// ran it with (D-05). Phase 2 looks the status up by these before it trusts host time.
public struct ClockSelfTestKey: Codable, Sendable, Equatable, Hashable {
  public var deviceUID: String
  public var sampleRate: Double
  public var bufferFrames: Int

  public init(deviceUID: String, sampleRate: Double, bufferFrames: Int) {
    self.deviceUID = deviceUID
    self.sampleRate = sampleRate
    self.bufferFrames = bufferFrames
  }
}

/// One line of `clock-selftest.json`: the latest self-test of one key.
public struct ClockSelfTestEntry: Codable, Sendable, Equatable {
  public var deviceUID: String
  public var sampleRate: Double
  public var bufferFrames: Int
  public var pass: Bool
  public var medianDeltaFrames: Double
  public var p95AbsDeltaFrames: Double
  public var n: Int
  public var runId: String
  public var measuredAt: Date

  public init(key: ClockSelfTestKey, result: ClockSelfTestResult, runId: String, measuredAt: Date) {
    self.deviceUID = key.deviceUID
    self.sampleRate = key.sampleRate
    self.bufferFrames = key.bufferFrames
    self.pass = result.pass
    self.medianDeltaFrames = result.medianDeltaFrames
    self.p95AbsDeltaFrames = result.p95AbsDeltaFrames
    self.n = result.n
    self.runId = runId
    self.measuredAt = measuredAt
  }

  public var key: ClockSelfTestKey {
    ClockSelfTestKey(deviceUID: deviceUID, sampleRate: sampleRate, bufferFrames: bufferFrames)
  }
}

/// `<store>/clock-selftest.json` (schemaVersion 1).
public struct ClockSelfTestFile: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var entries: [ClockSelfTestEntry]

  public init(entries: [ClockSelfTestEntry] = []) {
    self.schemaVersion = Self.currentSchemaVersion
    self.entries = entries
  }
}

public enum ClockSelfTestStore {
  /// A missing file is an empty one.
  public static func load(from url: URL) throws -> ClockSelfTestFile {
    try VersionedFile.load(
      ClockSelfTestFile.self, from: url, supportedVersion: ClockSelfTestFile.currentSchemaVersion,
      errorCode: "clockSelfTestUnreadable", noun: "clock self-test") ?? ClockSelfTestFile()
  }

  /// Stores `entry`, replacing the earlier entry of the same key; every other key is untouched.
  /// Entries keep first-seen order, so a refresh does not reshuffle the file.
  public static func record(_ entry: ClockSelfTestEntry, in url: URL) throws {
    var file = try load(from: url)
    if let index = file.entries.firstIndex(where: { $0.key == entry.key }) {
      file.entries[index] = entry
    } else {
      file.entries.append(entry)
    }
    try VersionedFile.save(
      file, to: url, errorCode: "clockSelfTestUnwritable", noun: "clock self-test")
  }

  public static func entry(for key: ClockSelfTestKey, in url: URL) throws -> ClockSelfTestEntry? {
    try load(from: url).entries.first { $0.key == key }
  }
}
