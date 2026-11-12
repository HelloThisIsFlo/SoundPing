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

  @Flag(help: "Use the simulated device instead of real hardware.")
  var simulate = false

  @Option(help: "Simulated path latency in frames.")
  var simLatency: Double = 412.37

  @Option(help: "Simulated per-hit jitter (Gaussian sigma) in frames.")
  var simJitter: Double = 0.5

  @Option(help: "Random seed. A random one is drawn and recorded when omitted.")
  var seed: UInt64?

  @Flag(help: "Print the final result as one JSON object.")
  var json = false

  @Option(help: "Absolute store folder. Default: SOUNDPING_HOME, else ~/Library/Application Support/SoundPing.")
  var store: String?

  /// Draw the random seed once, after parsing, so the request and the simulator share it.
  mutating func validate() throws {
    if seed == nil { seed = UInt64.random(in: 0..<(1 << 53)) }
  }

  func run() async throws {
    let recipe = try RecipeRegistry.recipe(id: recipe)
    let paths = try StorePaths.resolve(
      flag: store, environment: ProcessInfo.processInfo.environment)
    guard simulate else {
      throw SoundPingError.usage(
        "hardwareBackendUnavailable",
        "hardware runs are not available in this build yet; use --simulate")
    }
    let seed = seed ?? 0
    let backend = SimulatedBackend(
      scenario: Scenario(latencyFrames: simLatency, jitterFrames: simJitter, seed: seed))
    let request = RunRequest(
      recipe: recipe, parameters: recipe.defaultParameters(seed: seed), setup: .simulatedDuplex)

    let coordinator = RunCoordinator(backend: backend, store: RunStore(paths: paths))
    var finished: RunResult?
    for try await event in coordinator.run(request) {
      if case .finished(let result) = event { finished = result }
    }
    guard let result = finished else {
      throw SoundPingError.internalFailure("noResult", "the run ended without a result")
    }

    if json {
      FileHandle.standardOutput.write(try RunStore.encodedBytes(for: result))
    } else {
      print(result.runPath)
    }
  }
}
