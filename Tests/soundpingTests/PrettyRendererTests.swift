import Foundation
import SoundPingKit
import Testing

@testable import soundping

/// The default terminal output (D-03, ENG-02, RES-01): what Flo reads while a run happens.
@Suite struct PrettyRendererTests {
  private static let sampleRate = 48_000.0
  private static let escape = "\u{1B}"

  // MARK: fixtures

  private static func hit(
    _ index: Int, phase: RunPhase = .measure, frames: Double, confidence: Double = 0.93
  ) -> HitRecord {
    HitRecord(
      index: index, phase: phase, outputFrame: Int64(index) * 30_000, latencyFrames: frames,
      latencyMs: frames / sampleRate * 1000, confidence: confidence, psr: 11)
  }

  private static func rejected(
    _ index: Int, _ reason: RejectionReason, phase: RunPhase = .measure
  ) -> HitRecord {
    HitRecord(index: index, phase: phase, outputFrame: Int64(index) * 30_000, rejection: reason)
  }

  /// 5 warm-ups and 100 measured hits; hit 25 (noPeak) and hit 55 (lowConfidence) are rejected.
  private static func fixtureHits() -> [HitRecord] {
    var hits = (0..<5).map { hit($0, phase: .warmup, frames: 411) }
    for index in 5..<105 {
      switch index {
      case 25: hits.append(rejected(index, .noPeak))
      case 55: hits.append(rejected(index, .lowConfidence))
      default: hits.append(hit(index, frames: 400 + Double(index - 5) * 0.2))
      }
    }
    return hits
  }

  private static func result(
    hits: [HitRecord] = fixtureHits(), corrections: [Correction] = []
  ) -> RunResult {
    let measure = hits.filter { $0.phase == .measure }
    let latencies = measure.compactMap { $0.rejection == nil ? $0.latencyFrames : nil }
    var counts = Dictionary(uniqueKeysWithValues: RejectionReason.allCases.map { ($0.rawValue, 0) })
    for record in measure {
      if let reason = record.rejection { counts[reason.rawValue, default: 0] += 1 }
    }
    return RunResult(
      runId: "20261112T120000Z-round-trip",
      runPath: "/tmp/soundping-store/runs/20261112T120000Z-round-trip",
      createdAt: Date(timeIntervalSince1970: 1_794_484_800),
      toolVersion: "test",
      os: "macOS test",
      recipe: RecipeRegistry.roundTrip.ref,
      label: nil,
      tags: [],
      parameters: RunParameters(hits: measure.count, seed: 7),
      setup: SetupSnapshot(
        setup: .simulatedDuplex, sampleRate: sampleRate, bufferFrames: 128, simulated: true),
      measured: Measured(
        headline: .path, domain: .sample,
        path: Stats.summarize(latencies: latencies, n: measure.count, sampleRate: sampleRate)),
      histogram: Stats.histogram(latencies: latencies),
      hits: hits,
      rejectedCounts: counts,
      segments: RecipeRegistry.roundTrip.segments,
      corrections: corrections,
      simulation: nil)
  }

  private static func plain(_ renderer: PrettyRenderer = PrettyRenderer(useColor: false))
    -> PrettyRenderer
  {
    renderer
  }

  // MARK: hit lines

  @Test func aHitLineShowsIndexPhaseFramesMillisecondsAndConfidence() {
    let line = Self.plain().hitLine(Self.hit(7, frames: 412.37, confidence: 0.934))
    #expect(line.contains("#007"), "\(line)")
    #expect(line.contains("measure"), "\(line)")
    #expect(line.contains("412.37"), "\(line)")
    #expect(line.contains("8.591"), "\(line)")
    #expect(line.contains("0.93"), "\(line)")
  }

  @Test func aRejectedHitLineNamesItsReason() {
    let line = Self.plain().hitLine(Self.rejected(8, .lowConfidence))
    #expect(line.contains("#008"), "\(line)")
    #expect(line.contains("rejected: lowConfidence"), "\(line)")
  }

  @Test func warmUpLinesSayWarmup() {
    let line = Self.plain().hitLine(Self.hit(2, phase: .warmup, frames: 411.5))
    #expect(line.contains("warmup"), "\(line)")
    let rejectedWarmup = Self.plain().hitLine(Self.rejected(3, .noPeak, phase: .warmup))
    #expect(rejectedWarmup.contains("warmup"), "\(rejectedWarmup)")
    #expect(rejectedWarmup.contains("rejected: noPeak"), "\(rejectedWarmup)")
  }

  // MARK: color

  @Test func withColorOnlyRejectedLinesAreDimmed() {
    let renderer = PrettyRenderer(useColor: true)
    let dimmed = renderer.hitLine(Self.rejected(8, .lowConfidence))
    #expect(dimmed.hasPrefix("\(Self.escape)[2m"), "\(dimmed.debugDescription)")
    #expect(dimmed.hasSuffix("\(Self.escape)[0m"), "\(dimmed.debugDescription)")
    #expect(dimmed.contains("rejected: lowConfidence"))

    let normal = renderer.hitLine(Self.hit(7, frames: 412.37))
    #expect(!normal.contains(Self.escape), "\(normal.debugDescription)")
  }

  @Test func withoutColorNothingEmitsAnEscapeByte() {
    let renderer = PrettyRenderer(useColor: false)
    let result = Self.result()
    var output = [renderer.hitLine(Self.rejected(8, .lowConfidence))]
    output.append(renderer.hitLine(Self.hit(7, frames: 412.37)))
    output.append(renderer.summary(result))
    output.append(renderer.histogram(result.histogram))
    output.append(renderer.sparkline(result.hits))
    #expect(output.allSatisfy { !$0.isEmpty })
    #expect(output.allSatisfy { !$0.contains(Self.escape) })
  }

