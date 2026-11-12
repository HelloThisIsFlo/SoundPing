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
      Output.writeData(data)
    }

    /// One row per run: BUFFER (SoundPing's own buffer part, calculated), PATH (the measured
    /// hardware path, the column runs are compared by) and TOTAL (path + buffer). None of the
    /// three is "the" number; a two-device run has a PATH only.
    static func table(_ runs: [RunListing]) -> [String] {
      guard !runs.isEmpty else { return ["no runs yet"] }
      let ms = { (value: Double?) in value.map { String(format: "%.2f ms", $0) } ?? "-" }
      let stamp = ISO8601DateFormatter()
      let rows = runs.map { run in
        [
          run.runId, stamp.string(from: run.createdAt), run.label ?? "-", ms(run.bufferMs),
          ms(run.pathMs), ms(run.totalMs), "\(run.valid)/\(run.n)",
        ]
      }
      let header = ["RUN", "WHEN", "LABEL", "BUFFER", "PATH", "TOTAL", "VALID"]
      let widths = header.indices.map { column in
        ([header] + rows).map { $0[column].count }.max() ?? 0
      }
      return ([header] + rows).map { row in
        row.indices.map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
          .joined(separator: "  ")
          .trimmingCharacters(in: .whitespaces)
      }
    }

    private static func writeTable(_ runs: [RunListing]) {
      for line in table(runs) { print(line) }
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
          Output.writeData(try runStore.loadBytes(run))
        } else {
          Self.writeSummary(try runStore.load(run))
        }
      }
    }

    static func summaryLines(_ result: RunResult) -> [String] {
      let ms = { (value: Double?) in value.map { String(format: "%.2f ms", $0) } ?? "-" }
      let stats = result.measured.path
      return [
        "recipe   \(result.recipe.id)",
        "label    \(result.label ?? "-")",
        "tags     \(result.tags.isEmpty ? "-" : result.tags.joined(separator: ", "))",
        "buffer   \(ms(result.measured.ioOffset?.median?.ms))",
        "path     \(ms(stats?.median?.ms))",
        "total    \(ms(result.measured.appRoundTrip?.median?.ms))",
        "jitter   \(ms(stats?.jitter?.ms)) (path, p5–p95)",
        "valid    \(stats?.valid ?? 0)/\(stats?.n ?? 0)",
        "folder   \(result.runPath)",
      ]
    }

    private static func writeSummary(_ result: RunResult) {
      for line in summaryLines(result) { print(line) }
    }
  }
}
