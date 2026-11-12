import Foundation

/// What a calibration is stored under: the whole signal path and the settings that shape it
/// (CAL-02, D-09, D-11). Every field must match exactly for a calibration to apply: 48000 and
/// 44100 Hz are different keys, and so are buffers of 128 and 129 frames. The two devices of a
/// run each have their own buffer, so the output's and the input's are separate fields: 256 out +
/// 128 in and 128 out + 256 in are different setups even though both sum to the same.
public struct CalibrationKey: Codable, Sendable, Equatable, Hashable {
  public var outputUID: String
  /// 1-based, in the order the run played them.
  public var outChannels: [Int]
  public var inputUID: String
  public var inChannel: Int
  /// The HAL's nominal rate as a Double, compared exactly.
  public var sampleRate: Double
  /// SoundPing's own per-process I/O buffer on the output device (RESEARCH P1), not the buffer
  /// another app set. Zero only in a key read from a pre-split file, which never matches.
  public var outputBufferFrames: Int
  /// The same on the input device.
  public var inputBufferFrames: Int

  public init(
    outputUID: String, outChannels: [Int], inputUID: String, inChannel: Int, sampleRate: Double,
    outputBufferFrames: Int, inputBufferFrames: Int
  ) {
    self.outputUID = outputUID
    self.outChannels = outChannels
    self.inputUID = inputUID
    self.inChannel = inChannel
    self.sampleRate = sampleRate
    self.outputBufferFrames = outputBufferFrames
    self.inputBufferFrames = inputBufferFrames
  }

  /// Schema 1 keys held one `bufferFrames`, the input device's, and said nothing about the
  /// output's. Such a key reads back with `outputBufferFrames == 0`, a size no device has, so it
  /// can never equal the key of a new run: the old calibration stays in the file, unused, and the
  /// setup is simply calibrated once more. Guessing the output size from the input's would let a
  /// two-device calibration match a setup whose output buffer was different.
  private enum LegacyKeys: String, CodingKey { case bufferFrames }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    outputUID = try c.decode(String.self, forKey: .outputUID)
    outChannels = try c.decode([Int].self, forKey: .outChannels)
    inputUID = try c.decode(String.self, forKey: .inputUID)
    inChannel = try c.decode(Int.self, forKey: .inChannel)
    sampleRate = try c.decode(Double.self, forKey: .sampleRate)
    if let inBuffer = try c.decodeIfPresent(Int.self, forKey: .inputBufferFrames) {
      inputBufferFrames = inBuffer
      outputBufferFrames = try c.decode(Int.self, forKey: .outputBufferFrames)
    } else {
      let legacy = try decoder.container(keyedBy: LegacyKeys.self)
      inputBufferFrames = try legacy.decode(Int.self, forKey: .bufferFrames)
      outputBufferFrames = 0
    }
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

/// `<store>/calibrations.json` (schemaVersion 2). Version 1 keyed a calibration on one buffer
/// size; a version 1 file is still read, its records never match a new run (see
/// `CalibrationKey`), and the first write after it brings the file to version 2.
public struct CalibrationFile: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 2
  /// Older versions this build can still read.
  static let readableSchemaVersions: Set<Int> = [1]

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
      alsoReads: CalibrationFile.readableSchemaVersions, errorCode: "calibrationsUnreadable",
      noun: "calibrations") ?? CalibrationFile()
  }

  /// Stores `record`, replacing the earlier record of the same key; every other key is untouched.
  /// Records keep first-seen order, so a refresh does not reshuffle the file. A file this build
  /// cannot read is never overwritten.
  public static func record(_ record: CalibrationRecord, in url: URL) throws {
    var file = try load(from: url)
    file.schemaVersion = CalibrationFile.currentSchemaVersion
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