  @Test func colorFollowsTheTerminalAndNoColor() {
    #expect(Terminal.useColor(environment: [:], stdoutIsTTY: true))
    #expect(!Terminal.useColor(environment: [:], stdoutIsTTY: false), "a pipe never gets color")
    #expect(!Terminal.useColor(environment: ["NO_COLOR": "1"], stdoutIsTTY: true))
    #expect(!Terminal.useColor(environment: ["NO_COLOR": "anything"], stdoutIsTTY: true))
    #expect(
      Terminal.useColor(environment: ["NO_COLOR": ""], stdoutIsTTY: true),
      "an empty NO_COLOR does not count (no-color.org)")
  }

  // MARK: summary

  @Test func theSummaryShowsEveryStatisticInFramesAndMilliseconds() throws {
    let result = Self.result()
    let summary = Self.plain().summary(result)
    let path = try #require(result.measured.path)

    #expect(summary.contains("valid 98/100"), "\(summary)")
    for (label, value) in [
      ("median", path.median), ("jitter", path.jitter), ("p95", path.p95), ("max", path.max),
    ] {
      let value = try #require(value)
      let line = try #require(
        summary.split(separator: "\n").first { $0.hasPrefix(label) }, "no \(label) line")
      #expect(line.contains(String(format: "%.3f ms", value.ms)), "\(line)")
      #expect(line.contains(String(format: "%.2f frames", value.frames)), "\(line)")
    }
    #expect(summary.contains("p5–p95"), "jitter names its percentile span")
    #expect(summary.contains("Audio output → Cable or air → Audio input"), "\(summary)")
    #expect(summary.contains("Corrections: none (raw measurement)"), "\(summary)")
    #expect(summary.contains(result.runPath), "\(summary)")
  }

  @Test func rejectedHitsAreCountedInTheSummaryByReason() {
    let summary = Self.plain().summary(Self.result())
    #expect(summary.contains("noPeak 1"), "\(summary)")
    #expect(summary.contains("lowConfidence 1"), "\(summary)")
  }

  @Test func correctionsAreListedWithTheirSource() {
    let correction = Correction(
      name: "interface offset", valueFrames: 48, valueMs: 1, source: .userEntered)
    let summary = Self.plain().summary(Self.result(corrections: [correction]))
    #expect(summary.contains("interface offset"), "\(summary)")
    #expect(summary.contains("userEntered"), "\(summary)")
    #expect(!summary.contains("none (raw measurement)"), "\(summary)")
  }

  @Test func aRunWithoutValidHitsSaysSoInsteadOfPrintingZeros() {
    let hits =
      (0..<5).map { Self.rejected($0, .noPeak, phase: .warmup) }
      + (5..<25).map { Self.rejected($0, .lowConfidence) }
    let result = Self.result(hits: hits)
    let renderer = Self.plain()
    let summary = renderer.summary(result)

    #expect(summary.contains("valid 0/20"), "\(summary)")
    #expect(summary.contains("no valid hits"), "\(summary)")
    #expect(!summary.contains("0.00"), "\(summary)")
    #expect(!summary.contains("median"), "\(summary)")
    #expect(summary.contains("lowConfidence 20"), "\(summary)")
    #expect(renderer.histogram(result.histogram).isEmpty, "no histogram without valid hits")
  }

  // MARK: histogram and sparkline

  @Test func theHistogramHasOneProportionalBarRowPerBin() throws {
    let result = Self.result()
    let histogram = try #require(result.histogram)
    let rows = Self.plain().histogram(result.histogram).split(separator: "\n").map(String.init)
    #expect(rows.count == histogram.counts.count, "one row per bin")

    let bars = rows.map { row in row.filter { $0 == "█" }.count }
    #expect(bars.max() == 40, "the longest bar is 40 columns")
    let largest = try #require(histogram.counts.max())
    for (count, bar) in zip(histogram.counts, bars) {
      let expected = count == 0 ? 0 : max(1, Int((Double(count) / Double(largest) * 40).rounded()))
      #expect(bar == expected, "count \(count) drew \(bar) columns, expected \(expected)")
    }
    for (row, count) in zip(rows, histogram.counts) {
      #expect(row.hasSuffix(" \(count)"), "\(row)")
    }
    let first = String(format: "%.2f", histogram.firstBinStartFrames)
    let firstRow = try #require(rows.first, "no histogram rows")
    #expect(firstRow.contains(first), "the first row starts at the first bin edge: \(firstRow)")
  }

  @Test func theSparklineHasOneCharacterPerMeasuredHit() throws {
    let result = Self.result()
    let line = Self.plain().sparkline(result.hits)
    #expect(line.count == 100, "warm-ups are not drawn")
    try #require(line.count == 100, "the rest of this test indexes into the line")

    let characters = Array(line)
    #expect(characters[20] == "·", "hit 25 was rejected")
    #expect(characters[50] == "·", "hit 55 was rejected")
    #expect(characters[0] == "▁", "the lowest latency draws the lowest block")
    #expect(characters[99] == "█", "the highest latency draws the highest block")
    #expect(characters.filter { "▁▂▃▄▅▆▇█".contains($0) }.count == 98)
  }

  @Test func aSparklineOfIdenticalLatenciesDrawsAFlatLine() {
    let hits = (0..<10).map { Self.hit($0, frames: 412.37) }
    let line = Self.plain().sparkline(hits)
    #expect(line.count == 10)
    #expect(Set(line).count == 1, "\(line)")
  }
}
