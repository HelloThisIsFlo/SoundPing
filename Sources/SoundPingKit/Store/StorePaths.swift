import Foundation

/// Where everything lives on disk (D-06). The CLI, the tests and the later app resolve the same
/// layout; `--store` and `SOUNDPING_HOME` isolate it completely for CI.
public struct StorePaths: Sendable, Equatable {
  public let root: URL
  public let runs: URL
  public let calibrations: URL
  public let clockSelfTest: URL
  public let setups: URL
  public let runLock: URL
  /// Where the root came from: `flag`, `env` or `default`.
  public let source: String

  /// `--store` flag, else `SOUNDPING_HOME`, else `~/Library/Application Support/SoundPing`.
  /// A relative root is refused (T-01-08). Creates the root and `runs/`.
  public static func resolve(flag: String?, environment: [String: String]) throws -> StorePaths {
    let rawRoot: String
    let source: String
    if let flag {
      rawRoot = flag
      source = "flag"
    } else if let env = environment["SOUNDPING_HOME"], !env.isEmpty {
      rawRoot = env
      source = "env"
    } else {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      rawRoot = support.appendingPathComponent("SoundPing", isDirectory: true).path
      source = "default"
    }

    guard rawRoot.hasPrefix("/") else {
      throw SoundPingError.usage(
        "invalidStorePath",
        "the store root must be an absolute path, got '\(rawRoot)'",
        context: ["path": rawRoot, "source": source])
    }

    let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
    let runs = root.appendingPathComponent("runs", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    } catch {
      throw SoundPingError.usage(
        "invalidStorePath",
        "cannot create the store at '\(root.path)': \(error.localizedDescription)",
        context: ["path": root.path, "source": source])
    }

    return StorePaths(
      root: root,
      runs: runs,
      calibrations: root.appendingPathComponent("calibrations.json"),
      clockSelfTest: root.appendingPathComponent("clock-selftest.json"),
      setups: root.appendingPathComponent("setups.json"),
      runLock: root.appendingPathComponent(".run.lock"),
      source: source)
  }
}
