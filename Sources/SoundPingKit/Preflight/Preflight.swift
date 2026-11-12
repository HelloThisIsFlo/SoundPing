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
