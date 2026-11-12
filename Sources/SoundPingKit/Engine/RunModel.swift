import Foundation

// The Codable contract every renderer and the later app read (D-03).
// `--json` output == run.json == what the app reads. Enums with payloads are hand-coded with a
// `type` discriminator; synthesized enum coding is never relied on (RESEARCH Pattern 6).

public enum RunPhase: String, Codable, Sendable { case probe, warmup, measure }

public enum RejectionReason: String, Codable, Sendable, CaseIterable {
  case noPeak, lowConfidence, ambiguousPeaks, clipped, discontinuity, outsideWindow
}

public struct HitRecord: Codable, Sendable, Equatable {
  public var index: Int
  public var phase: RunPhase
  public var outputFrame: Int64
  public var latencyFrames: Double?
  public var latencyMs: Double?
  public var confidence: Double?
  public var psr: Double?
  public var rejection: RejectionReason?

  public init(
    index: Int,
    phase: RunPhase,
    outputFrame: Int64,
    latencyFrames: Double? = nil,
    latencyMs: Double? = nil,
    confidence: Double? = nil,
    psr: Double? = nil,
    rejection: RejectionReason? = nil
  ) {
    self.index = index
    self.phase = phase
    self.outputFrame = outputFrame
    self.latencyFrames = latencyFrames
    self.latencyMs = latencyMs
    self.confidence = confidence
    self.psr = psr
    self.rejection = rejection
  }
}

public struct StatValue: Codable, Sendable, Equatable {
  public var frames: Double
  public var ms: Double

  public init(frames: Double, ms: Double) {
    self.frames = frames
    self.ms = ms
  }
}

public struct SummaryStats: Codable, Sendable, Equatable {
  /// Measure-phase hits fired.
  public var n: Int
  /// Measure-phase hits that produced a number.
  public var valid: Int
  public var median: StatValue?
  public var p5: StatValue?
  public var p95: StatValue?
  /// p95 - p5.
  public var jitter: StatValue?
  public var min: StatValue?
  public var max: StatValue?

  public init(
    n: Int, valid: Int, median: StatValue? = nil, p5: StatValue? = nil, p95: StatValue? = nil,
    jitter: StatValue? = nil, min: StatValue? = nil, max: StatValue? = nil
  ) {
    self.n = n
    self.valid = valid
    self.median = median
    self.p5 = p5
    self.p95 = p95
    self.jitter = jitter
    self.min = min
    self.max = max
  }
}

public struct Histogram: Codable, Sendable, Equatable {
  public var binWidthFrames: Double
  public var firstBinStartFrames: Double
  public var counts: [Int]

  public init(binWidthFrames: Double, firstBinStartFrames: Double, counts: [Int]) {
    self.binWidthFrames = binWidthFrames
    self.firstBinStartFrames = firstBinStartFrames
    self.counts = counts
  }
}

public enum MeasurementKind: String, Codable, Sendable { case path, appRoundTrip, ioOffset }
public enum TimeDomain: String, Codable, Sendable { case sample, host }

public struct Measured: Codable, Sendable, Equatable {
  public var headline: MeasurementKind
  public var domain: TimeDomain
  public var path: SummaryStats?
  public var appRoundTrip: SummaryStats?
  public var ioOffset: SummaryStats?

  public init(
    headline: MeasurementKind, domain: TimeDomain, path: SummaryStats? = nil,
    appRoundTrip: SummaryStats? = nil, ioOffset: SummaryStats? = nil
  ) {
    self.headline = headline
    self.domain = domain
    self.path = path
    self.appRoundTrip = appRoundTrip
    self.ioOffset = ioOffset
  }

  /// The statistics of the number this run leads with.
  public var headlineStats: SummaryStats? {
    switch headline {
    case .path: return path
    case .appRoundTrip: return appRoundTrip
    case .ioOffset: return ioOffset
    }
  }
}

public struct Segment: Codable, Sendable, Equatable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public enum CorrectionSource: String, Codable, Sendable { case measured, halReported, userEntered }

public struct Correction: Codable, Sendable, Equatable {
  public var name: String
  public var valueFrames: Double
  public var valueMs: Double
  public var source: CorrectionSource
  public var calibrationKey: String?

  public init(
    name: String, valueFrames: Double, valueMs: Double, source: CorrectionSource,
    calibrationKey: String? = nil
  ) {
    self.name = name
    self.valueFrames = valueFrames
    self.valueMs = valueMs
    self.source = source
    self.calibrationKey = calibrationKey
  }
}

/// The setup as it was when the run happened: every `ResolvedSetup` field plus what the
/// backend actually delivered.
public struct SetupSnapshot: Codable, Sendable, Equatable {
  public var output: DeviceRef
  public var input: DeviceRef
  public var outChannels: [Int]
  public var inChannel: Int
  public var outChannelNames: [String]
  public var inChannelName: String?
  public var requestedBufferFrames: Int?
  public var setupName: String?
  public var midiOut: MIDIRef?
  public var warnings: [String]
  public var sampleRate: Double
  public var bufferFrames: Int
  public var simulated: Bool

