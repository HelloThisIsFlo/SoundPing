import Foundation

/// What macOS says about microphone access for the process that owns consent.
public enum PermissionStatus: String, Codable, Sendable, CaseIterable {
  case authorized, denied, restricted, notDetermined
}

/// The checks that run before a single test sound is played, in a fixed order (ENG-03):
/// microphone permission, then the output's mute and volume, then the level ramp. The first
/// failure ends the run with a named cause; later checks never run.
public struct Preflight: Sendable {
  public let resolver: any ResponsibleAppResolving

  public init(resolver: any ResponsibleAppResolving = ProcessTreeResolver()) {
    self.resolver = resolver
  }

  /// What the permission check found, kept in the saved result.
  public struct PermissionOutcome: Sendable, Equatable {
    public var status: PermissionStatus
    public var app: ResponsibleApp
  }

  /// Asks the backend for the microphone status (a real backend prompts first when the user has
  /// not been asked yet) and fails the run when access is denied or restricted. Without access
  /// macOS delivers silence, not an error, so this check has to come before any hit.
  public func checkPermission(on backend: any AudioBackend) async throws -> PermissionOutcome {
    let status = await backend.permissionStatus()
    let app = resolver.resolve()
    if let error = Self.permissionError(status: status, app: app) { throw error }
    return PermissionOutcome(status: status, app: app)
  }

  /// The named failure for a status, or nil when audio may be captured. `notDetermined` passes:
  /// the backend asked the user and the answer was not recorded, so the capture itself is the judge.
  public static func permissionError(status: PermissionStatus, app: ResponsibleApp)
    -> SoundPingError?
  {
    let word: String
    switch status {
    case .denied: word = "denied"
    case .restricted: word = "restricted"
    case .authorized, .notDetermined: return nil
    }
    var context = [
      "terminalApp": app.name,
      "detectedVia": app.detectedVia,
      "status": status.rawValue,
      "fix": "System Settings → Privacy & Security → Microphone → enable \(app.name), then rerun",
    ]
    if let bundleId = app.bundleId { context["terminalAppBundleId"] = bundleId }
    return .preflight(
      "micPermissionDenied", "Microphone access is \(word) for \(app.name)", context: context)
  }

  /// Fails the run when the output is muted, process-muted or at volume zero. Read only: the
  /// user's volume is never touched (T-01-30).
  public func checkOutput(on backend: any AudioBackend) async throws {
    let state = await backend.outputMuteState()
    if let reason = state.reason { throw Self.mutedError(reason: reason) }
  }

  static func mutedError(reason: String) -> SoundPingError {
    .preflight(
      "outputMuted", "The output is muted: \(reason)",
      context: [
        "reason": reason,
        "fix":
          "unmute the output or raise its volume, then rerun; SoundPing never changes your volume",
      ])
  }

  /// Exact zeros while a test sound plays: no signal path, as opposed to a weak one.
  static func silenceError(device: String, channel: String?) -> SoundPingError {
    let place = channel.map { "\(device), \($0)" } ?? device
    return .preflight(
      "inputDigitalSilence",
      "The input delivered only zeros while a test sound played (\(place))",
      context: [
        "device": device,
        "fix":
          "check that this input channel carries a live source, is not muted, and (for a virtual device) has something routed into it, then rerun",
      ])
  }

  static func clippingError(peakDbfs: Double, levelDbfs: Double) -> SoundPingError {
    .preflight(
      "inputClipping",
      String(
        format:
          "The input peaks at %.1f dBFS (clipping starts at %.0f) with the test sound at %.0f dBFS",
        peakDbfs, LevelRamp.clippingDbfs, levelDbfs),
      context: [
        "peakDbfs": String(peakDbfs), "levelDbfs": String(levelDbfs),
        "fix": "turn the input gain or the loop level down, then rerun",
      ])
  }

  /// Nothing heard even at the ceiling (or at `--level`). The hint names what set the ceiling and
  /// the one flag that raises it, `--max-level` (the model is at `LevelRamp.loudness`).
  static func nothingHeardError(
    loudness: LevelRamp.Loudness, probes: Int, chosenLevel: Double?, terminalApp: String?
  ) -> SoundPingError {
    let detail: String
    if let chosenLevel {
      detail = String(format: "Nothing was heard at the chosen level of %.0f dBFS", chosenLevel)
    } else {
      detail = String(
        format: "Nothing was heard even at the ceiling of %.0f dBFS (%@)",
        loudness.ceilingDbfs, loudness.ceilingOrigin)
    }
    let access = terminalApp.map { " for \($0)" } ?? ""
    var fix =
      "check the cable or loop routing, that microphone access is allowed\(access), the output volume and the input gain, then rerun"
    switch loudness.source {
    case .maxLevel:
      fix += "; the ceiling is your --max-level, raise it only when you know the level is safe"
    case .listenerFlag:
      fix +=
        "; --listener \(loudness.kind.rawValue) lowered the ceiling, so drop it, or allow a louder probe with --max-level only when you know the level is safe"
    case .output where loudness.output == .headphones:
      fix +=
        "; Bluetooth outputs and built-in outputs that do not clearly report their speakers are treated as headphones, and --listener does not change that ceiling, so for a Bluetooth speaker (or any output that is not at your ears) allow a louder probe with --max-level, for example --max-level -18, only when you know the level is safe"
    case .output where loudness.detected == .loopback:
      fix +=
        "; a working loop is heard far below this ceiling, so check the loop routing first; the ceiling comes from the output alone and no loop gets a louder one, so only if the loop really needs more pass --max-level (for example --max-level -6)"
    case .output:
      fix +=
        "; the ceiling comes from the output alone (an interface, a virtual device or a loop gets no louder one, and --listener does not raise it), so only --max-level allows a louder test sound, for example --max-level -6 for a loop that really needs it; pass it only when you know the level is safe"
    }
    return .preflight(
      "nothingHeardAtCeiling", detail,
      context: [
        "ceilingDbfs": String(loudness.ceilingDbfs), "listener": loudness.kind.rawValue,
        "detectedListener": loudness.detected.rawValue, "output": loudness.output.rawValue,
        "ceilingSource": loudness.source.rawValue, "probes": String(probes), "fix": fix,
      ])
  }
}

