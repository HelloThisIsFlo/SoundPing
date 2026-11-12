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

/// Who the test sound is meant for. It sets how loud the ramp may go and which chirp band fits (D-12, D-14).
public enum ListenerKind: String, Codable, Sendable, CaseIterable {
  case loopback, speaker, headphones, unknown
}

/// What a person can pass to a run to steer the preflight.
public struct PreflightOptions: Sendable, Equatable {
  /// Replaces the listener's ceiling (`--max-level`). The one way to go louder than the default.
  public var maxLevelDbfs: Double?
  /// Overrides the classification of the listener (`--listener`).
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
