import Foundation
import Testing

@testable import SoundPingKit

/// Forwards to the simulator, announces a device change on the event stream during the first
/// listening wait, and then never delivers the samples, like a device whose notification arrives
/// while the probe waits.
private actor ChangingDeviceBackend: AudioBackend {
  private let inner: SimulatedBackend
  private let continuation: AsyncStream<DeviceEvent>.Continuation
  nonisolated let events: AsyncStream<DeviceEvent>

  init(scenario: Scenario) {
    inner = SimulatedBackend(scenario: scenario)
    (events, continuation) = AsyncStream<DeviceEvent>.makeStream()
  }

  func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws -> BackendInfo {
    try await inner.open(setup, templates: templates)
  }
  func start() async throws -> BackendInfo { try await inner.start() }
  func currentInputFrame() async -> Int64 { await inner.currentInputFrame() }
  func currentOutputFrame() async -> Int64 { await inner.currentOutputFrame() }
  func schedule(_ hits: [ScheduledHit]) async throws { try await inner.schedule(hits) }
  func waitUntilCaptured(throughInputFrame frame: Int64) async throws {
    continuation.yield(
      .sampleRateChanged(uid: SimulatedCatalog.scarlettUID, from: 48_000, to: 44_100))
    while true { try await Task.sleep(for: .seconds(3600)) }
  }
  func capture(_ range: Range<Int64>) async throws -> [Float] { try await inner.capture(range) }
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    await inner.stamps(covering: range)
  }
  func stampLog() async -> StampLog { await inner.stampLog() }
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval] {
    await inner.faults(overlappingInput: input, output: output)
  }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }
  func stop() async {
    await inner.stop()
    continuation.finish()
  }
}

/// Forwards to the simulator, but the first `glitches` listening windows report an overload over
/// the window, as a real glitch would. Remembers every level it was asked to play.
private actor GlitchingProbeBackend: AudioBackend {
  private let inner: SimulatedBackend
  private var remaining: Int
  private(set) var playedLevels: [Double] = []
  nonisolated let events: AsyncStream<DeviceEvent>

  init(scenario: Scenario, glitches: Int) {
    inner = SimulatedBackend(scenario: scenario)
    remaining = glitches
    events = inner.events
  }

  func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws -> BackendInfo {
    try await inner.open(setup, templates: templates)
  }
  func start() async throws -> BackendInfo { try await inner.start() }
  func currentInputFrame() async -> Int64 { await inner.currentInputFrame() }
  func currentOutputFrame() async -> Int64 { await inner.currentOutputFrame() }
  func schedule(_ hits: [ScheduledHit]) async throws {
    playedLevels += hits.map { (20 * log10(Double($0.gain))).rounded() }
    try await inner.schedule(hits)
  }
  func waitUntilCaptured(throughInputFrame frame: Int64) async throws {
    try await inner.waitUntilCaptured(throughInputFrame: frame)
  }
  func capture(_ range: Range<Int64>) async throws -> [Float] { try await inner.capture(range) }
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    await inner.stamps(covering: range)
  }
  func stampLog() async -> StampLog { await inner.stampLog() }
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval] {
    if remaining > 0 {
      remaining -= 1
      return [FaultInterval(direction: .input, frames: input, cause: .overload)]
    }
    return await inner.faults(overlappingInput: input, output: output)
  }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }
  func stop() async { await inner.stop() }
}

/// `--in-channel auto` (D-11): play the chirp, hear which input channel it comes back on, say how
/// sure that is, and refuse to guess when two channels hear it about equally. It is a probe: it
/// never writes a run and never measures.
@Suite struct ChannelProbeTests {
  private static let scarlett = SimulatedCatalog.scarlett

  private static var setup: ResolvedSetup {
    ResolvedSetup(
      output: scarlett.ref, input: scarlett.ref, outChannels: [1, 2], inChannel: 0,
      autoInChannel: true)
  }

  private struct Probed {
    var result: ChannelProbeResult?
    var error: SoundPingError?
  }

  private static func probe(
    _ scenario: Scenario, options: PreflightOptions = PreflightOptions()
  ) async -> Probed {
    do {
      let result = try await ChannelProbe().run(
        backend: SimulatedBackend(scenario: scenario), setup: setup,
        channels: scarlett.input?.channels ?? [], options: options)
      return Probed(result: result, error: nil)
    } catch {
      return Probed(result: nil, error: error as? SoundPingError)
    }
  }

  @Test func aDeviceChangeWhileProbingEndsTheProbeWithTheMatchingError() async throws {
    let backend = ChangingDeviceBackend(
      scenario: Scenario(jitterFrames: 0, loopChannel: 7, seed: 3))
    var thrown: SoundPingError?
    do {
      _ = try await ChannelProbe().run(
        backend: backend, setup: Self.setup, channels: Self.scarlett.input?.channels ?? [])
    } catch {
      thrown = error as? SoundPingError
    }
    let error = try #require(thrown)
    #expect(error.kind == .deviceChanged)
    #expect(error.code == "sampleRateChanged")
  }

