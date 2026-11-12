import Foundation
import Testing

@testable import SoundPingKit

@Suite struct ResultSchemaTests {
  private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

  private static func result(label: String? = "bench", tags: [String] = ["a", "b"]) -> RunResult {
    RunResult(
      runId: "20231114T221320Z-round-trip",
      runPath: "/tmp/store/runs/20231114T221320Z-round-trip",
      createdAt: createdAt,
      toolVersion: "test",
      os: "macOS test",
      recipe: RecipeRegistry.roundTrip.ref,
      label: label,
      tags: tags,
      parameters: RecipeRegistry.roundTrip.defaultParameters(seed: 1),
      setup: SetupSnapshot(
        setup: .simulatedDuplex, sampleRate: 48_000, bufferFrames: 128, simulated: true),
      measured: Measured(
        headline: .path, domain: .sample,
        path: SummaryStats(
          n: 100, valid: 98, median: StatValue(frames: 400, ms: 8.33),
          jitter: StatValue(frames: 1, ms: 0.02))),
      histogram: Histogram(binWidthFrames: 1, firstBinStartFrames: 399, counts: [1, 5, 2]),
      hits: [HitRecord(index: 0, phase: .warmup, outputFrame: 4800, latencyFrames: 400)],
      rejectedCounts: Dictionary(
        uniqueKeysWithValues: RejectionReason.allCases.map { ($0.rawValue, 0) }),
      segments: RecipeRegistry.roundTrip.segments,
      corrections: [],
      simulation: nil)
  }

  private static func object(of event: RunEvent) throws -> [String: Any] {
    let data = try RunJSON.lineEncoder().encode(event)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private static func object(of result: RunResult) throws -> [String: Any] {
    let data = try RunJSON.fileEncoder().encode(result)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func everyRunEventCaseEncodesItsTypeKey() throws {
    let result = Self.result()
    let record = HitRecord(index: 1, phase: .measure, outputFrame: 9600, latencyFrames: 400)
    let events: [(RunEvent, String)] = [
      (
        .armed(
          ArmedInfo(
            runId: result.runId, recipe: result.recipe, parameters: result.parameters,
            setup: result.setup)), "armed"
      ),
      (.hit(record), "hit"),
      (
        .rejected(HitRecord(index: 2, phase: .measure, outputFrame: 19_200, rejection: .noPeak)),
        "rejected"
      ),
      (.aborted(.deviceChanged("gone", "the device vanished")), "aborted"),
      (.finished(result), "finished"),
    ]
    for (event, expected) in events {
      let object = try Self.object(of: event)
      #expect(object["type"] as? String == expected)
      let decoded = try RunJSON.decoder().decode(
        RunEvent.self, from: try RunJSON.lineEncoder().encode(event))
      #expect(decoded == event)
    }
  }

  @Test func aRunResultRoundTripsUnchanged() throws {
    let original = Self.result()
    let data = try RunStore.encodedBytes(for: original)
    let decoded = try RunJSON.decoder().decode(RunResult.self, from: data)
    #expect(decoded == original)
    #expect(try RunStore.encodedBytes(for: decoded) == data)
  }

  @Test func topLevelKeysAreSorted() throws {
    let text = try #require(
      String(data: try RunJSON.fileEncoder().encode(Self.result()), encoding: .utf8))
    // Pretty printing indents the top-level keys by exactly two spaces.
    let keys = text.split(separator: "\n").compactMap { line -> String? in
      guard line.hasPrefix("  \""), !line.hasPrefix("   ") else { return nil }
      return line.dropFirst(3).prefix { $0 != "\"" }.description
    }
    #expect(keys.count >= 10)
    #expect(keys == keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
  }

  @Test func schemaVersionAndTimestamp() throws {
    let object = try Self.object(of: Self.result())
    #expect(object["schemaVersion"] as? Int == 1)
    let createdAt = try #require(object["createdAt"] as? String)
    #expect(createdAt.hasSuffix("Z"))
    #expect(createdAt == "2023-11-14T22:13:20Z")
  }

  @Test func emptyCorrectionsAndTagsEncodeAsEmptyArrays() throws {
    let object = try Self.object(of: Self.result(label: nil, tags: []))
    let corrections = try #require(object["corrections"] as? [Any])
    let tags = try #require(object["tags"] as? [Any])
    #expect(corrections.isEmpty)
    #expect(tags.isEmpty)
  }

  @Test func segmentsDecodeInSignalFlowOrder() throws {
    let data = try RunJSON.fileEncoder().encode(Self.result())
    let decoded = try RunJSON.decoder().decode(RunResult.self, from: data)
    #expect(decoded.segments.map(\.id) == ["audioOutput", "transmission", "audioInput"])
  }
}
