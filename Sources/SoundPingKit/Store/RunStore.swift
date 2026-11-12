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

  public init(paths: StorePaths) {
    self.paths = paths
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

  /// Creates the run folder. Refuses to reuse an existing one rather than overwrite a run.
  public func createRunFolder(recipeId: String, label: String?, createdAt: Date) throws -> URL {
    let name = Self.folderName(recipeId: recipeId, label: label, createdAt: createdAt)
    let folder = try runsChild(named: name)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    } catch {
      throw SoundPingError.internalFailure(
        "runFolderUnavailable",
        "cannot create the run folder '\(folder.path)': \(error.localizedDescription)",
        context: ["path": folder.path])
    }
    return folder
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
      let stats = result.measured.path
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
