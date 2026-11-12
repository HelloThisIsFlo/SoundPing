import Foundation
import SoundPingKit
import Testing

@testable import soundping

/// `soundping runs list` and `runs show` carry BUFFER, PATH and TOTAL and no single "median"
/// (Phase 1 decision, PROJECT.md Key Decisions).
@Suite struct RunsListTests {
  private static func listing(
    id: String, buffer: Double?, path: Double?, total: Double?
  ) -> RunListing {
    RunListing(
      runId: id, createdAt: Date(timeIntervalSince1970: 1_794_484_800), recipe: "round-trip",
      label: "loop", tags: [], bufferFrames: 128, bufferMs: buffer, pathMs: path, totalMs: total,
      valid: 98, n: 100, runPath: "/tmp/\(id)")
  }

  @Test func theTableHasBufferPathAndTotalColumnsInThatOrder() throws {
    let lines = RunsCommand.List.table([
      Self.listing(id: "run-a", buffer: 5.917, path: 0.5625, total: 6.479)
    ])
    let header = try #require(lines.first)
    let columns = header.split(separator: " ").map(String.init)
    #expect(columns == ["RUN", "WHEN", "LABEL", "BUFFER", "PATH", "TOTAL", "VALID"], "\(header)")
    #expect(!header.contains("MEDIAN"))

    let row = try #require(lines.dropFirst().first)
    #expect(row.contains("5.92 ms"), "\(row)")
    #expect(row.contains("0.56 ms"), "\(row)")
    #expect(row.contains("6.48 ms"), "\(row)")
    #expect(row.contains("98/100"), "\(row)")
  }

  @Test func aTwoDeviceRunShowsAPathAndDashesForTheRest() throws {
    let lines = RunsCommand.List.table([
      Self.listing(id: "run-b", buffer: nil, path: 46.0, total: nil)
    ])
    let row = try #require(lines.dropFirst().first)
    #expect(row.contains("46.00 ms"), "\(row)")
    #expect(row.contains(" -  "), "buffer and total are dashes: \(row)")
  }

  @Test func noRunsSaysSo() {
    #expect(RunsCommand.List.table([]) == ["no runs yet"])
  }

  @Test func showPrintsTheThreeFiguresNotOneMedian() {
    let measured = Measured(
      headline: .appRoundTrip, domain: .sample,
      path: SummaryStats(n: 10, valid: 10, median: StatValue(frames: 27, ms: 0.5625)),
      appRoundTrip: SummaryStats(n: 10, valid: 10, median: StatValue(frames: 311, ms: 6.479)),
      ioOffset: SummaryStats(n: 100, valid: 100, median: StatValue(frames: 284, ms: 5.917)))
    let result = RunResult(
      runId: "run-a", runPath: "/tmp/run-a", createdAt: Date(timeIntervalSince1970: 0),
      toolVersion: "test", os: "macOS test", recipe: RecipeRegistry.roundTrip.ref, label: nil,
      tags: [], parameters: RunParameters(hits: 10, seed: 7),
      setup: SetupSnapshot(
        setup: .simulatedDuplex, sampleRate: 48_000, outputBufferFrames: 128,
        inputBufferFrames: 128, simulated: true),
      measured: measured, histogram: nil, hits: [], rejectedCounts: [:],
      segments: RecipeRegistry.roundTrip.segments, corrections: [], simulation: nil)
    let lines = RunsCommand.Show.summaryLines(result)
    #expect(lines.contains { $0.hasPrefix("buffer") && $0.contains("5.92 ms") }, "\(lines)")
    #expect(lines.contains { $0.hasPrefix("path") && $0.contains("0.56 ms") }, "\(lines)")
    #expect(lines.contains { $0.hasPrefix("total") && $0.contains("6.48 ms") }, "\(lines)")
    #expect(!lines.contains { $0.hasPrefix("median") }, "\(lines)")
  }
}
