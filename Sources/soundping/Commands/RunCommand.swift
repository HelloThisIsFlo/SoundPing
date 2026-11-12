import ArgumentParser
import Foundation
import SoundPingKit

struct RunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run a recipe and save the result."
  )

  @Argument(help: "The recipe to run, e.g. round-trip.")
  var recipe: String

  @OptionGroup var options: RunOptions
  @OptionGroup(title: "Simulation") var simulation: SimulationOptions
  @OptionGroup(title: "Output") var output: OutputOptions

  mutating func validate() throws {
    options.pinSeed()
  }

  func run() async throws {
    try await withErrorReporting(jsonMode: output.isDataMode) {
      let recipe = try RecipeRegistry.recipe(id: recipe)
      let store = try options.makeStore()
      let (backend, setup) = try options.makeBackend(simulation: simulation)
      let request = try options.makeRequest(recipe: recipe, setup: setup)

      let ndjson = NDJSONRenderer()
      var finished: RunResult?
      for try await event in RunCoordinator(backend: backend, store: store).run(request) {
        if output.ndjson { try ndjson.write(event) }
        if output.isDataMode, let progress = Self.progress(for: event) {
          Output.progressLine(progress)
        }
        if case .finished(let result) = event { finished = result }
      }
      guard let result = finished else {
        throw SoundPingError.internalFailure("noResult", "the run ended without a result")
      }

      if output.json {
        try JSONRenderer.write(result)
      } else if !output.ndjson {
        Output.writeLine(Self.summaryLine(for: result))
      }
    }
  }

  /// A short stderr line per hit for a person watching a data-mode run.
  private static func progress(for event: RunEvent) -> String? {
    switch event {
    case .hit(let record):
      let frames = record.latencyFrames.map { String(format: "%.2f frames", $0) } ?? "-"
      return "hit \(record.index) (\(record.phase.rawValue)): \(frames)"
    case .rejected(let record):
      return
        "hit \(record.index) (\(record.phase.rawValue)): rejected \(record.rejection?.rawValue ?? "unknown")"
    default:
      return nil
    }
  }

  /// One line until the full pretty renderer lands.
  private static func summaryLine(for result: RunResult) -> String {
    guard let path = result.measured.path, let median = path.median, let jitter = path.jitter else {
      return "no valid hits (0/\(result.measured.path?.n ?? 0)) \(result.runPath)"
    }
    let ms = { (value: Double) in String(format: "%.2f", value) }
    return
      "median \(ms(median.ms)) ms (\(String(format: "%.1f", median.frames)) frames), jitter \(ms(jitter.ms)) ms, valid \(path.valid)/\(path.n)  \(result.runPath)"
  }
}
