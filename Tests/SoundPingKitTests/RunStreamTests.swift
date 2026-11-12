import Foundation
import Testing

@testable import SoundPingKit

/// The event stream every renderer and the later app read (ENG-02): order, adjacency and the
/// empty case. A run opens with its level probes, then exactly one `levelLocked`, then `armed`
/// (the preflight, 01-08), then one hit or rejected event per warm-up and measured hit, then
/// `finished`.
@Suite struct RunStreamTests {
  private struct Collected {
    var events: [RunEvent]
    var store: RunStore

    var armed: ArmedInfo? {
      for case .armed(let info) in events { return info }
      return nil
    }

    /// The probe events before the lock, the lock itself, and `armed`: the opening of every run.
    var probeCount: Int {
      events.prefix { if case .probe = $0 { return true } else { return false } }.count
    }

    var lockCount: Int {
      events.filter { if case .levelLocked = $0 { return true } else { return false } }.count
    }

    /// True when the stream opens with probes, then the lock, then `armed`.
    var opensWithProbesLockAndArmed: Bool {
      let opening = probeCount
      guard events.count > opening + 1 else { return false }
      guard case .levelLocked = events[opening], case .armed = events[opening + 1] else {
        return false
      }
      return true
    }

    var finished: RunResult? {
      if case .finished(let result) = events.last { return result }
      return nil
    }

    /// The hit and rejected events between `armed` and `finished`, in emission order.
    var hitEvents: [HitRecord] {
      events.compactMap {
        switch $0 {
        case .hit(let record), .rejected(let record): return record
        default: return nil
        }
      }
    }
  }

  private static func collect(_ scenario: Scenario, hits: Int, warmup: Int) async throws
    -> Collected
  {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))

    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: scenario.seed)
    parameters.hits = hits
    parameters.warmup = warmup
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: .simulatedDuplex)
    let coordinator = RunCoordinator(backend: SimulatedBackend(scenario: scenario), store: store)

    var events: [RunEvent] = []
    for try await event in coordinator.run(request) { events.append(event) }
    return Collected(events: events, store: store)
  }

  private static func cleanUp(_ collected: Collected) {
    try? FileManager.default.removeItem(at: collected.store.paths.root)
  }

  @Test func aNormalRunIsArmedThenOneLinePerHitThenFinished() async throws {
    let collected = try await Self.collect(
      Scenario(jitterFrames: 0.5, seed: 7), hits: 20, warmup: 5)
    defer { Self.cleanUp(collected) }

    #expect(collected.armed != nil)
    #expect(collected.probeCount >= 1, "the stream opens with at least one probe")
    #expect(collected.lockCount == 1, "exactly one levelLocked")
    #expect(collected.opensWithProbesLockAndArmed, "probes, then levelLocked, then armed")
    let result = try #require(collected.finished, "the last event is finished")
    // probes, levelLocked, armed, 25 hits, the same-device clock self-test, finished.
    #expect(collected.events.count == collected.probeCount + 1 + 1 + 25 + 1 + 1)
    if case .selfTest(let selfTest) = collected.events[collected.events.count - 2] {
      #expect(selfTest.pass)
    } else {
      Issue.record("the event before finished is the clock self-test")
    }

    let hitEvents = collected.hitEvents
    #expect(hitEvents.count == 25)
    #expect(hitEvents.map(\.index) == Array(0..<25), "indices strictly increase in schedule order")

    // The result on the stream is the result on disk.
    let saved = try collected.store.load(result.runId)
    #expect(saved == result)
    #expect(try #require(result.measured.path).valid == 20)
  }

  @Test func everyHitRejectedStillEmitsArmedRejectedLinesAndFinished() async throws {
    // Every scheduled hit (5 warm-ups, 20 measured) never arrives at the normal in-window latency.
    // Missed hits play no stimulus, so the capture holds noise and each hit is rejected.
    let missedHits = Array(0...24)
    let collected = try await Self.collect(
      Scenario(jitterFrames: 0, missedHits: missedHits, seed: 7), hits: 20, warmup: 5)
    defer { Self.cleanUp(collected) }

    #expect(collected.armed != nil)
    #expect(
      collected.opensWithProbesLockAndArmed, "the ramp locks on probes no missed-hit knob reaches")
    #expect(collected.lockCount == 1)
    let result = try #require(collected.finished)

    let rejected = collected.events.compactMap { event -> HitRecord? in
      if case .rejected(let record) = event { return record }
      return nil
    }
    #expect(rejected.count == 25)
    #expect(
      !collected.events.contains {
        if case .hit = $0 { return true }
        return false
      }, "no hit event for a run where nothing arrived")
    #expect(
      rejected.allSatisfy { $0.rejection == .noPeak || $0.rejection == .lowConfidence })
    #expect(collected.hitEvents.map(\.index) == Array(0..<25))

    let path = try #require(result.measured.path)
    #expect(path.valid == 0)
    #expect(path.n == 20)
    #expect(path.median == nil, "no valid hits means no median, never zero")
    #expect(result.histogram == nil)
  }

  @Test func aHitAndAnAdjacentRejectedHitAreTwoSeparateEventsInOrder() async throws {
    // Hit 8 never arrives; hits 7 and 9 do. The three stay three separate lines.
    let collected = try await Self.collect(
      Scenario(jitterFrames: 0, missedHits: [8], seed: 7), hits: 20, warmup: 5)
    defer { Self.cleanUp(collected) }

    let tagged = collected.events.compactMap { event -> (String, Int)? in
      switch event {
      case .hit(let record): return ("hit", record.index)
      case .rejected(let record): return ("rejected", record.index)
      default: return nil
      }
    }
    #expect(tagged.count == 25)
    #expect(tagged[7].0 == "hit" && tagged[7].1 == 7)
    #expect(tagged[8].0 == "rejected" && tagged[8].1 == 8)
    #expect(tagged[9].0 == "hit" && tagged[9].1 == 9)
  }
}
