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

  @Option(help: "A label for this run, stored verbatim and used in the run folder name.")
  var label: String?

  @Option(
    name: .customLong("tag"),
    help: "A tag for this run. Repeat the flag for several; duplicates are dropped.")
  var tags: [String] = []

  @Option(
    help:
      "A saved setup (see --save-setup). Any device flag below overrides the matching field of the setup."
  )
  var setup: String?

  @Option(
    help:
      "Output device: its UID, its name, or part of its name. `default` uses the system default on purpose. Required for hardware runs."
  )
  var output: String?

  @Option(
    help:
      "Input device: its UID, its name, or part of its name. `default` uses the system default on purpose. Required for hardware runs."
  )
  var input: String?

  @Option(
    help:
      "Input channel, 1-based, as `soundping devices` lists it. Required for hardware runs; never guessed."
  )
  var inChannel: String?

  @Option(
    help: "Output channels, 1-based, comma-separated, e.g. 1,2. Default: the device's stereo pair."
  )
  var outChannels: String?

  @Option(
    help:
      "SoundPing's own audio buffer size in frames (e.g. 128). Applied to this process only, clamped to what the device allows, and recorded as applied. Default: whatever the device gives this process."
  )
  var buffer: Int?

  @Option(
    parsing: .unconditional,
    help:
      "MIDI destination: its unique ID (may be negative, e.g. -823739469) or its name."
  )
  var midiOut: String?

  @Option(help: "Save the resolved devices and channels under this name in setups.json.")
  var saveSetup: String?

  /// Tags without duplicates, first-seen order kept.
  var uniqueTags: [String] {
    var seen = Set<String>()
    return tags.filter { seen.insert($0).inserted }
  }

  /// Draws the random seed once, after parsing, so the request and the simulator share it.
  mutating func pinSeed() {
    if seed == nil { seed = UInt64.random(in: 0..<(1 << 53)) }
  }

  /// The store for a run. It holds `<root>/.run.lock` for as long as the store (or a copy of it,
  /// such as the coordinator's) is alive, so a second run fails fast with `runInProgress` (T-01-06).
  func makeStore() throws -> RunStore {
    try RunStore(
      paths: try StorePaths.resolve(flag: store, environment: ProcessInfo.processInfo.environment)
    ).acquiringRunLock()
  }

  /// The device side of the run. Selectors are resolved first, so a bad device or channel is
  /// reported before anything else. Without `--simulate` the run goes to the real devices through
  /// the HAL backend.
  func makeBackend(simulation: SimulationOptions) throws -> (
    backend: any AudioBackend, setup: ResolvedSetup
  ) {
    var setup = try resolveSetup(simulated: simulation.simulate)
    if let buffer {
      guard (1...16_384).contains(buffer) else {
        throw SoundPingError.usage(
          "invalidParameters", "--buffer must be between 1 and 16384 frames, got \(buffer)",
          context: ["parameter": "buffer", "value": String(buffer)])
      }
      setup.requestedBufferFrames = buffer
    }
    guard simulation.simulate else { return (HALBackend(), setup) }
    guard let seed else {
      throw SoundPingError.internalFailure("seedNotPinned", "the run seed was never drawn")
    }
    return (
      SimulatedBackend(scenario: simulation.scenario(seed: seed, bufferFrames: buffer ?? 128)), setup
    )
  }

  /// Turns the device flags and `--setup` into a `ResolvedSetup`, prints each warning to stderr
  /// and writes `--save-setup`. Reads the device list from the simulator or the HAL (D-08..D-11).
  func resolveSetup(simulated: Bool) throws -> ResolvedSetup {
    let paths = try StorePaths.resolve(
      flag: store, environment: ProcessInfo.processInfo.environment)
    let catalog: any DeviceCatalog = simulated ? SimulatedCatalog() : HALDeviceCatalog()
    let saved = (setup != nil || saveSetup != nil) ? try Setups.load(from: paths.setups) : nil

    let resolved = try SetupResolver(
      listing: try catalog.listing(), setups: saved, simulated: simulated
    )
    .resolve(
      SetupSelectors(
        setup: setup, output: output, input: input, inChannel: inChannel,
        outChannels: try parsedOutChannels(), midiOut: midiOut, saveSetup: saveSetup))

    for warning in resolved.warnings {
      FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
    }

    if let name = saveSetup {
      guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw SoundPingError.usage("invalidSetupName", "--save-setup needs a non-empty name")
      }
      var file = saved ?? SetupsFile()
      file.setups[name] = SetupBinding(resolved: resolved)
      try Setups.save(file, to: paths.setups)
    }
    return resolved
  }

  private func parsedOutChannels() throws -> [Int]? {
    guard let outChannels else { return nil }
    let pieces = outChannels.split(separator: ",", omittingEmptySubsequences: false)
    let values = pieces.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard values.count == pieces.count, !values.isEmpty else {
      throw SoundPingError.usage(
        "invalidChannel",
        "--out-channels takes comma-separated channel numbers such as 1,2; got '\(outChannels)'",
        context: ["value": outChannels])
    }
    return values
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
    return RunRequest(
      recipe: recipe, parameters: parameters, setup: setup, label: label, tags: uniqueTags)
  }
}
