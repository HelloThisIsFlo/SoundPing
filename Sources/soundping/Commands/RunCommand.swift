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
      let pretty = PrettyRenderer(useColor: Terminal.useColor())
      var finished: RunResult?
      for try await event in RunCoordinator(backend: backend, store: store).run(request) {
        if output.ndjson { try ndjson.write(event) }
        if output.isDataMode {
          if let progress = Self.progress(for: event) { Output.progressLine(progress) }
        } else {
          switch event {
          case .armed(let info): Output.writeLine(pretty.armedLine(info))
          case .hit(let record), .rejected(let record): Output.writeLine(pretty.hitLine(record))
          case .aborted, .selfTest, .finished: break
          }
        }
        if case .finished(let result) = event { finished = result }
      }
      guard let result = finished else {
        throw SoundPingError.internalFailure("noResult", "the run ended without a result")
      }

      if output.json {
        try JSONRenderer.write(result)
      } else if !output.ndjson {
        Output.writeLine("")
        Output.writeLine(pretty.report(result))
      }

      // The result is saved and printed. A run with too few valid hits still fails, so an agent
      // reading only the exit code cannot take an untrustworthy number for a good one (D-03).
      if let failure = RunGate.check(result) {
        throw FailedAfterResult(error: failure)
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
}
