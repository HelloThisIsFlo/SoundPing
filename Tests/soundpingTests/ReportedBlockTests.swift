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
      setup: SetupSnapshot(
        setup: setup, sampleRate: 48_000, outputBufferFrames: 128, inputBufferFrames: 128,
        simulated: true),
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
          inChannel: setup.inChannel, outputBufferFrames: 128, inputBufferFrames: 128,
          sampleRate: 48_000) : nil)
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

  @Test func aSameDeviceSummaryShowsPathBufferAndTotalWithMacOSBesideThem() throws {
    let text = renderer.summary(Self.result(domain: .sample, setup: Self.scarlett))
    let lines = text.split(separator: "\n").map(String.init)
    func line(_ prefix: String) throws -> String {
      try #require(lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) })
    }

    #expect(text.contains("Round trip at buffer 128, 48000 Hz"), "\(text)")
    let path = try line("hardware path")
    #expect(path.contains("412.37 frames") && path.contains("measured"), "\(path)")
    #expect(path.contains("macOS reports 57.00 frames"), "reported path of the Scarlett fixture")
    let buffer = try line("SoundPing buffer")
    #expect(buffer.contains("284.00 frames"), "expected and measured Δio: \(buffer)")
    #expect(buffer.contains("calculated: 2 × 128 buffer +"), "the formula is shown: \(buffer)")
    #expect(buffer.contains("safety in") && buffer.contains("safety out"), "\(buffer)")
    let total = try line("total")
    #expect(total.contains("696.37 frames") && total.contains("path + buffer"), "\(total)")
    #expect(total.contains("macOS reports 341.00 frames"), "reported app round trip")
    #expect(!text.contains("Reported vs measured"), "folded into the breakdown")
    #expect(text.contains("Corrections: none (raw measurement)"))
  }

  @Test func theBreakdownLeadsWithNoSingleHeadlineNumber() throws {
    let text = renderer.summary(Self.result(domain: .sample, setup: Self.scarlett))
    let lines = text.split(separator: "\n").map(String.init)
    let headings = lines.filter { !$0.hasPrefix(" ") }
    #expect(!headings.contains { $0.lowercased().contains("headline") }, "\(text)")
    let breakdown = try #require(lines.firstIndex { $0.hasPrefix("Round trip at buffer") })
    let rows = lines[(breakdown + 1)...].prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }
    #expect(rows.map { String($0.prefix(4)) } == ["hard", "Soun", "tota"], "\(rows)")
  }

  @Test func withoutReportedFiguresTheBreakdownStillShowsTheThreeMeasuredFigures() {
    let text = renderer.summary(
      Self.result(domain: .sample, setup: Self.scarlett, withReported: false))
    #expect(text.contains("Round trip at buffer 128, 48000 Hz"), "\(text)")
    #expect(text.contains("412.37 frames") && text.contains("284.00 frames"))
    #expect(text.contains("696.37 frames"))
    #expect(text.contains("Δio read from the stamps"), "\(text)")
    #expect(!text.contains("macOS reports"), "\(text)")
  }

  @Test func aTwoDeviceSummaryShowsOnlyThePathAndSaysWhy() {
    let text = renderer.summary(Self.result(domain: .host, setup: Self.speakersToMic))
    #expect(text.contains("Reported vs measured"))
    #expect(text.contains("2203.00 frames"), "speakers plus microphone fixture sum")
    #expect(!text.contains("app round trip reported"))
    #expect(text.contains("single device only"))
    #expect(text.contains("Corrections: none (raw measurement)"))
  }

  @Test func aTwoDeviceRunWithoutReportedFiguresLeavesTheBlockOut() {
    let text = renderer.summary(
      Self.result(domain: .host, setup: Self.speakersToMic, withReported: false))
    #expect(!text.contains("Reported vs measured"))
    #expect(!text.contains("Round trip at buffer"), "a breakdown is defined for one device only")
  }

  @Test func theArmedLineNamesBothBuffersOnlyWhenTheyDiffer() {
    func line(output: Int, input: Int) -> String {
      let snapshot = SetupSnapshot(
        setup: Self.speakersToMic, sampleRate: 48_000, outputBufferFrames: output,
        inputBufferFrames: input, simulated: false)
      return renderer.armedLine(
        ArmedInfo(
          runId: "r", recipe: RecipeRegistry.roundTrip.ref,
          parameters: RunParameters(hits: 10, seed: 7), setup: snapshot))
    }
    #expect(
      line(output: 512, input: 512).contains("buffer 512)"), "\(line(output: 512, input: 512))")
    #expect(
      line(output: 512, input: 128).contains("buffer 512 out + 128 in)"),
      "\(line(output: 512, input: 128))")
  }
}
