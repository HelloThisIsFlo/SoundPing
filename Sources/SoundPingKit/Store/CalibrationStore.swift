import Foundation

/// What a calibration is stored under: the whole signal path and the settings that shape it
/// (CAL-02, D-09, D-11). Every field must match exactly for a calibration to apply: 48000 and
/// 44100 Hz are different keys, and so are buffers of 128 and 129 frames.
public struct CalibrationKey: Codable, Sendable, Equatable, Hashable {
  public var outputUID: String
  /// 1-based, in the order the run played them.
  public var outChannels: [Int]
  public var inputUID: String
  public var inChannel: Int
  /// The HAL's nominal rate as a Double, compared exactly.
  public var sampleRate: Double
  /// SoundPing's own per-process I/O buffer (RESEARCH P1), not the buffer another app set.
  public var bufferFrames: Int

  public init(
    outputUID: String, outChannels: [Int], inputUID: String, inChannel: Int, sampleRate: Double,
    bufferFrames: Int
  ) {
    self.outputUID = outputUID
    self.outChannels = outChannels
    self.inputUID = inputUID
    self.inChannel = inChannel
    self.sampleRate = sampleRate
    self.bufferFrames = bufferFrames
  }
}

/// Phase 1 stores one kind of calibration: a measured round trip. There is deliberately no
/// "mic delay" case (CAL-02, PROJECT accuracy constraint): a number that hides an uncorrected
/// offset is worse than none, and a round trip is not a part of the chain.
public enum CalibrationKind: String, Codable, Sendable, CaseIterable {
  case roundTrip

  public var label: String {
    switch self {
    case .roundTrip: return "round trip"
    }
  }
}

/// One stored calibration. Values are in frames (Double) and milliseconds.
public struct CalibrationRecord: Codable, Sendable, Equatable {
  public var key: CalibrationKey
  public var kind: CalibrationKind
  public var label: String
  /// Which measurement `valueFrames` and `valueMs` are the median of.
  public var headline: MeasurementKind
  public var valueFrames: Double
  public var valueMs: Double
  public var pathFrames: Double
  public var appRoundTripFrames: Double?
  /// p95 - p5 of the headline measurement.
  public var jitterFrames: Double
  public var valid: Int
  public var n: Int
  public var domain: TimeDomain
  public var runId: String
  public var measuredAt: Date

  public init(
    key: CalibrationKey, kind: CalibrationKind = .roundTrip, headline: MeasurementKind,
    valueFrames: Double, valueMs: Double, pathFrames: Double, appRoundTripFrames: Double?,
    jitterFrames: Double, valid: Int, n: Int, domain: TimeDomain, runId: String, measuredAt: Date
  ) {
    self.key = key
    self.kind = kind
    self.label = kind.label
    self.headline = headline
    self.valueFrames = valueFrames
    self.valueMs = valueMs
    self.pathFrames = pathFrames
    self.appRoundTripFrames = appRoundTripFrames
    self.jitterFrames = jitterFrames
    self.valid = valid
    self.n = n
    self.domain = domain
    self.runId = runId
    self.measuredAt = measuredAt
  }
}

/// What a result says about the calibration its run produced.
public struct CalibrationRef: Codable, Sendable, Equatable {
  public var key: CalibrationKey
  public var kind: CalibrationKind
  public var label: String
  /// False when the run failed the valid-hit gate and so left nothing behind.
  public var stored: Bool

  public init(key: CalibrationKey, kind: CalibrationKind = .roundTrip, stored: Bool) {
    self.key = key
    self.kind = kind
    self.label = kind.label
    self.stored = stored
  }
}

/// `<store>/calibrations.json` (schemaVersion 1).
public struct CalibrationFile: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var calibrations: [CalibrationRecord]

  public init(calibrations: [CalibrationRecord] = []) {
    self.schemaVersion = Self.currentSchemaVersion
    self.calibrations = calibrations
  }
}

public enum CalibrationStore {
  /// A missing file is an empty one. Another schemaVersion or malformed JSON is a usage error that
  /// names the file, never a crash (T-01-21, ASVS V5).
  public static func load(from url: URL) throws -> CalibrationFile {
    try VersionedFile.load(
      CalibrationFile.self, from: url, supportedVersion: CalibrationFile.currentSchemaVersion,
      errorCode: "calibrationsUnreadable", noun: "calibrations") ?? CalibrationFile()
  }

  /// Stores `record`, replacing the earlier record of the same key; every other key is untouched.
  /// Records keep first-seen order, so a refresh does not reshuffle the file. A file this build
  /// cannot read is never overwritten.
  public static func record(_ record: CalibrationRecord, in url: URL) throws {
    var file = try load(from: url)
    if let index = file.calibrations.firstIndex(where: { $0.key == record.key }) {
      file.calibrations[index] = record
    } else {
      file.calibrations.append(record)
    }
    try VersionedFile.save(
      file, to: url, errorCode: "calibrationsUnwritable", noun: "calibrations")
  }

  public static func calibration(for key: CalibrationKey, in url: URL) throws -> CalibrationRecord?
  {
    try load(from: url).calibrations.first { $0.key == key }
  }
}
