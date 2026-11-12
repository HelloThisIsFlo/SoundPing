import Foundation
import Testing

@testable import SoundPingKit

/// A simulated device that reports itself gone once the first hit is captured, then hangs the
/// way a vanished real device does until the coordinator cancels the wait.
private actor GoneAfterFirstHitBackend: AudioBackend {
  private let inner: SimulatedBackend
  private let continuation: AsyncStream<DeviceEvent>.Continuation
  nonisolated let events: AsyncStream<DeviceEvent>
  private var waits = 0
  private(set) var stopCount = 0

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
  func capture(_ range: Range<Int64>) async throws -> [Float] { try await inner.capture(range) }
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    await inner.stamps(covering: range)
  }

  func stampLog() async -> StampLog { await inner.stampLog() }
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval] {
    await inner.faults(overlappingInput: input, output: output)
  }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }

  func waitUntilCaptured(throughInputFrame: Int64) async throws {
    waits += 1
    if waits == 1 {
      try await inner.waitUntilCaptured(throughInputFrame: throughInputFrame)
      continuation.yield(.gone(uid: "soundping-sim-duplex"))
    } else {
      try await Task.sleep(for: .seconds(60))
    }
  }

  func stop() async {
    stopCount += 1
    await inner.stop()
    continuation.finish()
  }
}

@Suite struct SimulationRecoveryTests {
  private static func makeStore() throws -> (store: RunStore, cleanup: @Sendable () -> Void) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    let paths = try StorePaths.resolve(flag: folder.path, environment: [:])
    return (RunStore(paths: paths), { try? FileManager.default.removeItem(at: folder) })
  }

  private static func request(seed: UInt64, hits: Int = 100) -> RunRequest {
    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: seed)
    parameters.hits = hits
    return RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: .simulatedDuplex)
  }

  private static func finish(_ request: RunRequest, scenario: Scenario) async throws -> RunResult {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let coordinator = RunCoordinator(backend: SimulatedBackend(scenario: scenario), store: store)
    var result: RunResult?
    for try await event in coordinator.run(request) {
      if case .finished(let finished) = event { result = finished }
    }
    return try #require(result)
  }

  @Test func recoversInjectedLatencyAndExcludesWarmups() async throws {
    let scenario = Scenario(latencyFrames: 412.37, jitterFrames: 0, seed: 7)
    let result = try await Self.finish(Self.request(seed: 7), scenario: scenario)

    let path = try #require(result.measured.path)
    #expect(abs(try #require(path.median).frames - 412.37) <= 0.1)
    #expect(path.valid == 100)
    #expect(path.n == 100)

    let warmups = result.hits.filter { $0.phase == .warmup }
    #expect(warmups.count == 5)
    #expect(result.hits.prefix(5).allSatisfy { $0.phase == .warmup })
    #expect(result.hits.count == 105)
  }

  @Test func jitterTracksTheInjectedSpread() async throws {
    let scenario = Scenario(latencyFrames: 412.37, jitterFrames: 2.0, seed: 11)
    let result = try await Self.finish(Self.request(seed: 11, hits: 400), scenario: scenario)

    let jitter = try #require(result.measured.path?.jitter).frames
    let expected = 3.29 * 2.0
    #expect(abs(jitter - expected) <= expected * 0.10)
  }

  @Test func aFullRunFinishesFast() async throws {
    let scenario = Scenario(seed: 3)
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await Self.finish(Self.request(seed: 3), scenario: scenario)
    let elapsed = clock.now - start

    #expect(result.hits.count == 105)
    // The point is that virtual time never sleeps: 105 hits spaced 450-750 ms would take a minute
    // of wall clock. The bound is generous because `swift test` runs every suite in parallel and
    // this run shares the CPU with them (a bare run takes about half a second in a debug build).
    #expect(elapsed < .seconds(10))
  }

  @Test func aVanishedDeviceAbortsTheRun() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let backend = GoneAfterFirstHitBackend(scenario: Scenario(seed: 5))
    let coordinator = RunCoordinator(backend: backend, store: store)

    var events: [RunEvent] = []
    var thrown: Error?
    do {
      for try await event in coordinator.run(Self.request(seed: 5)) { events.append(event) }
    } catch {
      thrown = error
    }

    let error = try #require(thrown as? SoundPingError)
    #expect(error.kind == .deviceChanged)
    #expect(error.code == "deviceGone")
    #expect(
      events.contains {
        if case .aborted(let aborted) = $0 { return aborted.code == "deviceGone" }
        return false
      })
    #expect(
      !events.contains {
        if case .finished = $0 { return true }
        return false
      })
    #expect(await backend.stopCount >= 1)
  }

  // MARK: A reopened simulator has a live event stream (IN-20)

  @Test(.timeLimit(.minutes(1)))
  func aDeviceEventAfterAStopAndReopenStillEndsTheRun() async throws {
    // What the channel probe does on --simulate: open and stop once per channel, then measure.
    let backend = SimulatedBackend(
      scenario: Scenario(jitterFrames: 0, faults: [Fault(kind: .sampleRateChange, atHit: 3)], seed: 5))
    let nominal = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: 48_000)
    _ = try await backend.open(.simulatedDuplex, templates: [nominal])
    let first = backend.events
    await backend.stop()
    for await _ in first {}  // returns only because stop() finished that open's stream

    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    var thrown: SoundPingError?
    do {
      for try await _ in RunCoordinator(backend: backend, store: store).run(
        Self.request(seed: 5, hits: 20))
      {}
    } catch {
      thrown = error as? SoundPingError
    }
    #expect(thrown?.kind == .deviceChanged)
    #expect(thrown?.code == "sampleRateChanged")
  }

  @Test(.timeLimit(.minutes(1)))
  func anOpenOnAnOpenSimulatorFinishesThePreviousOpensStream() async throws {
    let backend = SimulatedBackend(scenario: Scenario(seed: 5))
    let nominal = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: 48_000)
    _ = try await backend.open(.simulatedDuplex, templates: [nominal])
    let first = backend.events
    _ = try await backend.open(.simulatedDuplex, templates: [nominal])
    for await _ in first {}  // the second open stopped the first, as the HAL backend does
    let second = backend.events
    await backend.stop()
    for await _ in second {}
  }
}