/// Whether the output is muted at any of the three places the system keeps a mute. Read, never set:
/// the user's volume belongs to the user (T-01-30).
public struct MuteState: Codable, Sendable, Equatable {
  public var deviceMute: Bool?
  public var volumeScalar: Float?
  public var processMute: Bool?

  public init(deviceMute: Bool? = nil, volumeScalar: Float? = nil, processMute: Bool? = nil) {
    self.deviceMute = deviceMute
    self.volumeScalar = volumeScalar
    self.processMute = processMute
  }

  /// Nothing would come out of the speakers.
  public var isMuted: Bool { reason != nil }

  /// Which of the three it is, or nil when the output is audible.
  public var reason: String? {
    if deviceMute == true { return "the output device is muted" }
    if processMute == true { return "the system mutes audio from this process" }
    if let volumeScalar, volumeScalar <= 0 { return "the output volume is at zero" }
    return nil
  }
}

/// Who the test sound is meant for. It picks the chirp band and what a run reports (D-12). It never
/// raises the ceiling, which comes from the output (`LevelRamp.loudness`); `--listener` can only
/// lower it.
public enum ListenerKind: String, Codable, Sendable, CaseIterable {
  case loopback, speaker, headphones, unknown
}

/// What a person can pass to a run to steer the preflight. How the two combine with the output's
/// ceiling is written down at `LevelRamp.loudness`.
public struct PreflightOptions: Sendable, Equatable {
  /// Replaces the ceiling, louder or quieter (`--max-level`). The only way to a louder test sound.
  public var maxLevelDbfs: Double?
  /// Names the listener when SoundPing cannot tell (`--listener`): it picks the reported listener
  /// and the chirp band, and can lower the ceiling to that listener's, never raise it.
  public var listener: ListenerKind?
  /// The chirp band follows the listener unless a template was asked for by name (D-12).
  public var templateFollowsListener: Bool

  public init(
    maxLevelDbfs: Double? = nil, listener: ListenerKind? = nil,
    templateFollowsListener: Bool = false
  ) {
    self.maxLevelDbfs = maxLevelDbfs
    self.listener = listener
    self.templateFollowsListener = templateFollowsListener
  }
}

/// One uncounted test sound of the level ramp. Probes never appear in `hits[]`.
public struct ProbeRecord: Codable, Sendable, Equatable {
  /// −1, −2, … in probe order, so a hit index never collides with a probe.
  public var index: Int
  public var levelDbfs: Double
  public var confidence: Double
  /// Loudest input sample of the listening window, in dBFS.
  public var peakDbfs: Double

  public init(index: Int, levelDbfs: Double, confidence: Double, peakDbfs: Double) {
    self.index = index
    self.levelDbfs = levelDbfs
    self.confidence = confidence
    self.peakDbfs = peakDbfs
  }
}

/// The level every warm-up and measured hit plays at (D-14).
public struct LevelLock: Codable, Sendable, Equatable {
  public var levelDbfs: Double
  public var listenerKind: ListenerKind
  public var ceilingDbfs: Double
  public var templateId: String

  public init(
    levelDbfs: Double, listenerKind: ListenerKind, ceilingDbfs: Double, templateId: String
  ) {
    self.levelDbfs = levelDbfs
    self.listenerKind = listenerKind
    self.ceilingDbfs = ceilingDbfs
    self.templateId = templateId
  }
}

/// What the preflight found, saved with the run.
public struct PreflightReport: Codable, Sendable, Equatable {
  public var permission: PermissionStatus
  public var terminalApp: String?
  public var listenerKind: ListenerKind
  public var ceilingDbfs: Double
  public var lockedLevelDbfs: Double
  public var templateId: String
  public var probes: [ProbeRecord]
  public var warnings: [String]

  public init(
    permission: PermissionStatus, terminalApp: String? = nil, listenerKind: ListenerKind,
    ceilingDbfs: Double, lockedLevelDbfs: Double, templateId: String, probes: [ProbeRecord],
    warnings: [String] = []
  ) {
    self.permission = permission
    self.terminalApp = terminalApp
    self.listenerKind = listenerKind
    self.ceilingDbfs = ceilingDbfs
    self.lockedLevelDbfs = lockedLevelDbfs
    self.templateId = templateId
    self.probes = probes
    self.warnings = warnings
  }
}
