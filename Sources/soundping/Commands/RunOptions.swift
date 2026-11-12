import ArgumentParser
import Foundation
import SoundPingKit

/// The flags every run-shaped command shares (D-02), kept in one group so commands added by
/// later plans inherit them instead of redeclaring them.
struct RunOptions: ParsableArguments {
  @Option(help: "Measured hits to fire (warm-ups come on top). Default: the recipe's.")
  var hits: Int?

  @Option(help: "Warm-up hits to fire first; they are recorded but never counted.")
  var warmup: Int?

  @Option(help: "Random seed. A random one is drawn and recorded when omitted.")
  var seed: UInt64?

  @Option(help: "Stimulus level in dBFS. Default: the recipe's start level.")
  var level: Double?

  @Option(help: "Stimulus template id. Available: \(StimulusLibrary.ids.joined(separator: ", ")).")
  var template: String?

  @Option(
    help:
      "Absolute store folder. Default: SOUNDPING_HOME, else ~/Library/Application Support/SoundPing."
  )
  var store: String?

  /// Draws the random seed once, after parsing, so the request and the simulator share it.
  mutating func pinSeed() {
    if seed == nil { seed = UInt64.random(in: 0..<(1 << 53)) }
  }

  func makeStore() throws -> RunStore {
    RunStore(
      paths: try StorePaths.resolve(flag: store, environment: ProcessInfo.processInfo.environment))
  }

  /// The device side of the run. Hardware arrives with the HAL backend; until then only the
  /// simulator is available.
  func makeBackend(simulation: SimulationOptions) throws -> (
    backend: any AudioBackend, setup: ResolvedSetup
  ) {
    guard simulation.simulate else {
      throw SoundPingError.usage(
        "hardwareBackendUnavailable",
        "hardware runs are not available in this build yet; use --simulate")
    }
    guard let seed else {
      throw SoundPingError.internalFailure("seedNotPinned", "the run seed was never drawn")
    }
    return (SimulatedBackend(scenario: simulation.scenario(seed: seed)), .simulatedDuplex)
  }

  func makeRequest(recipe: Recipe, setup: ResolvedSetup) throws -> RunRequest {
    guard let seed else {
      throw SoundPingError.internalFailure("seedNotPinned", "the run seed was never drawn")
    }
    var parameters = recipe.defaultParameters(seed: seed)
    if let hits { parameters.hits = hits }
    if let warmup { parameters.warmup = warmup }
    if let level { parameters.levelDbfs = level }
    if let template {
      guard StimulusLibrary.ids.contains(template) else {
        throw SoundPingError.usage(
          "unknownTemplate",
          "no stimulus template named '\(template)'; available: \(StimulusLibrary.ids.joined(separator: ", "))",
          context: ["template": template])
      }
      parameters.templateId = template
    }
    return RunRequest(recipe: recipe, parameters: parameters, setup: setup)
  }
}
