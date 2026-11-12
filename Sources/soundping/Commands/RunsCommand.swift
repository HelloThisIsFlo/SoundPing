import ArgumentParser
import Foundation
import SoundPingKit

/// `soundping runs list | show` (D-02): read saved runs back. Never takes the run lock, so
/// listing works while a run is in progress.
struct RunsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "runs",
    abstract: "List and show saved runs.",
    subcommands: [List.self]
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "List saved runs, newest first."
    )

    @Option(
      help:
        "Absolute store folder. Default: SOUNDPING_HOME, else ~/Library/Application Support/SoundPing."
    )
    var store: String?

    @Flag(help: "Print the listing as one JSON object.")
    var json = false

    func run() async throws {
      try await withErrorReporting(jsonMode: json) {
        let paths = try StorePaths.resolve(
          flag: store, environment: ProcessInfo.processInfo.environment)
        let runs = try RunStore(paths: paths).list()
        if json {
          try Self.writeJSON(runs)
        } else {
          Self.writeTable(runs)
        }
      }
    }

    private struct Envelope: Encodable {
      var schemaVersion = 1
      var runs: [RunListing]
    }

    private static func writeJSON(_ runs: [RunListing]) throws {
      var data = try RunJSON.fileEncoder().encode(Envelope(runs: runs))
      data.append(0x0A)
      FileHandle.standardOutput.write(data)
    }

    private static func writeTable(_ runs: [RunListing]) {
      guard !runs.isEmpty else {
        print("no runs yet")
        return
      }
      let width = runs.map(\.runId.count).max() ?? 0
      let stamp = ISO8601DateFormatter()
      for run in runs {
        let median = run.medianMs.map { String(format: "%.2f ms", $0) } ?? "-"
        let id = run.runId.padding(toLength: width, withPad: " ", startingAt: 0)
        print(
          "\(id)  \(stamp.string(from: run.createdAt))  \(run.label ?? "-")  \(median)  \(run.valid)/\(run.n)"
        )
      }
    }
  }
}
