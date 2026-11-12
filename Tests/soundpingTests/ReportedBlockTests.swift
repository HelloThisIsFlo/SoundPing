import Foundation
import SoundPingKit
import Testing

@testable import soundping

/// RES-02 in the terminal: reported and measured figures side by side, corrections stated.
@Suite struct ReportedBlockTests {
  /// The public face of the simulated fixtures: the device list `--simulate` shows.
  private static func device(_ uid: String) -> DeviceInfo {
    let devices = (try? SimulatedCatalog().listing().audio) ?? []
    return devices.first { $0.uid == uid }!
  }

  private static func result(
    domain: TimeDomain, setup: ResolvedSetup, withReported: Bool = true
  ) -> RunResult {
    let path = StatValue(frames: 412.37, ms: 412.37 / 48)
    let figures =
      domain == .sample
      ? Measured(
        headline: .appRoundTrip, domain: .sample,
        path: SummaryStats(n: 10, valid: 10, median: path),
        appRoundTrip: SummaryStats(
          n: 10, valid: 10, median: StatValue(frames: 696.37, ms: 696.37 / 48)),
        ioOffset: SummaryStats(n: 100, valid: 100, median: StatValue(frames: 284, ms: 284 / 48)))
      : Measured(
        headline: .path, domain: .host, path: SummaryStats(n: 10, valid: 10, median: path))
    let output = device(setup.output.uid)
    let input = device(setup.input.uid)
    return RunResult(
      runId: "20261112T120000Z-round-trip",
      runPath: "/tmp/soundping-store/runs/20261112T120000Z-round-trip",
      createdAt: Date(timeIntervalSince1970: 1_794_484_800),
      toolVersion: "test",
      os: "macOS test",
      recipe: RecipeRegistry.roundTrip.ref,
      label: nil,
      tags: [],
      parameters: RunParameters(hits: 10, seed: 7),
      setup: SetupSnapshot(setup: setup, sampleRate: 48_000, bufferFrames: 128, simulated: true),
      measured: figures,
      histogram: nil,
      hits: [],
      rejectedCounts: [:],
      segments: RecipeRegistry.roundTrip.segments,
      corrections: [],
      simulation: nil,
      reported: withReported
        ? ReportedLatency.compute(
          output: output, outChannels: setup.outChannels, input: input,
          inChannel: setup.inChannel, bufferFrames: 128, sampleRate: 48_000) : nil)
  }

  private static var scarlett: ResolvedSetup {
    ResolvedSetup(
      output: device(SimulatedCatalog.scarlettUID).ref,
      input: device(SimulatedCatalog.scarlettUID).ref,
      outChannels: [1, 2], inChannel: 1)
  }

  private static var speakersToMic: ResolvedSetup {
    ResolvedSetup(
      output: device(SimulatedCatalog.macSpeakersUID).ref,
      input: device(SimulatedCatalog.macMicrophoneUID).ref,
      outChannels: [1, 2], inChannel: 1)
  }

  private let renderer = PrettyRenderer(useColor: false)

  @Test func aSameDeviceSummaryShowsReportedNextToMeasuredForPathRoundTripAndIoOffset() {
    let text = renderer.summary(Self.result(domain: .sample, setup: Self.scarlett))
    #expect(text.contains("Reported vs measured"))
    #expect(text.contains("path"))
    #expect(text.contains("57.00 frames"), "reported path of the Scarlett fixture")
    #expect(text.contains("412.37 frames"))
    #expect(text.contains("341.00 frames"), "reported app round trip")
    #expect(text.contains("696.37 frames"))
    #expect(text.contains("284.00 frames"), "expected and measured Δio")
    #expect(text.contains("Corrections: none (raw measurement)"))
  }

  @Test func aTwoDeviceSummaryShowsOnlyThePathAndSaysWhy() {
    let text = renderer.summary(Self.result(domain: .host, setup: Self.speakersToMic))
    #expect(text.contains("Reported vs measured"))
    #expect(text.contains("2203.00 frames"), "speakers plus microphone fixture sum")
    #expect(!text.contains("app round trip reported"))
    #expect(text.contains("single device only"))
    #expect(text.contains("Corrections: none (raw measurement)"))
  }

  @Test func withoutReportedFiguresTheBlockIsLeftOut() {
    let text = renderer.summary(
      Self.result(domain: .sample, setup: Self.scarlett, withReported: false))
    #expect(!text.contains("Reported vs measured"))
  }
}
