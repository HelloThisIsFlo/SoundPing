import Foundation

/// The gentle auto-ramp (D-14, RESEARCH Pattern 5): start quiet, step up until the chirp is heard
/// clearly, then lock that level for the whole run. It never goes above the listener's ceiling,
/// because the test sound reaches a person's ears (T-01-28).
///
/// The ramp is a pure state machine: the coordinator plays a probe at the level it asks for and
/// tells it what was heard. The ceilings and the 0.9 confidence target are RESEARCH A3 assumptions,
/// tunable on the bench.
public struct LevelRamp: Sendable {
  public static let firstProbeDbfs = -48.0
  public static let stepUpDb = 6.0
  public static let stepDownDb = 12.0
  public static let floorDbfs = -60.0
  public static let maxClippingRetries = 2
  /// A probe heard this clearly locks the level.
  public static let confidenceTarget = 0.9
  /// The input peak the lock aims for; louder than this (below clipping) still locks, with a warning.
  public static let peakTargetDbfs = -6.0
  /// An input peak at or above this counts as clipping.
  public static let clippingDbfs = -1.0
  /// With a level chosen by the user, a chirp heard below this is not there at all.
  public static let minConfidence = 0.5

  public enum Failure: Sendable, Equatable { case clipping, nothingHeard }

  public enum Step: Sendable, Equatable {
    /// Play the next probe at this level.
    case probe(Double)
    /// Lock this level, with a warning to report when the lock is not clean.
    case lock(Double, warning: String?)
    case fail(Failure)
  }

  // MARK: Listener, ceiling, template

  /// Who is going to hear the test sound. Loopback is a `Loop` input channel or a virtual input
  /// device; the built-in output is headphones on its headphone data source and speakers
  /// otherwise; any other output is unknown, because an interface headphone jack looks like a line out.
  public static func classify(setup: ResolvedSetup, output: DeviceInfo?, input: DeviceInfo?)
    -> ListenerKind
  {
    let inputTransport = input?.transport ?? setup.input.transport
    let looped = setup.inChannelName?.lowercased().hasPrefix("loop") == true
    if looped || inputTransport == "virtual" { return .loopback }

    let outputTransport = output?.transport ?? setup.output.transport
    if outputTransport == "builtIn" {
      return outputIsHeadphones(setup: setup, output: output) ? .headphones : .speaker
    }
    return .unknown
  }

  /// Whether the output device is known to be headphones: the built-in output on its headphone
  /// data source. It depends on the output device alone, whatever the input is.
  public static func outputIsHeadphones(setup: ResolvedSetup, output: DeviceInfo?) -> Bool {
    let outputTransport = output?.transport ?? setup.output.transport
    return outputTransport == "builtIn" && output?.output?.dataSource == "hdpn"
  }

  public static func ceilingDbfs(for kind: ListenerKind) -> Double {
    switch kind {
    case .loopback: return -6
    case .speaker: return -12
    case .headphones: return -30
    case .unknown: return -18
    }
  }

  /// The ceiling of a run: the listener's, or `--max-level` when the user asked for another.
  public static func resolveCeiling(kind: ListenerKind, maxLevelDbfs: Double?) throws -> Double {
    guard let maxLevelDbfs else { return ceilingDbfs(for: kind) }
    guard maxLevelDbfs.isFinite, maxLevelDbfs <= 0 else {
      throw SoundPingError.usage(
        "invalidParameters",
        "--max-level must be 0 dBFS or below, got \(maxLevelDbfs)",
        context: ["parameter": "max-level", "value": String(maxLevelDbfs)])
    }
    return maxLevelDbfs
  }

  /// The chirp band follows the listener (D-12): full range for a cable, the speaker band otherwise.
  public static func templateId(for kind: ListenerKind) -> String {
    kind == .loopback ? "chirp-loopback" : "chirp-speaker"
  }

  /// A loudest-sample magnitude as dBFS. Silence is -200, not -infinity, which JSON cannot carry.
  public static func dbfs(ofAbsolutePeak peak: Float) -> Double {
    guard peak > 0 else { return -200 }
    return Swift.max(-200, 20 * log10(Double(peak)))
  }

  // MARK: The ramp

  private let ceiling: Double
  private let fixedLevel: Double?
  private var clippingRetries = 0

  /// `fixedLevelDbfs` is `--level`: one confirmation probe at that level, no ramp.
  public init(ceilingDbfs: Double, fixedLevelDbfs: Double? = nil) {
    self.ceiling = ceilingDbfs
    // A non-finite level would defeat the ceiling clamp (min(NaN, c) is NaN), so it is dropped.
    self.fixedLevel = fixedLevelDbfs.flatMap { $0.isFinite ? $0 : nil }
  }

  /// The level of the first probe, never above the ceiling.
  public var firstLevel: Double {
    Swift.min(fixedLevel ?? Self.firstProbeDbfs, ceiling)
  }

  /// Takes the answer to the probe just played at `level` and says what to do next.
  public mutating func record(level: Double, confidence: Double, peakDbfs: Double) -> Step {
    if peakDbfs >= Self.clippingDbfs {
      guard fixedLevel == nil, clippingRetries < Self.maxClippingRetries, level > Self.floorDbfs
      else { return .fail(.clipping) }
      clippingRetries += 1
      return .probe(Swift.max(Self.floorDbfs, level - Self.stepDownDb))
    }

    if confidence >= Self.confidenceTarget {
      return .lock(level, warning: peakDbfs > Self.peakTargetDbfs ? "input is hot" : nil)
    }

    if fixedLevel != nil {
      guard confidence >= Self.minConfidence else { return .fail(.nothingHeard) }
      return .lock(
        level,
        warning: String(
          format:
            "the chirp is heard with confidence %.2f at the chosen level, below the %.2f target",
          confidence, Self.confidenceTarget))
    }

    guard level < ceiling else { return .fail(.nothingHeard) }
    return .probe(Swift.min(ceiling, level + Self.stepUpDb))
  }
}
