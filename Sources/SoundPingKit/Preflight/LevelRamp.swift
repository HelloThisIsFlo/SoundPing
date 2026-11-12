import Foundation

/// The gentle auto-ramp (D-14, RESEARCH Pattern 5): start quiet, step up until the chirp is heard
/// clearly, then lock that level for the whole run. It never goes above the ceiling, because the
/// test sound reaches a person's ears (T-01-28; the model is written down at `classify`).
///
/// The ramp is a pure state machine: the coordinator plays a probe at the level it asks for and
/// tells it what was heard. The ceilings (see `classify`) and the 0.9 confidence target are RESEARCH A3 assumptions,
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

  // MARK: Listener, ceiling, template

  /// # The loudness model (T-01-28)
  ///
  /// The test sound may reach someone's ears, so every run and every `--in-channel auto` probe
  /// plays under a ceiling. This comment is the one place the model is written down; the CLI help
  /// of `--listener`, `--max-level` and `--level` says the same in short.
  ///
  /// **1. SoundPing works out the listener from the devices** (`classify`), in this order:
  ///
  /// | Detected listener | Ceiling | When |
  /// |---|---|---|
  /// | headphones | -30 dBFS | any Bluetooth output, or a built-in output that does not report its speakers (`ispk`) |
  /// | loopback | -6 dBFS | a loop SoundPing can see: a `Loop` input channel or a virtual input on the output's own device, or a virtual output into a virtual input |
  /// | speaker | -12 dBFS | the built-in output, only when its data source is the speakers (`ispk`) |
  /// | unknown | -18 dBFS | everything else: USB and other interfaces, and a virtual output heard by a physical input |
  ///
  /// The `--in-channel auto` probe does not know the channel yet, so it only tells headphones
  /// (-30) from everything else (unknown, -18); see `probeLoudness`.
  ///
  /// **2. `--listener` describes the setup when SoundPing cannot tell.** It picks the listener the
  /// run reports and, without `--template`, the chirp band. It can lower the ceiling to that
  /// listener's, never raise it: the ceiling is the lower of the detected listener's and the named
  /// listener's. So `--listener loopback` on headphones, AirPods or an interface stays at -30 or
  /// -18 dBFS.
  ///
  /// **3. `--max-level` is the only way to a louder test sound.** It replaces the ceiling (louder or
  /// quieter) whatever was detected or named, for example `--max-level -18` for a Bluetooth
  /// speaker or `--max-level -6` for a cable loop on an interface.
  ///
  /// **4. `--level` picks a fixed level instead of the ramp**, and is clamped to the ceiling (with a
  /// warning when it was above it).
  ///
  /// Hence the invariant: without `--max-level`, an output treated as headphones never gets a
  /// ceiling above -30 dBFS, whatever the input and whatever `--listener` says.
  ///
  /// Why this table: the headphone check comes first, because a virtual input or a `Loop` channel
  /// on another device returns nothing the output played, so it never lifts the ceiling of an
  /// output that reaches someone's ears. A loop needs the output to feed the input digitally: the
  /// same device, or two virtual devices. A virtual output heard by a microphone is acoustic (a
  /// virtual device that monitors to headphones or speakers), so it is no loop. A Bluetooth output
  /// is nearly always earbuds or headphones. A built-in output is proven to be the speakers
  /// (`ispk`) before it gets the speaker ceiling; a missing or unreadable data source counts as
  /// headphones, because the jack may be its own device with no data source. A wrong guess costs a
  /// speaker user one flag (`--max-level`); the opposite wrong guess would put -12 or -18 dBFS
  /// clicks next to someone's ears. USB outputs stay unknown: there is no reliable way to tell a
  /// headset from an interface, and an interface headphone jack looks like a line out.
  public static func classify(setup: ResolvedSetup, output: DeviceInfo?, input: DeviceInfo?)
    -> ListenerKind
  {
    // Ears first (T-01-28): an output a person hears keeps its own ceiling whatever the input is.
    if outputIsHeadphones(setup: setup, output: output) { return .headphones }

    let outputTransport = output?.transport ?? setup.output.transport
    let inputTransport = input?.transport ?? setup.input.transport
    let sameDevice = setup.output.uid == setup.input.uid
    let looped = setup.inChannelName?.lowercased().hasPrefix("loop") == true
    // A loop needs the output to feed the input digitally: one device (an interface loop channel,
    // a virtual duplex), or a virtual output into a virtual input. A virtual output heard by a
    // physical input is acoustic, and a physical output next to some virtual input is no loop (CR-04).
    let bothVirtual = outputTransport == "virtual" && inputTransport == "virtual"
    if (sameDevice && (looped || inputTransport == "virtual")) || bothVirtual {
      return .loopback
    }
    if outputTransport == "builtIn" { return .speaker }
    return .unknown
  }

  /// Whether the output device is treated as headphones: any Bluetooth output, or a built-in
  /// output unless it is clearly the speakers (see `classify`). Fail safe: prove "speaker" instead
  /// of proving "headphones", so a missing data source picks the quieter ceiling. It depends on the
  /// output device alone, whatever the input is.
  public static func outputIsHeadphones(setup: ResolvedSetup, output: DeviceInfo?) -> Bool {
    let outputTransport = output?.transport ?? setup.output.transport
    if outputTransport == "bluetooth" { return true }
    guard outputTransport == "builtIn" else { return false }
    return output?.output?.dataSource != "ispk"
  }

  public static func ceilingDbfs(for kind: ListenerKind) -> Double {
    switch kind {
    case .loopback: return -6
    case .speaker: return -12
    case .headphones: return -30
    case .unknown: return -18
    }
  }

  /// What set the ceiling of a run or probe.
  public enum CeilingSource: String, Sendable, Equatable {
    /// The listener SoundPing worked out from the devices.
    case devices
    /// `--listener`, because it named a quieter listener than the detected one.
    case listenerFlag
    /// `--max-level`.
    case maxLevel
  }

  /// The listener and ceiling a run or probe plays under (see `classify` for the model).
  public struct Loudness: Sendable, Equatable {
    /// The listener the run reports and picks the chirp band for: `--listener` when given, else
    /// the detected one.
    public var kind: ListenerKind
    /// The listener SoundPing worked out from the devices.
    public var detected: ListenerKind
    public var ceilingDbfs: Double
    public var source: CeilingSource

    /// What set the ceiling, in words, for messages.
    public var ceilingOrigin: String {
      switch source {
      case .devices: return "for a \(detected.rawValue) listener, worked out from the devices"
      case .listenerFlag: return "set by --listener \(kind.rawValue)"
      case .maxLevel: return "set by --max-level"
      }
    }

    /// A note for the run when `--listener` named a louder listener than the devices allow: the
    /// flag did not raise the ceiling, and the user should know why.
    public var listenerNotRaisedWarning: String? {
      guard source == .devices, kind != detected,
        LevelRamp.ceilingDbfs(for: kind) > ceilingDbfs
      else { return nil }
      return String(
        format:
          "--listener %@ does not raise the %.0f dBFS ceiling of a %@ output; only --max-level allows a louder test sound",
        kind.rawValue, ceilingDbfs, detected.rawValue)
    }
  }

  /// Applies `--listener` and `--max-level` to the detected listener: `--max-level` replaces the
  /// ceiling, otherwise it is the lower of the detected and the named listener's ceilings.
  public static func loudness(detected: ListenerKind, options: PreflightOptions) throws -> Loudness
  {
    let kind = options.listener ?? detected
    if let maxLevel = options.maxLevelDbfs {
      return Loudness(
        kind: kind, detected: detected, ceilingDbfs: try validatedMaxLevel(maxLevel),
        source: .maxLevel)
    }
    let fromDevices = ceilingDbfs(for: detected)
    let fromFlag = ceilingDbfs(for: kind)
    if fromFlag < fromDevices {
      return Loudness(kind: kind, detected: detected, ceilingDbfs: fromFlag, source: .listenerFlag)
    }
    return Loudness(kind: kind, detected: detected, ceilingDbfs: fromDevices, source: .devices)
  }

  /// The loudness of a run: the detected listener (`classify`) with the user's options applied.
  public static func runLoudness(
    setup: ResolvedSetup, output: DeviceInfo?, input: DeviceInfo?, options: PreflightOptions
  ) throws -> Loudness {
    try loudness(detected: classify(setup: setup, output: output, input: input), options: options)
  }

  /// The loudness of an `--in-channel auto` probe. The channel is not known yet, so a loop cannot
  /// be seen: the probe tells headphones (-30 dBFS) from everything else (unknown, -18 dBFS), and
  /// never takes a louder detected kind than unknown.
  public static func probeLoudness(
    setup: ResolvedSetup, output: DeviceInfo?, options: PreflightOptions
  ) throws -> Loudness {
    let detected: ListenerKind =
      outputIsHeadphones(setup: setup, output: output) ? .headphones : .unknown
    return try loudness(detected: detected, options: options)
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
