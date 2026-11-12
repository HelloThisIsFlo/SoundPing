import Foundation
import Testing

@testable import SoundPingKit

/// Broken hits are named and counted, never dropped and never turned into a wrong number (RES-01).
@Suite struct RejectionTests {
  private static func run(_ scenario: Scenario, hits: Int = 30) async throws -> RunResult {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))

    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: scenario.seed)
    parameters.hits = hits
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: .simulatedDuplex)
    let coordinator = RunCoordinator(backend: SimulatedBackend(scenario: scenario), store: store)

    var result: RunResult?
    for try await event in coordinator.run(request) {
      if case .finished(let finished) = event { result = finished }
    }
    return try #require(result)
  }

  @Test func missedHitsAndAnXrunAreRejectedWithTheirReason() async throws {
    let scenario = Scenario(
      latencyFrames: 412.37, jitterFrames: 0, missedHits: [8, 15], xrunHits: [25], seed: 7)
    let result = try await Self.run(scenario)

    #expect(result.hits.count == 35)
    let path = try #require(result.measured.path)
    #expect(path.n == 30)
    #expect(path.valid == 27)

    func rejection(_ index: Int) -> RejectionReason? {
      result.hits.first { $0.index == index }?.rejection
    }
    #expect(rejection(25) == .discontinuity)
    for index in [8, 15] {
      let reason = rejection(index)
      #expect(
        reason == .noPeak || reason == .lowConfidence, "hit \(index): \(String(describing: reason))"
      )
    }
    #expect(result.rejectedCounts.values.reduce(0, +) == 3)
    #expect(result.rejectedCounts[RejectionReason.discontinuity.rawValue] == 1)

    // The rejected hits stay in hits[] but carry no number, and the statistics ignore them.
    #expect(result.hits.filter { $0.rejection != nil }.allSatisfy { $0.latencyFrames == nil })
    #expect(abs(try #require(path.median).frames - 412.37) <= 0.1)
  }

  // The level ramp keeps an engine run below clipping: a hot path locks at the first probe and a
  // hopeless one stops as `inputClipping` (LevelRampTests pins both). The correlator's own guard
  // still has to catch a gain change in the middle of a run, so it is tested on a window it is
  // handed directly: the chirp driven five times past full scale and flattened by the converter.
  @Test func aFlatToppedChirpIsRejectedAsClipped() throws {
    let template = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: 48_000)
    var window = [Float](repeating: 0, count: 3_000)
    for (index, sample) in template.samples.enumerated() {
      window[600 + index] = Swift.max(-1, Swift.min(1, sample * 5))
    }
    let span = window[600..<(600 + template.samples.count)]
    #expect(span.filter { abs($0) >= 0.999 }.count >= 3, "the synthesized span really is clipped")

    let detection = Correlator(template: template).detect(
      window: window, windowStartFrame: 0, stamps: [])
    #expect(detection == .rejected(.clipped))
  }

  @Test func aCleanChirpInTheSameWindowIsNotRejectedAsClipped() throws {
    let template = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: 48_000)
    var window = [Float](repeating: 0, count: 3_000)
    for (index, sample) in template.samples.enumerated() { window[600 + index] = sample * 0.3 }

    let detection = Correlator(template: template).detect(
      window: window, windowStartFrame: 0, stamps: [])
    guard case .found(let frame, _, _, _) = detection else {
      Issue.record("expected a found hit, got \(detection)")
      return
    }
    #expect(abs(frame - 600) < 0.5)
  }

  @Test func aFaultIndexBeyondTheRunIsAUsageError() async throws {
    let scenario = Scenario(jitterFrames: 0, xrunHits: [999], seed: 3)
    await #expect(throws: SoundPingError.self) {
      _ = try await Self.run(scenario, hits: 10)
    }
  }
}
