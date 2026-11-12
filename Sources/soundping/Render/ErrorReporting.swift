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
  /// The single JSON line an agent reads on stdout in --json and --ndjson modes.
  static func line(for error: SoundPingError) -> String {
    ""
  }
}

enum ErrorReporting {
  static func report(for error: Error, jsonMode: Bool) -> ErrorReport {
    ErrorReport(stdout: nil, stderr: [], exitCode: 0)
  }
}

/// The quality gate after a completed run (D-03 gate class).
enum RunGate {
  /// `ceil(minValidFraction * hits)`.
  static func requiredValid(hits: Int, minValidFraction: Double) -> Int {
    0
  }

  static func check(_ result: RunResult) -> SoundPingError? {
    nil
  }
}

/// Every command body runs inside this, so error output has one home.
func withErrorReporting(jsonMode: Bool, _ body: () async throws -> Void) async throws {
  _ = jsonMode
  do {
    try await body()
  } catch let error as SoundPingError {
    FileHandle.standardError.write(Data("error: \(error.code): \(error.detail)\n".utf8))
    throw ExitCode(1)
  } catch let error as ExitCode {
    throw error
  } catch let error as CleanExit {
    throw error
  } catch {
    FileHandle.standardError.write(Data("error: internal: \(error)\n".utf8))
    throw ExitCode(1)
  }
}
