import CoreServices
import Darwin
import Foundation

/// The app that owns microphone consent for this process (RESEARCH P4). macOS asks about the
/// responsible app, not about SoundPing: a CLI run from Ghostty needs Ghostty enabled, a CLI an
/// agent starts needs the agent's host enabled.
public struct ResponsibleApp: Sendable, Equatable {
  public var name: String
  public var bundleId: String?
  /// `processTree` when the parent chain led to an app bundle; `env (likely)` for an environment
  /// fallback, which anyone can set; `unknown` when nothing could be found.
  public var detectedVia: String

  public init(name: String, bundleId: String? = nil, detectedVia: String) {
    self.name = name
    self.bundleId = bundleId
    self.detectedVia = detectedVia
  }
}

public protocol ResponsibleAppResolving: Sendable {
  func resolve() -> ResponsibleApp
}

/// Parent and executable lookups for a process id, so the walk can be tested without a process tree.
public protocol ProcessInspecting: Sendable {
  func parent(of pid: Int32) -> Int32?
  func executablePath(of pid: Int32) -> String?
}

/// The real process table: `sysctl(KERN_PROC_PID)` for the parent, `proc_pidpath` for the path.
public struct SystemProcessInspector: ProcessInspecting {
  public init() {}

  public func parent(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }

  public func executablePath(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

/// Walks from this process to its parents until an `*.app/Contents/MacOS/` executable shows up.
/// A daemonised multiplexer (a tmux server) re-parents to launchd and ends the walk without an
/// app; the environment then gives a guess, labelled as one (T-01-29).
public struct ProcessTreeResolver: ResponsibleAppResolving {
  private let inspector: any ProcessInspecting
  private let environment: [String: String]
  private let startPid: Int32

  /// The longest parent chain walked; a real one is a dozen deep.
  private static let maxDepth = 64
  private static let appMarker = ".app/Contents/MacOS/"

  public init(
    inspector: any ProcessInspecting = SystemProcessInspector(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    startPid: Int32 = getpid()
  ) {
    self.inspector = inspector
    self.environment = environment
    self.startPid = startPid
  }

  public func resolve() -> ResponsibleApp {
    var pid = startPid
    for _ in 0..<Self.maxDepth {
      if let path = inspector.executablePath(of: pid),
        let identity = Self.identity(forExecutable: path)
      {
        return ResponsibleApp(
          name: identity.name, bundleId: identity.bundleId, detectedVia: "processTree")
      }
      guard let parent = inspector.parent(of: pid), parent > 1, parent != pid else { break }
      pid = parent
    }
    return environmentGuess()
  }

  /// The app a path inside `<name>.app/Contents/MacOS/` belongs to: its display name (else its
  /// bundle name, else the folder name) and bundle id. Nil when the path is not inside an app.
  public static func identity(forExecutable path: String) -> (name: String, bundleId: String?)? {
    guard let marker = path.range(of: appMarker) else { return nil }
    // The bundle folder ends with the `.app` the marker starts with.
    let bundlePath = String(path[path.startIndex..<path.index(marker.lowerBound, offsetBy: 4)])
    return identity(forBundleAt: URL(fileURLWithPath: bundlePath))
  }

  static func identity(forBundleAt url: URL) -> (name: String, bundleId: String?) {
    let bundle = Bundle(url: url)
    func text(_ key: String) -> String? {
      guard let value = bundle?.object(forInfoDictionaryKey: key) as? String else { return nil }
      return value.isEmpty ? nil : value
    }
    let folder = url.deletingPathExtension().lastPathComponent
    let name = text("CFBundleDisplayName") ?? text("CFBundleName") ?? folder
    return (name, bundle?.bundleIdentifier)
  }

  private func environmentGuess() -> ResponsibleApp {
    if let id = environment["__CFBundleIdentifier"], !id.isEmpty {
      return ResponsibleApp(
        name: Self.appName(forBundleIdentifier: id) ?? id, bundleId: id,
        detectedVia: "env (likely)")
    }
    if let program = environment["TERM_PROGRAM"], !program.isEmpty {
      return ResponsibleApp(name: program, bundleId: nil, detectedVia: "env (likely)")
    }
    return ResponsibleApp(name: "your terminal app", bundleId: nil, detectedVia: "unknown")
  }

  private static func appName(forBundleIdentifier id: String) -> String? {
    guard
      let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?
        .takeRetainedValue() as? [URL],
      let first = urls.first
    else { return nil }
    return identity(forBundleAt: first).name
  }
}