  public init(setup: ResolvedSetup, sampleRate: Double, bufferFrames: Int, simulated: Bool) {
    self.output = setup.output
    self.input = setup.input
    self.outChannels = setup.outChannels
    self.inChannel = setup.inChannel
    self.outChannelNames = setup.outChannelNames
    self.inChannelName = setup.inChannelName
    self.requestedBufferFrames = setup.requestedBufferFrames
    self.setupName = setup.setupName
    self.midiOut = setup.midiOut
    self.warnings = setup.warnings
    self.sampleRate = sampleRate
    self.bufferFrames = bufferFrames
    self.simulated = simulated
  }
}

public struct RecipeRef: Codable, Sendable, Equatable {
  public var id: String
  public var version: Int

  public init(id: String, version: Int) {
    self.id = id
    self.version = version
  }
}

public struct RunResult: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var runId: String
  public var runPath: String
  public var createdAt: Date
  public var toolVersion: String
  public var os: String
  public var recipe: RecipeRef
  public var label: String?
  public var tags: [String]
  public var parameters: RunParameters
  public var setup: SetupSnapshot
  public var measured: Measured
  public var histogram: Histogram?
  public var hits: [HitRecord]
  /// Measure-phase rejections, every `RejectionReason` key present (zeros included).
  public var rejectedCounts: [String: Int]
  /// In signal-flow order, listed separately even when a recipe measures them together (ENG-06).
  public var segments: [Segment]
  /// Always encoded, `[]` in Phase 1 (ENG-06).
  public var corrections: [Correction]
  public var simulation: Scenario?
  /// The host-clock self-test of a same-device run (CAL-03, D-05); nil for two-device runs.
  public var selfTest: ClockSelfTestResult?
  /// The timebase the host times of this run were converted with.
  public var hostTimebase: HostTimebase?
  /// What the HAL reports for the devices of this run, shown next to the measured figures and
  /// never applied to them (RES-02, ENG-06). Nil when a device's properties are unknown.
  public var reported: ReportedLatency?
  /// The round-trip calibration this run produced, or `stored: false` when it failed the valid-hit gate (CAL-02).
  public var calibration: CalibrationRef?

  public init(
    schemaVersion: Int = RunResult.currentSchemaVersion,
    runId: String,
    runPath: String,
    createdAt: Date,
    toolVersion: String,
    os: String,
    recipe: RecipeRef,
    label: String?,
    tags: [String],
    parameters: RunParameters,
    setup: SetupSnapshot,
    measured: Measured,
    histogram: Histogram?,
    hits: [HitRecord],
    rejectedCounts: [String: Int],
    segments: [Segment],
    corrections: [Correction],
    simulation: Scenario?,
    selfTest: ClockSelfTestResult? = nil,
    hostTimebase: HostTimebase? = nil,
    reported: ReportedLatency? = nil,
    calibration: CalibrationRef? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.runId = runId
    self.runPath = runPath
    self.createdAt = createdAt
    self.toolVersion = toolVersion
    self.os = os
    self.recipe = recipe
    self.label = label
    self.tags = tags
    self.parameters = parameters
    self.setup = setup
    self.measured = measured
    self.histogram = histogram
    self.hits = hits
    self.rejectedCounts = rejectedCounts
    self.segments = segments
    self.corrections = corrections
    self.simulation = simulation
    self.selfTest = selfTest
    self.hostTimebase = hostTimebase
    self.reported = reported
    self.calibration = calibration
  }
}

/// What the run announces before the first hit.
public struct ArmedInfo: Codable, Sendable, Equatable {
  public var runId: String
  public var recipe: RecipeRef
  public var parameters: RunParameters
  public var setup: SetupSnapshot

  public init(runId: String, recipe: RecipeRef, parameters: RunParameters, setup: SetupSnapshot) {
    self.runId = runId
    self.recipe = recipe
    self.parameters = parameters
    self.setup = setup
  }
}

public enum RunEvent: Sendable, Equatable {
  case armed(ArmedInfo)
  case hit(HitRecord)
  case rejected(HitRecord)
  case aborted(SoundPingError)
  /// The host-clock self-test, emitted after the last hit of a same-device run and before `finished`.
  case selfTest(ClockSelfTestResult)
  case finished(RunResult)
}

extension RunEvent: Codable {
  private enum Key: String, CodingKey { case type, result }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .armed(let info):
      try container.encode("armed", forKey: .type)
      try info.encode(to: encoder)
    case .hit(let record):
      try container.encode("hit", forKey: .type)
      try record.encode(to: encoder)
    case .rejected(let record):
      try container.encode("rejected", forKey: .type)
      try record.encode(to: encoder)
    case .aborted(let error):
      try container.encode("aborted", forKey: .type)
      try error.encode(to: encoder)
    case .selfTest(let result):
      try container.encode("selfTest", forKey: .type)
      try result.encode(to: encoder)
    case .finished(let result):
      try container.encode("finished", forKey: .type)
      try container.encode(result, forKey: .result)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "armed": self = .armed(try ArmedInfo(from: decoder))
    case "hit": self = .hit(try HitRecord(from: decoder))
    case "rejected": self = .rejected(try HitRecord(from: decoder))
    case "aborted": self = .aborted(try SoundPingError(from: decoder))
    case "selfTest": self = .selfTest(try ClockSelfTestResult(from: decoder))
    case "finished": self = .finished(try container.decode(RunResult.self, forKey: .result))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "unknown RunEvent type '\(type)'")
    }
  }
}

/// The encoders and decoder behind `--json`, `--ndjson` and run.json, so all of them agree byte for byte.
public enum RunJSON {
  public static func fileEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  public static func lineEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