  @Test func theLoopChannelWinsWithHighConfidenceAndAClearMargin() async throws {
    let probed = await Self.probe(Scenario(jitterFrames: 0, loopChannel: 7, seed: 3))

    #expect(probed.error == nil)
    let result = try #require(probed.result)
    #expect(result.type == "channelProbe")
    #expect(result.schemaVersion == 1)
    #expect(result.chosen.index == 7)
    #expect(result.chosen.name == "Loop 1")
    #expect(result.chosen.confidence >= 0.9)
    #expect(result.chosen.margin >= 0.2)

    #expect(result.channels.count == 10, "every input channel is listed")
    #expect(result.channels.first?.index == 7, "best first")
    #expect(Set(result.channels.map(\.index)) == Set(1...10))
    let runnerUp = try #require(result.channels.dropFirst().first)
    #expect(abs((result.chosen.confidence - runnerUp.confidence) - result.chosen.margin) < 1e-9)
    #expect(!result.saved, "saving is the caller's decision")
  }

  @Test func twoChannelsHearingTheChirpAboutEquallyAreAmbiguous() async throws {
    // Without a loop channel every channel hears the same chirp: nothing separates them.
    let probed = await Self.probe(Scenario(jitterFrames: 0, seed: 3))

    let error = try #require(probed.error)
    #expect(error.kind == .preflight)
    #expect(error.code == "inChannelAmbiguous")
    let candidates = error.context["candidates"] ?? ""
    #expect(candidates.contains("7 = Loop 1"), "the candidates are listed: \(candidates)")
    #expect(candidates.contains("8 = Loop 2"), "the candidates are listed: \(candidates)")
    #expect(error.context["fix"]?.contains("--in-channel") == true)
    #expect(probed.result == nil)
  }

  @Test func theProbePlaysUnderTheRunCeilingTheBuiltInSpeakersIncluded() async throws {
    // One rule for runs and probes: the built-in speakers get -12 dBFS here too, an interface -18.
    let mic = SimulatedCatalog.macMicrophone
    let speakers = SimulatedCatalog.macSpeakers
    #expect(speakers.output?.dataSource == "ispk")
    for (output, expected) in [(speakers, -12.0), (Self.scarlett, -18.0)] {
      var setup = Self.setup
      setup.output = output.ref
      var thrown: SoundPingError?
      do {
        _ = try await ChannelProbe().run(
          backend: SimulatedBackend(
            scenario: Scenario(jitterFrames: 0, pathGainDb: -80, loopChannel: 7, seed: 3)),
          setup: setup, channels: Array((Self.scarlett.input?.channels ?? []).prefix(2)))
      } catch {
        thrown = error as? SoundPingError
      }
      let error = try #require(thrown, "\(output.name)")
      #expect(error.code == "nothingHeardAtCeiling")
      #expect(error.context["ceilingDbfs"] == String(expected), "\(output.name)")
      #expect(error.context["ceilingSource"] == "output", "\(output.name)")
      let run = try LevelRamp.runLoudness(
        setup: ResolvedSetup(output: output.ref, input: mic.ref, outChannels: [1, 2], inChannel: 1),
        output: output, input: mic, options: PreflightOptions())
      #expect(run.ceilingDbfs == expected, "the same ceiling as a run: \(output.name)")
    }
  }

  @Test func theListenerFlagNeverLiftsTheProbeOnABluetoothOutput() async throws {
    var output = DeviceRef(uid: "bt-speaker", name: "Bluetooth Speaker")
    output.transport = "bluetooth"
    var setup = Self.setup
    setup.output = output
    var thrown: SoundPingError?
    do {
      _ = try await ChannelProbe().run(
        backend: SimulatedBackend(
          scenario: Scenario(jitterFrames: 0, pathGainDb: -80, loopChannel: 7, seed: 3)),
        setup: setup, channels: Self.scarlett.input?.channels ?? [],
        options: PreflightOptions(listener: .loopback))
    } catch {
      thrown = error as? SoundPingError
    }
    let error = try #require(thrown)
    #expect(error.code == "nothingHeardAtCeiling")
    #expect(error.context["ceilingDbfs"] == "-30.0")
    #expect(error.context["detectedListener"] == "headphones")
  }

