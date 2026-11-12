import Foundation

/// One row of `soundping runs list`: enough to find a run without opening its run.json.
public struct RunListing: Codable, Sendable, Equatable {
  public var runId: String
  public var createdAt: Date
  public var recipe: String
  public var label: String?
  public var tags: [String]
  /// Headline median in milliseconds; nil when the run produced no valid hit.
  public var medianMs: Double?
  public var valid: Int
  public var n: Int
  public var runPath: String

  public init(
    runId: String, createdAt: Date, recipe: String, label: String?, tags: [String],
    medianMs: Double?, valid: Int, n: Int, runPath: String
  ) {
    self.runId = runId
    self.createdAt = createdAt
    self.recipe = recipe
    self.label = label
    self.tags = tags
    self.medianMs = medianMs
    self.valid = valid
    self.n = n
    self.runPath = runPath
  }
}

/// Reads and writes runs as `<runs>/<yyyyMMdd'T'HHmmss'Z'>-<slug>/run.json` (D-06, RESEARCH Pattern 9).
public struct RunStore: Sendable {
  public let paths: StorePaths
  /// Kept only so the run lock lives exactly as long as the store that was handed out with it.
  private let heldLock: RunLock?

  public init(paths: StorePaths) {
    self.paths = paths
    self.heldLock = nil
  }

  private init(paths: StorePaths, heldLock: RunLock?) {
    self.paths = paths
    self.heldLock = heldLock
  }

  /// The same store, holding `<root>/.run.lock` until the last copy goes away (T-01-06).
  public func acquiringRunLock() throws -> RunStore {
    RunStore(paths: paths, heldLock: try RunLock.acquire(at: paths.runLock))
  }

  /// Longest slug kept, in characters.
  public static let maxSlugLength = 48

  /// The recipe id plus the label, lowercased, every character outside [a-z0-9] (non-ASCII
  /// included) turned into `-`, repeats collapsed, edge dashes trimmed, capped at 48 characters
  /// (T-01-05). No label gives the recipe id.
  public static func slug(recipeId: String, label: String?) -> String {
    var raw = recipeId
    if let label, !label.isEmpty { raw += "-" + label }
    var out = ""
    var lastWasDash = true
    for scalar in raw.lowercased().unicodeScalars {
      let isLetter = scalar.value >= 0x61 && scalar.value <= 0x7A
      let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
      if isLetter || isDigit {
        out.unicodeScalars.append(scalar)
        lastWasDash = false
      } else if !lastWasDash {
        out.append("-")
        lastWasDash = true
      }
    }
    if out.count > maxSlugLength { out = String(out.prefix(maxSlugLength)) }
    while out.hasSuffix("-") { out.removeLast() }
    return out
  }

  /// The folder name a run created at `createdAt` gets; also its `runId`.
  public static func folderName(recipeId: String, label: String?, createdAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return "\(formatter.string(from: createdAt))-\(slug(recipeId: recipeId, label: label))"
  }

