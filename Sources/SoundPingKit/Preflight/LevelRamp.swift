import Foundation

/// The gentle auto-ramp (D-14, RESEARCH Pattern 5): start quiet, step up until the chirp is heard
/// clearly, then lock that level for the whole run. It never goes above the ceiling, because the
/// test sound reaches a person's ears (T-01-28; the model is written down at `loudness`).
///
/// The ramp is a pure state machine: the coordinator plays a probe at the level it asks for and
/// tells it what was heard. The ceilings (see `loudness`) and the 0.9 confidence target are RESEARCH A3 assumptions,
/// tunable on the bench.
public struct LevelRamp: Sendable {
  public static let firstProbeDbfs = -48.0
  public static let stepUpDb = 6.0
  public static let stepDownDb = 12.0
  public static let floorDbfs = -60.0
  public static let maxClippingRetries = 2
  /// How often a probe spoilt by an audio glitch is replayed at the same level before the ramp
  /// takes its answer as it is.
  public static let maxGlitchRetries = 3
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

  // MARK: Ceiling, listener, template

  /// # The loudness model (T-01-28)
  ///
  /// The test sound may reach someone's ears, so every run and every `--in-channel auto` probe
  /// plays under a ceiling. This comment is the one place the model is written down; the CLI help
  /// of `--listener`, `--max-level` and `--level`, the `nothingHeardAtCeiling` hint and the README
  /// say the same in short.
  ///
  /// **1. The ceiling is chosen from the output alone** (`outputClass`):
  ///
  /// | Output | Ceiling | Which outputs |
  /// |---|---|---|
  /// | headphones | -30 dBFS | any Bluetooth output, or a built-in output that does not clearly report its speakers (`ispk`) |
  /// | built-in speakers | -12 dBFS | the built-in output, only when its data source is the speakers (`ispk`) |
  /// | other | -18 dBFS | everything else: every interface, every virtual output, every loop |
  ///
  /// The input never changes it. No setup gets a louder ceiling on its own, loops included: the
  /// ramp starts at -48 dBFS and stops at the first clearly heard probe, so a working loop locks
  /// far below -18. Guessing which setups are loops, to allow them more, bought nothing and caused
  /// every hearing-safety regression so far (CR-02 to CR-05).
  ///
  /// The `--in-channel auto` probe plays under exactly this rule too, through `runLoudness`, so
  /// the built-in speakers get -12 there as in a run.
  ///
  /// **2. `--listener` describes the setup.** It picks the listener the run reports and, without
  /// `--template`, the chirp band. It can lower the ceiling to that listener's (headphones -30,
  /// speaker -12, unknown -18; loopback has no ears, so it lowers nothing), never raise it.
  ///
  /// **3. `--max-level` is the only way to a louder test sound.** It replaces the ceiling (louder or
  /// quieter), for example `--max-level -18` for a Bluetooth speaker or `--max-level -6` for a
  /// loop that really needs it.
  ///
  /// **4. `--level` picks a fixed level instead of the ramp**, and is clamped to the ceiling (with a
  /// warning when it was above it).
  ///
  /// Why the output rule: a Bluetooth output is nearly always earbuds or headphones. A built-in
  /// output is proven to be the speakers (`ispk`) before it gets the speaker ceiling; a missing or
  /// unreadable data source counts as headphones, because the jack may be its own device with no
  /// data source (WR-12). USB and other interfaces stay at -18: there is no reliable way to tell a
  /// headset from an interface, and an interface headphone jack looks like a line out. A wrong
  /// guess costs a speaker user one flag (`--max-level`); the opposite wrong guess would put -12 or
  /// -18 dBFS clicks next to someone's ears.
  public static func loudness(
    output: OutputClass, detected: ListenerKind, options: PreflightOptions
  ) throws -> Loudness {
    let kind = options.listener ?? detected
    if let maxLevel = options.maxLevelDbfs {
      return Loudness(
        kind: kind, detected: detected, output: output,
        ceilingDbfs: try validatedMaxLevel(maxLevel), source: .maxLevel)
    }
    let fromOutput = ceilingDbfs(for: output)
    if let named = options.listener.flatMap(listenerCeilingDbfs(for:)), named < fromOutput {
      return Loudness(
        kind: kind, detected: detected, output: output, ceilingDbfs: named, source: .listenerFlag)
    }
    return Loudness(
      kind: kind, detected: detected, output: output, ceilingDbfs: fromOutput, source: .output)
  }

  /// What the ceiling is chosen from: the output device, and nothing else (see `loudness`).
  public enum OutputClass: String, Sendable, Equatable, CaseIterable {
    /// Any Bluetooth output, or a built-in output that does not clearly report its speakers.
    case headphones
    /// The built-in output reporting its speakers (`ispk`).
    case speakers
    /// Everything else: every interface, every virtual output, every loop.
    case other

    /// The output, in words, for messages.
    var phrase: String {
      switch self {
      case .headphones: return "headphones"
      case .speakers: return "the built-in speakers"
      case .other: return "an output that is neither headphones nor the built-in speakers"
      }
    }
  }

  /// Which ceiling the output gets (see `loudness`). It reads the output device alone.
  public static func outputClass(setup: ResolvedSetup, output: DeviceInfo?) -> OutputClass {
    if outputIsHeadphones(setup: setup, output: output) { return .headphones }
    let transport = output?.transport ?? setup.output.transport
    // A built-in output that is not headphones has proven its speakers (`ispk`).
    return transport == "builtIn" ? .speakers : .other
  }

