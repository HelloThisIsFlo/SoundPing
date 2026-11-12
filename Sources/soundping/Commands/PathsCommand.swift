import ArgumentParser
import Foundation
import SoundPingKit

/// `soundping paths` (D-06): every store path, absolute, and which setting chose the root, so
/// agents never have to quote "Application Support" by hand. Read-only: it resolves `StorePaths`
/// directly and never takes the run lock.
struct PathsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "paths",
    abstract: "Print the store folder and every file SoundPing keeps in it."
  )

  @Option(
    help:
      "Absolute store folder. Default: SOUNDPING_HOME, else ~/Library/Application Support/SoundPing."
  )
  var store: String?

  @Flag(help: "Print the paths as one JSON object.")
  var json = false

  private struct Envelope: Encodable {
    var schemaVersion = 1
    var root: String
    var runs: String
    var calibrations: String
    var clockSelfTest: String
    var setups: String
    var runLock: String
    var source: String
  }

  func run() async throws {
    try await withErrorReporting(jsonMode: json) {
      let paths = try StorePaths.resolve(
        flag: store, environment: ProcessInfo.processInfo.environment)
      let envelope = Envelope(
        root: paths.root.path, runs: paths.runs.path, calibrations: paths.calibrations.path,
        clockSelfTest: paths.clockSelfTest.path, setups: paths.setups.path,
        runLock: paths.runLock.path, source: paths.source)
      if json {
        try writeJSONLine(envelope)
      } else {
        print("root: \(envelope.root)")
        print("runs: \(envelope.runs)")
        print("calibrations: \(envelope.calibrations)")
        print("clockSelfTest: \(envelope.clockSelfTest)")
        print("setups: \(envelope.setups)")
        print("runLock: \(envelope.runLock)")
        print("source: \(envelope.source)")
      }
    }
  }
}
