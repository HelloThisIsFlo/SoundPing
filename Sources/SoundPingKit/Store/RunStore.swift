import Foundation

/// Writes runs as `<runs>/<yyyyMMdd'T'HHmmss'Z'>-<recipe id>/run.json` (D-06, RESEARCH Pattern 9).
public struct RunStore: Sendable {
  public let paths: StorePaths

  public init(paths: StorePaths) {
    self.paths = paths
  }

  /// The folder name a run created at `createdAt` gets; also its `runId`.
  public static func folderName(recipeId: String, label: String?, createdAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return "\(formatter.string(from: createdAt))-\(recipeId)"
  }

  /// Creates the run folder. Refuses to reuse an existing one rather than overwrite a run.
  public func createRunFolder(recipeId: String, label: String?, createdAt: Date) throws -> URL {
    let name = Self.folderName(recipeId: recipeId, label: label, createdAt: createdAt)
    let folder = paths.runs.appendingPathComponent(name, isDirectory: true)
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
}
