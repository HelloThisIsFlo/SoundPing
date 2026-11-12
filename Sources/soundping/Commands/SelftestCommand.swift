import ArgumentParser
import Foundation
import SoundPingKit

/// `soundping selftest clock` (CAL-03, D-05): does the host clock agree with the sample clock?
/// Phase 2 adds `selftest midi` beside it.
struct SelftestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "selftest",
    abstract: "Check that SoundPing's own clocks agree before you trust a measurement.",
    subcommands: [ClockCheck.self]
  )

  /// What `selftest clock --json` prints on a pass.
  struct SelfTestReport: Codable, Equatable {
    var schemaVersion = 1
    var type = "clockSelfTest"
    var pass: Bool
    var medianDeltaFrames: Double
    var p95AbsDeltaFrames: Double
    var n: Int
    var key: ClockSelfTestKey
    var runId: String
    var runPath: String
  }

  /// Runs the round-trip recipe on one device and gates on the self-test every same-device run
  /// already computes: the same engine function, here as an explicit pass or fail.
  struct ClockCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "clock",
      abstract:
        "Play and record on one device, then check its host timestamps against its sample clock.",
      discussion:
        "Output and input must be the same device. Exits 0 when |median delta| <= 1 and p95 |delta| <= 2 frames, 3 (clockSelfTestFailed) otherwise. The run is saved either way."
    )

    @OptionGroup var options: RunOptions
    @OptionGroup(title: "Simulation") var simulation: SimulationOptions
    @OptionGroup(title: "Output") var output: OutputOptions

    mutating func validate() throws {
      options.pinSeed()
    }

    func run() async throws {
      try await withErrorReporting(jsonMode: output.isDataMode) {
        let recipe = try RecipeRegistry.recipe(id: "round-trip")
        let store = try options.makeStore()
        let (backend, setup) = try options.makeBackend(simulation: simulation)
        guard setup.output.uid == setup.input.uid else {
          throw SoundPingError.usage(
            "selfTestNeedsSameDevice",
            "the clock self-test compares one device's sample clock with its host clock, so output and input must be the same device; got '\(setup.output.name)' and '\(setup.input.name)'",
            context: [
              "output": setup.output.uid, "input": setup.input.uid,
              "fix": "pass the same device to --output and --input",
            ])
        }
        let request = try options.makeRequest(recipe: recipe, setup: setup)

        let ndjson = NDJSONRenderer()
        let pretty = PrettyRenderer(useColor: Terminal.useColor())
        var finished: RunResult?
        for try await event in RunCoordinator(backend: backend, store: store).run(request) {
          if output.ndjson { try ndjson.write(event) }
          if !output.isDataMode {
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
        guard let selfTest = result.selfTest else {
          throw SoundPingError.internalFailure(
            "selfTestMissing", "the run finished without a clock self-test",
            context: ["runPath": result.runPath])
        }

        // Too few valid hits means there is nothing to judge the clock on.
        if let failure = RunGate.check(result) { throw failure }

        let key = ClockSelfTestKey(
          deviceUID: setup.output.uid, sampleRate: result.setup.sampleRate,
          bufferFrames: result.setup.bufferFrames)
        if !output.isDataMode {
          Output.writeLine("")
          Output.writeLine(pretty.selfTestLine(selfTest))
          Output.writeLine("Saved: \(result.runPath)")
        }
        guard selfTest.pass else { throw Self.failure(selfTest, result: result) }

        if output.json {
          let report = SelfTestReport(
            pass: selfTest.pass, medianDeltaFrames: selfTest.medianDeltaFrames,
            p95AbsDeltaFrames: selfTest.p95AbsDeltaFrames, n: selfTest.n, key: key,
            runId: result.runId, runPath: result.runPath)
          var data = try RunJSON.fileEncoder().encode(report)
          data.append(0x0A)
          Output.writeData(data)
        }
      }
    }

    static func failure(_ selfTest: ClockSelfTestResult, result: RunResult) -> SoundPingError {
      let limits = selfTest.thresholds
      return SoundPingError(
        kind: .gate, code: "clockSelfTestFailed",
        detail: String(
          format:
            "the host clock disagrees with the sample clock: median delta %.2f frames (limit %g), p95 |delta| %.2f frames (limit %g). The run is saved.",
          selfTest.medianDeltaFrames, limits.medianFrames, selfTest.p95AbsDeltaFrames,
          limits.p95Frames),
        context: [
          "medianDeltaFrames": String(format: "%.4f", selfTest.medianDeltaFrames),
          "p95AbsDeltaFrames": String(format: "%.4f", selfTest.p95AbsDeltaFrames),
          "n": String(selfTest.n),
          "runId": result.runId,
          "runPath": result.runPath,
          "fix":
            "do not trust host-time alignment (MIDI, two-device runs) on this setup; try another buffer size or sample rate, or another device",
        ])
    }
  }
}
