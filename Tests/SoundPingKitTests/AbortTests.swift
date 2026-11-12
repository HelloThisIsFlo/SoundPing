import Foundation
import Testing

@testable import SoundPingKit

/// Forwards to the simulator and reports the device gone only after the run's last measurement,
/// when the coordinator is no longer listening: such an event must change nothing.
private actor LateEventBackend: AudioBackend {
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
  func start() async throws { try await inner.start() }
  func currentInputFrame() async -> Int64 { await inner.currentInputFrame() }
  func currentOutputFrame() async -> Int64 { await inner.currentOutputFrame() }
  func schedule(_ hits: [ScheduledHit]) async throws { try await inner.schedule(hits) }
  func waitUntilCaptured(throughInputFrame frame: Int64) async throws {
    try await inner.waitUntilCaptured(throughInputFrame: frame)
  }
  func capture(_ range: Range<Int64>) async throws -> [Float] { try await inner.capture(range) }
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    await inner.stamps(covering: range)
  }
  func stampLog() async -> StampLog { await inner.stampLog() }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }

  func stop() async {
    continuation.yield(.gone(uid: "soundping-sim-duplex"))
    await inner.stop()
    continuation.finish()
  }
}

@Suite struct AbortTests {
  private struct Outcome {
    var events: [RunEvent]
    var error: SoundPingError?
    var store: RunStore
    var result: RunResult? {
      for case .finished(let result) in events { return result }
      return nil
    }
  }