  /// Whether the output device is treated as headphones: any Bluetooth output, or a built-in
  /// output unless it is clearly the speakers. Fail safe: prove "speaker" instead of proving
  /// "headphones", so a missing data source picks the quieter ceiling (WR-12).
  public static func outputIsHeadphones(setup: ResolvedSetup, output: DeviceInfo?) -> Bool {
    let outputTransport = output?.transport ?? setup.output.transport
    if outputTransport == "bluetooth" { return true }
    guard outputTransport == "builtIn" else { return false }
    return output?.output?.dataSource != "ispk"
  }

  public static func ceilingDbfs(for output: OutputClass) -> Double {
    switch output {
    case .headphones: return -30
    case .speakers: return -12
    case .other: return -18
    }
  }

  /// The ceiling `--listener` lowers to: the matching output's. A loop has no ears, so naming it
  /// lowers nothing (nil).
  public static func listenerCeilingDbfs(for kind: ListenerKind) -> Double? {
    switch kind {
    case .headphones: return ceilingDbfs(for: .headphones)
    case .speaker: return ceilingDbfs(for: .speakers)
    case .unknown: return ceilingDbfs(for: .other)
    case .loopback: return nil
    }
  }

  /// The listener a run reports and picks its chirp band for, when `--listener` does not name one.
  /// It never sets the ceiling (see `loudness`): a loop SoundPing can see only picks the
  /// full-range chirp.
  ///
  /// | Detected listener | When |
  /// |---|---|
  /// | headphones | the output is headphones (see `outputClass`) |
  /// | loopback | a `Loop` input channel or a virtual input on the output's own device, or a virtual output into a virtual input |
  /// | speaker | the built-in speakers |
  /// | unknown | everything else |
  public static func classify(setup: ResolvedSetup, output: DeviceInfo?, input: DeviceInfo?)
    -> ListenerKind
  {
    let outputClass = outputClass(setup: setup, output: output)
    if outputClass == .headphones { return .headphones }

    let outputTransport = output?.transport ?? setup.output.transport
    let inputTransport = input?.transport ?? setup.input.transport
    let sameDevice = setup.output.uid == setup.input.uid
    let looped = setup.inChannelName?.lowercased().hasPrefix("loop") == true
    let bothVirtual = outputTransport == "virtual" && inputTransport == "virtual"
    if (sameDevice && (looped || inputTransport == "virtual")) || bothVirtual {
      return .loopback
    }
    return outputClass == .speakers ? .speaker : .unknown
  }

  /// What set the ceiling of a run or probe.
  public enum CeilingSource: String, Sendable, Equatable {
    /// The output device (see `loudness`).
    case output
    /// `--listener`, because it named a quieter listener than the output's ceiling.
    case listenerFlag
    /// `--max-level`.
    case maxLevel
  }

  /// The listener and ceiling a run or probe plays under (see `loudness` for the model).
  public struct Loudness: Sendable, Equatable {
    /// The listener the run reports and picks the chirp band for: `--listener` when given, else
    /// the detected one.
    public var kind: ListenerKind
    /// The listener SoundPing worked out from the devices (`classify`).
    public var detected: ListenerKind
    /// The output the ceiling was chosen from.
    public var output: OutputClass
    public var ceilingDbfs: Double
    public var source: CeilingSource

    public init(
      kind: ListenerKind, detected: ListenerKind, output: OutputClass, ceilingDbfs: Double,
      source: CeilingSource
    ) {
      self.kind = kind
      self.detected = detected
      self.output = output
      self.ceilingDbfs = ceilingDbfs
      self.source = source
    }

    /// What set the ceiling, in words, for messages.
    public var ceilingOrigin: String {
      switch source {
      case .output: return "for \(output.phrase), chosen from the output alone"
      case .listenerFlag: return "set by --listener \(kind.rawValue)"
      case .maxLevel: return "set by --max-level"
      }
    }

    /// A note for the run when `--listener` named a louder listener than the output allows: the
    /// flag did not raise the ceiling, and the user should know why.
    public var listenerNotRaisedWarning: String? {
      guard source == .output, kind != detected,
        (LevelRamp.listenerCeilingDbfs(for: kind) ?? 0) > ceilingDbfs
      else { return nil }
      return String(
        format:
          "--listener %@ does not raise the %.0f dBFS ceiling of %@; only --max-level allows a louder test sound",
        kind.rawValue, ceilingDbfs, output.phrase)
    }
  }

  /// The loudness of a run, and of an `--in-channel auto` probe (which passes its setup before the
  /// channel is known): the output's ceiling with the user's options applied, and the detected
  /// listener for the report and the chirp band.
  public static func runLoudness(
    setup: ResolvedSetup, output: DeviceInfo?, input: DeviceInfo?, options: PreflightOptions
  ) throws -> Loudness {
    try loudness(
      output: outputClass(setup: setup, output: output),
      detected: classify(setup: setup, output: output, input: input), options: options)
  }

  /// `--max-level`, refused unless it is a finite dBFS value of 0 or below.
  public static func validatedMaxLevel(_ maxLevelDbfs: Double) throws -> Double {
    guard maxLevelDbfs.isFinite, maxLevelDbfs <= 0 else {
      throw SoundPingError.usage(
        "invalidParameters",
        "--max-level must be 0 dBFS or below, got \(maxLevelDbfs)",
        context: ["parameter": "max-level", "value": String(maxLevelDbfs)])
    }
    return maxLevelDbfs
  }

  /// What `templateId(for:)` does, in words, for `soundping recipes`.
  public static let templateRule =
    "follows the listener unless --template is given (chirp-loopback for a loop, chirp-speaker otherwise)"

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
