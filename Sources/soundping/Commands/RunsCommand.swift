import ArgumentParser
import Foundation
import SoundPingKit

/// `soundping runs list | show` (D-02): read saved runs back. Never takes the run lock, so
/// listing works while a run is in progress.
struct RunsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "runs",
    abstract: "List and show saved runs.",
    subcommands: [List.self, Show.self]
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

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "show",
      abstract: "Show one saved run, by run id or absolute folder path."
    )

    @Argument(help: "A run id from `runs list`, or the absolute path of a run folder.")
    var run: String

    @Option(
      help:
        "Absolute store folder. Default: SOUNDPING_HOME, else ~/Library/Application Support/SoundPing."
    )
    var store: String?

    @Flag(help: "Print run.json exactly as stored.")
    var json = false

    func run() async throws {
      try await withErrorReporting(jsonMode: json) {
        let paths = try StorePaths.resolve(
          flag: store, environment: ProcessInfo.processInfo.environment)
        let runStore = RunStore(paths: paths)
        if json {
          FileHandle.standardOutput.write(try runStore.loadBytes(run))
        } else {
          Self.writeSummary(try runStore.load(run))
        }
      }
    }

    private static func writeSummary(_ result: RunResult) {
      let ms = { (value: Double?) in value.map { String(format: "%.2f ms", $0) } ?? "-" }
      let stats = result.measured.path
      print("recipe   \(result.recipe.id)")
      print("label    \(result.label ?? "-")")
      print("tags     \(result.tags.isEmpty ? "-" : result.tags.joined(separator: ", "))")
      print("median   \(ms(stats?.median?.ms))")
      print("jitter   \(ms(stats?.jitter?.ms))")
      print("valid    \(stats?.valid ?? 0)/\(stats?.n ?? 0)")
      print("path     \(result.runPath)")
    }
  }
}
