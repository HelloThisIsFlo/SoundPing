import ArgumentParser
import Foundation
import SoundPingKit

/// What a failure puts on each stream and the exit code it ends the process with.
struct ErrorReport: Equatable {
  /// One line for stdout, or nil when stdout must stay untouched.
  var stdout: String?
  var stderr: [String]
  var exitCode: Int32
}

/// A failure that struck after the run's result was already printed to stdout (a quality gate).
/// Stdout keeps the result as its only content; the failure goes to stderr and the exit code.
struct FailedAfterResult: Error {
  var error: SoundPingError
}

enum ErrorEnvelope {
  private static let reserved: Set<String> = ["schemaVersion", "type", "kind", "code", "detail"]

  /// The single JSON line an agent reads on stdout in --json and --ndjson modes:
  /// `schemaVersion`, `type: "error"`, `kind`, `code`, `detail`, then every context key at the
  /// top level. Keys are sorted. A context key can never overwrite one of the five fixed fields.
  static func line(for error: SoundPingError) -> String {
    var object: [String: Any] = error.context.filter { !reserved.contains($0.key) }
    object["schemaVersion"] = RunResult.currentSchemaVersion
    object["type"] = "error"
    object["kind"] = error.kind.rawValue
    object["code"] = error.code
    object["detail"] = error.detail
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else {
      return
        #"{"code":"\#(error.code)","kind":"\#(error.kind.rawValue)","schemaVersion":1,"type":"error"}"#
    }
    return String(decoding: data, as: UTF8.self)
  }
}

enum ErrorReporting {
  static func report(for error: Error, jsonMode: Bool) -> ErrorReport {
    switch error {
    case let failed as FailedAfterResult:
      return ErrorReport(
        stdout: nil, stderr: humanLines(for: failed.error),
        exitCode: ExitCodes.code(for: failed.error.kind))
    case let known as SoundPingError:
      return ErrorReport(
        stdout: jsonMode ? ErrorEnvelope.line(for: known) : nil, stderr: humanLines(for: known),
        exitCode: ExitCodes.code(for: known.kind))
    default:
      let unknown = SoundPingError.internalFailure("internal", "\(error)")
      return ErrorReport(
        stdout: jsonMode ? ErrorEnvelope.line(for: unknown) : nil, stderr: humanLines(for: unknown),
        exitCode: ExitCodes.code(for: unknown.kind))
    }
  }

  /// `error: <code>: <detail>`, plus `fix: …` when the error knows one.
  static func humanLines(for error: SoundPingError) -> [String] {
    var lines = ["error: \(error.code): \(error.detail)"]
    if let fix = error.context["fix"] { lines.append("fix: \(fix)") }
    return lines
  }
}

/// The quality gate after a completed run (D-03 gate class).
enum RunGate {
  /// `ceil(minValidFraction * hits)`. The small offset keeps `0.3 * 10`, which floating point
  /// makes 3.0000000000000004, from demanding a fourth hit.
  static func requiredValid(hits: Int, minValidFraction: Double) -> Int {
    Int((minValidFraction * Double(hits) - 1e-9).rounded(.up))
  }

  /// nil when enough measured hits gave a number. The run is saved either way.
  static func check(_ result: RunResult) -> SoundPingError? {
    let hits = result.parameters.hits
    let valid = result.measured.path?.valid ?? 0
    let required = requiredValid(hits: hits, minValidFraction: result.parameters.minValidFraction)
    guard valid < required else { return nil }
    return SoundPingError(
      kind: .gate, code: "tooFewValidHits",
      detail:
        "only \(valid) of \(hits) measured hits gave a number; at least \(required) are needed. The run is saved.",
      context: [
        "valid": String(valid), "hits": String(hits), "required": String(required),
        "runPath": result.runPath,
        "fix": "see rejectedCounts in the saved result for why hits were rejected, then run again",
      ])
  }
}

/// Every command body runs inside this, so error output has one home: the JSON envelope on
/// stdout in the data modes, `error:` lines on stderr, and one exit code per failure class.
func withErrorReporting(jsonMode: Bool, _ body: () async throws -> Void) async throws {
  do {
    try await body()
  } catch let error as ExitCode {
    throw error
  } catch let error as CleanExit {
    throw error
  } catch let error as ValidationError {
    throw error
  } catch {
    let report = ErrorReporting.report(for: error, jsonMode: jsonMode)
    if let line = report.stdout { Output.writeLine(line) }
    for line in report.stderr { Output.logLine(line) }
    throw ExitCode(report.exitCode)
  }
}
