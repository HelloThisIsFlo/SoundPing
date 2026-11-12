import ArgumentParser
import Foundation
import SoundPingKit

/// Every command body runs inside this, so error output has one home. For now it prints
/// `error: <code>: <detail>` to stderr and exits 1; the JSON envelope and one exit code per
/// error class replace the internals later without touching any command.
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
