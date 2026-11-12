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
      // `--in-channel auto` finds the channel and stops: it never measures (D-11).
      if setup.autoInChannel {
        try await probeChannels(backend: backend, setup: setup)
        return
      }
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
          case .probe(let probe): Output.writeLine(pretty.probeLine(probe))
          case .levelLocked(let lock): Output.writeLine(pretty.lockLine(lock))
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

  /// `--in-channel auto`: probe every input channel, print the ranking and the winner, and offer
  /// to keep it. No run folder, no hits. JSON modes never prompt.
  private func probeChannels(backend: any AudioBackend, setup: ResolvedSetup) async throws {
    let channels = try options.inputChannels(of: setup, simulated: simulation.simulate)
    // Without --template the probe picks the chirp band from the listener, like a run
    // (`PreflightOptions.templateFollowsListener`); this default is only validated here.
    let templateId = options.template ?? "chirp-loopback"
    guard StimulusLibrary.ids.contains(templateId) else {
      throw SoundPingError.usage(
        "unknownTemplate",
        "no stimulus template named '\(templateId)'; available: \(StimulusLibrary.ids.joined(separator: ", "))",
        context: ["template": templateId])
    }
    var result = try await ChannelProbe().run(
      backend: backend, setup: setup, channels: channels, options: try options.preflightOptions(),
      templateId: templateId)

    let chosen = result.chosen
    var resolved = setup
    resolved.inChannel = chosen.index
    resolved.inChannelName = chosen.name
    resolved.autoInChannel = false

    let interactive = !output.isDataMode && Terminal.stdoutIsTTY && isatty(STDIN_FILENO) != 0
    if let name = options.saveSetup {
      try options.persistSetup(resolved, as: name)
      result.saved = true
    } else if interactive, let name = options.setup,
      try options.setupBindsSameDevices(name, as: resolved)
    {
      // Only a setup that binds the probed devices is offered the channel; with other devices the
      // index would point at the wrong channel next time (WR-06).
      Output.writeLine("")
      FileHandle.standardError.write(
        Data("Save in-channel \(chosen.index) to setup \(name)? [y/N] ".utf8))
      let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
      if answer == "y" || answer == "yes" {
        try options.updateSetupChannel(chosen.index, in: name, probedOn: resolved)
        result.saved = true
      }
    }
    if !result.saved {
      result.saveHint =
        "Pass --in-channel \(chosen.index) next time, or rerun with --in-channel auto --save-setup NAME to keep it in a setup."
    }

    if output.json {
      Output.writeData(try RunJSON.fileEncoder().encode(result) + Data([0x0A]))
    } else if output.ndjson {
      Output.writeLine(String(decoding: try RunJSON.lineEncoder().encode(result), as: UTF8.self))
    } else {
      Output.writeLine(PrettyRenderer(useColor: Terminal.useColor()).channelProbeReport(result))
    }
  }

  /// A short stderr line per hit for a person watching a data-mode run.
  private static func progress(for event: RunEvent) -> String? {
    switch event {
    case .probe(let probe):
      return String(
        format: "probe %.0f dBFS: confidence %.2f, peak %.1f dBFS", probe.levelDbfs,
        probe.confidence, probe.peakDbfs)
    case .levelLocked(let lock):
      return String(
        format: "level locked at %.0f dBFS (%@, ceiling %.0f dBFS)", lock.levelDbfs,
        lock.listenerKind.rawValue, lock.ceilingDbfs)
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