  private static func makeStore() throws -> (store: RunStore, cleanup: @Sendable () -> Void) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    let paths = try StorePaths.resolve(flag: folder.path, environment: [:])
    return (RunStore(paths: paths), { try? FileManager.default.removeItem(at: folder) })
  }

  private static func request(hits: Int, seed: UInt64 = 5) -> RunRequest {
    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: seed)
    parameters.hits = hits
    return RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: .simulatedDuplex)
  }

  private static func run(
    _ backend: any AudioBackend, hits: Int, store: RunStore
  ) async -> Outcome {
    var events: [RunEvent] = []
    var thrown: SoundPingError?
    do {
      for try await event in RunCoordinator(backend: backend, store: store).run(
        request(hits: hits))
      {
        events.append(event)
      }
    } catch {
      thrown = error as? SoundPingError
    }
    return Outcome(events: events, error: thrown, store: store)
  }

  private static func run(_ faults: [Fault], hits: Int, store: RunStore) async -> Outcome {
    let scenario = Scenario(jitterFrames: 0.5, faults: faults, seed: 5)
    return await run(SimulatedBackend(scenario: scenario), hits: hits, store: store)
  }

  /// No run folder under `runs/` holds a run.json: nothing was saved as a complete run.
  private static func savedRunFiles(in store: RunStore) -> [String] {
    let folders =
      (try? FileManager.default.contentsOfDirectory(atPath: store.paths.runs.path)) ?? []
    return folders.filter {
      FileManager.default.fileExists(
        atPath: store.paths.runs.appendingPathComponent($0).appendingPathComponent("run.json").path)
    }
  }

  private static func abortCodes(_ events: [RunEvent]) -> [String] {
    events.compactMap {
      if case .aborted(let error) = $0 { return error.code }
      return nil
    }
  }

  private static func hasFinished(_ events: [RunEvent]) -> Bool {
    events.contains {
      if case .finished = $0 { return true }
      return false
    }
  }

  // MARK: Every named failure is announced on the stream

  @Test func aRefusedRunIsAnnouncedOnTheStreamBeforeItThrows() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let outcome = await Self.run(
      SimulatedBackend(scenario: Scenario(jitterFrames: 0, seed: 5)), hits: 0, store: store)

    #expect(outcome.error?.code == "invalidParameters")
    #expect(Self.abortCodes(outcome.events) == ["invalidParameters"])
    #expect(!Self.hasFinished(outcome.events))
  }

  // MARK: Device changes abort with a named cause

  @Test func aSampleRateChangeAtHitThirtyAbortsTheRun() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let outcome = await Self.run(
      [Fault(kind: .sampleRateChange, atHit: 30)], hits: 40, store: store)

    let error = try #require(outcome.error)
    #expect(error.kind == .deviceChanged)
    #expect(error.code == "sampleRateChanged")
    #expect(Self.abortCodes(outcome.events) == ["sampleRateChanged"])
    // The abort is the last thing the stream says; no summary follows it.
    if case .aborted = outcome.events.last {} else { Issue.record("last event is not aborted") }
    #expect(!Self.hasFinished(outcome.events))
    #expect(Self.savedRunFiles(in: outcome.store).isEmpty)
    // Hit 30 had not been measured yet: nothing after the fault's hit was reported as a result.
    let reported = outcome.events.compactMap { event -> Int? in
      switch event {
      case .hit(let record), .rejected(let record): return record.index
      default: return nil
      }
    }
    #expect((reported.max() ?? 0) <= 30)
  }

  @Test func aDeviceLostAtTheFirstMeasuredHitAborts() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    // Five warm-ups, so hit index 5 is the first measured hit.
    let outcome = await Self.run([Fault(kind: .deviceGone, atHit: 5)], hits: 20, store: store)

    #expect(outcome.error?.kind == .deviceChanged)
    #expect(outcome.error?.code == "deviceGone")
    #expect(!Self.hasFinished(outcome.events))
    #expect(Self.savedRunFiles(in: outcome.store).isEmpty)
  }

  @Test func aBufferChangeInsideTheLastHitsWindowStillAborts() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    // 20 measured hits after 5 warm-ups: the last hit is index 24.
    let outcome = await Self.run([Fault(kind: .bufferChange, atHit: 24)], hits: 20, store: store)

    #expect(outcome.error?.kind == .deviceChanged)
    #expect(outcome.error?.code == "bufferSizeChanged")
    #expect(!Self.hasFinished(outcome.events))
    #expect(Self.savedRunFiles(in: outcome.store).isEmpty)
  }

  @Test func aStreamConfigurationChangeAborts() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let outcome = await Self.run(
      [Fault(kind: .streamConfigChange, atHit: 8)], hits: 20, store: store)

    #expect(outcome.error?.kind == .deviceChanged)
    #expect(outcome.error?.code == "streamConfigChanged")
    #expect(Self.savedRunFiles(in: outcome.store).isEmpty)
  }

  @Test func theFirstOfTwoFaultsDecidesTheCause() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let outcome = await Self.run(
      [Fault(kind: .deviceGone, atHit: 14), Fault(kind: .sampleRateChange, atHit: 9)],
      hits: 20, store: store)

    #expect(outcome.error?.code == "sampleRateChanged")
    #expect(Self.abortCodes(outcome.events) == ["sampleRateChanged"])
  }

  // MARK: Boundaries

  @Test func anEventAfterTheRunFinishedIsIgnored() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let backend = LateEventBackend(scenario: Scenario(jitterFrames: 0.5, seed: 5))
    let outcome = await Self.run(backend, hits: 10, store: store)

    #expect(outcome.error == nil)
    #expect(Self.hasFinished(outcome.events))
    #expect(Self.abortCodes(outcome.events).isEmpty)
    #expect(Self.savedRunFiles(in: outcome.store).count == 1)
  }

  @Test func aRunWithNoFaultsIsUnchanged() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let outcome = await Self.run([], hits: 10, store: store)
    #expect(outcome.error == nil)
    #expect(outcome.result?.measured.path?.valid == 10)
  }

  // MARK: Overloads reject hits, they do not abort

  @Test func anOverloadAtHitTwelveRejectsOnlyThatHit() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let outcome = await Self.run([Fault(kind: .overload, atHit: 12)], hits: 20, store: store)

    #expect(outcome.error == nil)
    let result = try #require(outcome.result)
    let rejected = result.hits.filter { $0.rejection != nil }
    #expect(rejected.map(\.index) == [12])
    #expect(rejected.first?.rejection == .discontinuity)
    #expect(result.measured.path?.valid == 19)
    #expect(result.rejectedCounts[RejectionReason.discontinuity.rawValue] == 1)
    #expect(Self.abortCodes(outcome.events).isEmpty)
  }

  // MARK: The fault list itself

  @Test func aFaultAtAHitTheRunNeverFiresIsAUsageError() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let outcome = await Self.run([Fault(kind: .overload, atHit: 999)], hits: 10, store: store)

    #expect(outcome.error?.kind == .usage)
    #expect(outcome.error?.code == "invalidParameters")
    #expect(Self.savedRunFiles(in: outcome.store).isEmpty)
  }

  @Test func faultSpecsParseAsKindAtHit() throws {
    #expect(try Fault.parse("sampleRateChange@30") == Fault(kind: .sampleRateChange, atHit: 30))
    #expect(try Fault.parse("deviceGone@0") == Fault(kind: .deviceGone, atHit: 0))
    for kind in Fault.Kind.allCases {
      #expect(try Fault.parse("\(kind.rawValue)@7") == Fault(kind: kind, atHit: 7))
    }
  }

  @Test func malformedFaultSpecsAreUsageErrors() {
    for spec in [
      "", "sampleRateChange", "sampleRateChange@", "@3", "nonsense@3", "overload@-1",
      "overload@x", "overload@3@4",
    ] {
      let error = #expect(throws: SoundPingError.self) { _ = try Fault.parse(spec) }
      #expect(error?.kind == .usage, "'\(spec)'")
      #expect(error?.code == "invalidParameters", "'\(spec)'")
    }
  }

  @Test func faultsSurviveRunJSONAndOldFilesStillDecode() throws {
    let scenario = Scenario(
      faults: [Fault(kind: .overload, atHit: 3), Fault(kind: .deviceGone, atHit: 9)], seed: 4)
    let data = try JSONEncoder().encode(scenario)
    #expect(try JSONDecoder().decode(Scenario.self, from: data) == scenario)

    // A run.json written before faults existed has no such key.
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "faults")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(Scenario.self, from: legacy).faults.isEmpty)
  }

  // MARK: What the HAL listeners cover

  @Test func theListenersCoverEveryChangeTheHALAnnounces() {
    let codes = Set(DeviceListeners.deviceSelectors.compactMap { HALProperty.fourCharCode($0) })
    #expect(codes == ["livn", "nsrt", "fsiz", "slay", "over", "stpd"])
    #expect(HALProperty.fourCharCode(DeviceListeners.systemSelector) == "dev#")
  }
}