  /// Creates the run folder. A name that is already taken gets `-2`, `-3`, … so two runs created in
  /// the same second never share a folder and a run is never overwritten (RUN-01).
  public func createRunFolder(recipeId: String, label: String?, createdAt: Date) throws -> URL {
    let base = Self.folderName(recipeId: recipeId, label: label, createdAt: createdAt)
    for attempt in 1...1000 {
      let folder = try runsChild(named: attempt == 1 ? base : "\(base)-\(attempt)")
      if FileManager.default.fileExists(atPath: folder.path) { continue }
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
      } catch {
        throw SoundPingError.internalFailure(
          "runFolderUnavailable",
          "cannot create the run folder '\(folder.path)': \(error.localizedDescription)",
          context: ["path": folder.path])
      }
    }
    throw SoundPingError.internalFailure(
      "runFolderUnavailable",
      "no free run folder name under '\(paths.runs.path)' for '\(base)'",
      context: ["path": paths.runs.path])
  }

  /// Joins a bare name under `runs/` and proves the result is still inside it (defence in depth).
  func runsChild(named name: String) throws -> URL {
    let child = paths.runs.appendingPathComponent(name, isDirectory: true).standardizedFileURL
    let prefix = paths.runs.standardizedFileURL.path + "/"
    guard !name.isEmpty, !name.contains("/"), name != ".", name != "..",
      child.path.hasPrefix(prefix)
    else {
      throw SoundPingError.usage(
        "unreadableRun", "'\(name)' is not a run id under \(paths.runs.path)",
        context: ["run": name])
    }
    return child
  }

  /// The exact bytes of run.json for a result: sorted keys, pretty printed, one trailing newline.
  /// `--json` prints these same bytes.
  public static func encodedBytes(for result: RunResult) throws -> Data {
    var data = try RunJSON.fileEncoder().encode(result)
    data.append(0x0A)
    return data
  }

  /// Atomically writes run.json into `folder` and returns the bytes written (T-01-07).
  @discardableResult
  public func write(_ result: RunResult, to folder: URL) throws -> Data {
    let data = try Self.encodedBytes(for: result)
    try data.write(to: folder.appendingPathComponent("run.json"), options: .atomic)
    return data
  }

  /// Every readable run under `runs/`, newest first, ties broken by folder name (RUN-01).
  public func list() throws -> [RunListing] {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: paths.runs, includingPropertiesForKeys: nil)
    } catch {
      throw SoundPingError.internalFailure(
        "runStoreUnreadable", "cannot read '\(paths.runs.path)': \(error.localizedDescription)",
        context: ["path": paths.runs.path])
    }
    var rows: [RunListing] = []
    for folder in entries {
      let file = folder.appendingPathComponent("run.json")
      guard let data = try? Data(contentsOf: file),
        let result = try? RunJSON.decoder().decode(RunResult.self, from: data)
      else { continue }
      let stats = result.measured.headlineStats ?? result.measured.path
      rows.append(
        RunListing(
          runId: folder.lastPathComponent, createdAt: result.createdAt, recipe: result.recipe.id,
          label: result.label, tags: result.tags, medianMs: stats?.median?.ms,
          valid: stats?.valid ?? 0, n: stats?.n ?? 0, runPath: folder.path))
    }
    return rows.sorted {
      $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.runId < $1.runId
    }
  }
}

extension RunStore {
  /// The run.json file for a run id (a bare folder name under `runs/`) or an absolute folder path
  /// that holds one. Anything else is `unreadableRun` and nothing outside `runs/` is read (T-01-34).
  func runFile(_ idOrPath: String) throws -> URL {
    let folder: URL
    if idOrPath.hasPrefix("/") {
      folder = URL(fileURLWithPath: idOrPath, isDirectory: true).standardizedFileURL
    } else {
      folder = try runsChild(named: idOrPath)
    }
    let file = folder.appendingPathComponent("run.json")
    guard FileManager.default.fileExists(atPath: file.path) else {
      throw SoundPingError.usage(
        "unreadableRun", "no run.json in '\(folder.path)'", context: ["path": folder.path])
    }
    return file
  }

  /// run.json exactly as stored, byte for byte.
  public func loadBytes(_ idOrPath: String) throws -> Data {
    let file = try runFile(idOrPath)
    do {
      return try Data(contentsOf: file)
    } catch {
      throw SoundPingError.usage(
        "unreadableRun", "cannot read '\(file.path)': \(error.localizedDescription)",
        context: ["path": file.path])
    }
  }

  public func load(_ idOrPath: String) throws -> RunResult {
    let file = try runFile(idOrPath)
    let data = try loadBytes(idOrPath)
    do {
      return try RunJSON.decoder().decode(RunResult.self, from: data)
    } catch {
      throw SoundPingError.usage(
        "unreadableRun", "cannot decode '\(file.path)': \(error.localizedDescription)",
        context: ["path": file.path])
    }
  }
}