  @Test func noChannelHearingAnythingAtTheCeilingIsNothingHeard() async throws {
    let probed = await Self.probe(
      Scenario(jitterFrames: 0, pathGainDb: -80, loopChannel: 7, seed: 3))

    let error = try #require(probed.error)
    #expect(error.kind == .preflight)
    #expect(error.code == "nothingHeardAtCeiling")
    #expect(
      error.context["ceilingDbfs"] == "-18.0", "an unknown listener: the interface's channels")
  }

  @Test func theCeilingHoldsWhileProbingEveryChannel() async throws {
    let probed = await Self.probe(
      Scenario(jitterFrames: 0, pathGainDb: -80, loopChannel: 7, seed: 3),
      options: PreflightOptions(maxLevelDbfs: -40))

    #expect(probed.error?.code == "nothingHeardAtCeiling")
    #expect(probed.error?.context["ceilingDbfs"] == "-40.0")
  }

  // MARK: Glitched probes are replayed, not stepped (IN-19)

  @Test func aGlitchedProbeIsReplayedAtTheSameLevelAndNotCountedAsHeard() async throws {
    let loop = try #require(Self.scarlett.input?.channels.first { $0.name == "Loop 1" })
    let scenario = Scenario(jitterFrames: 0, loopChannel: 7, seed: 3)
    let clean = GlitchingProbeBackend(scenario: scenario, glitches: 0)
    let expected = try await ChannelProbe().run(
      backend: clean, setup: Self.setup, channels: [loop])
    let cleanLevels = await clean.playedLevels
    #expect(cleanLevels.first == -48)

    let backend = GlitchingProbeBackend(scenario: scenario, glitches: 2)
    let result = try await ChannelProbe().run(
      backend: backend, setup: Self.setup, channels: [loop])
    // Two glitched probes replayed at -48 dBFS, then exactly the clean climb: no 12 dB step on a
    // glitch, and the channel scores what it really hears.
    let levels = await backend.playedLevels
    #expect(levels == [-48, -48] + cleanLevels, "\(levels)")
    #expect(result.chosen.index == expected.chosen.index)
    #expect(result.channels.map(\.levelDbfs) == expected.channels.map(\.levelDbfs))
    #expect(abs(result.chosen.confidence - expected.chosen.confidence) < 0.01)
  }

  @Test func theReplaysAreBoundedSoAGlitchingChannelStillClimbsToTheCeiling() async throws {
    let loop = try #require(Self.scarlett.input?.channels.first { $0.name == "Loop 1" })
    let backend = GlitchingProbeBackend(
      scenario: Scenario(jitterFrames: 0, loopChannel: 7, seed: 3), glitches: 1_000)
    var thrown: SoundPingError?
    do {
      _ = try await ChannelProbe().run(backend: backend, setup: Self.setup, channels: [loop])
    } catch {
      thrown = error as? SoundPingError
    }
    // Every probe glitched: never "only zeros", and nothing above the -18 dBFS ceiling.
    #expect(thrown?.code == "nothingHeardAtCeiling")
    let levels = await backend.playedLevels
    let perLevel = 1 + LevelRamp.maxGlitchRetries
    #expect(levels == [-48, -36, -24, -18].flatMap { Array(repeating: $0, count: perLevel) })
  }

  @Test func deadChannelsWithAGlitchAreStillDigitalSilence() async throws {
    // A glitched probe used to count as heard, turning dead channels into nothingHeard.
    let backend = GlitchingProbeBackend(
      scenario: Scenario(jitterFrames: 0, inputZeros: true, seed: 3), glitches: 1)
    var thrown: SoundPingError?
    do {
      _ = try await ChannelProbe().run(
        backend: backend, setup: Self.setup,
        channels: Array((Self.scarlett.input?.channels ?? []).prefix(2)))
    } catch {
      thrown = error as? SoundPingError
    }
    #expect(thrown?.code == "inputDigitalSilence")
  }

  @Test func aSourceThatIsAllZerosOnEveryChannelIsDigitalSilence() async throws {
    let probed = await Self.probe(Scenario(jitterFrames: 0, inputZeros: true, seed: 3))
    #expect(probed.error?.code == "inputDigitalSilence")
  }

  @Test func theSamePreflightChecksRunBeforeAnySoundIsPlayed() async throws {
    let denied = await Self.probe(Scenario(jitterFrames: 0, permission: .denied, seed: 3))
    #expect(denied.error?.code == "micPermissionDenied")

    let muted = await Self.probe(Scenario(jitterFrames: 0, outputMuted: true, seed: 3))
    #expect(muted.error?.code == "outputMuted")
  }

  @Test func theResultIsTheJSONObjectTheCommandPrints() throws {
    let result = ChannelProbeResult(
      channels: [
        ChannelScore(index: 7, name: "Loop 1", confidence: 0.97, levelDbfs: -36),
        ChannelScore(index: 1, name: "Input 1", confidence: 0.1, levelDbfs: -18),
      ],
      chosen: ChannelChoice(index: 7, name: "Loop 1", confidence: 0.97, margin: 0.87),
      saved: true)
    let data = try RunJSON.lineEncoder().encode(result)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["type"] as? String == "channelProbe")
    #expect(object["saved"] as? Bool == true)
    let chosen = try #require(object["chosen"] as? [String: Any])
    #expect(chosen["index"] as? Int == 7)
    #expect(chosen["margin"] as? Double == 0.87)
    #expect((object["channels"] as? [[String: Any]])?.first?["levelDbfs"] as? Double == -36)
    #expect(try RunJSON.decoder().decode(ChannelProbeResult.self, from: data) == result)
  }
}
