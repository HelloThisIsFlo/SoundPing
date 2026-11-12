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

  // +30 dB lands exactly on full scale at the -30 dBFS start level, which clips only 17 of 20 hits;
  // +40 dB drives the converter well past it.
  @Test func aHotPathClipsAndEveryHitIsRejectedAsClipped() async throws {
    let scenario = Scenario(latencyFrames: 412.37, jitterFrames: 0, pathGainDb: 40, seed: 9)
    let result = try await Self.run(scenario, hits: 20)

    let measured = result.hits.filter { $0.phase == .measure }
    #expect(measured.count == 20)
    #expect(measured.allSatisfy { $0.rejection == .clipped })
    #expect(result.rejectedCounts[RejectionReason.clipped.rawValue] == 20)
    #expect(try #require(result.measured.path).valid == 0)
    #expect(result.measured.path?.median == nil)
  }

  @Test func aFaultIndexBeyondTheRunIsAUsageError() async throws {
    let scenario = Scenario(jitterFrames: 0, xrunHits: [999], seed: 3)
    await #expect(throws: SoundPingError.self) {
      _ = try await Self.run(scenario, hits: 10)
    }
  }
}
