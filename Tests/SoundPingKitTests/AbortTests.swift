import CoreAudio
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
  func start() async throws -> BackendInfo { try await inner.start() }
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
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval] {
    await inner.faults(overlappingInput: input, output: output)
  }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }

  func stop() async {
    continuation.yield(.gone(uid: "soundping-sim-duplex"))
    await inner.stop()
    continuation.finish()
  }
}

/// Forwards to the simulator and announces that the output switched to its headphone data source
/// while the first probe of the ramp waits for its samples, like headphones plugged into a built-in
/// output during the run (WR-14).
private actor RouteChangeBackend: AudioBackend {
  private let inner: SimulatedBackend
  private let continuation: AsyncStream<DeviceEvent>.Continuation
  private var announced = false
  nonisolated let events: AsyncStream<DeviceEvent>

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
  func waitUntilCaptured(throughInputFrame frame: Int64) async throws {
    if !announced {
      announced = true
      continuation.yield(
        .outputRouteChanged(
          uid: "soundping-sim-duplex", property: "dataSource", from: "ispk", to: "hdpn"))
      // The coordinator ends the run on the event; this wait never completes on its own.
      while true { try await Task.sleep(for: .seconds(3600)) }
    }
    try await inner.waitUntilCaptured(throughInputFrame: frame)
  }
  func capture(_ range: Range<Int64>) async throws -> [Float] { try await inner.capture(range) }
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    await inner.stamps(covering: range)
  }
  func stampLog() async -> StampLog { await inner.stampLog() }
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval] {
    await inner.faults(overlappingInput: input, output: output)
  }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }
  func stop() async {
    await inner.stop()
    continuation.finish()
  }
}

/// Forwards to the simulator, but from the second `open` on reports headphones plugged in between
/// two channels of a probe, while no backend was watching (WR-15): the built-in output on its
/// headphone data source, or only its jack connected (the data source unchanged). Remembers what
/// was scheduled after that switch.
private actor RouteBetweenOpensBackend: AudioBackend {
  enum Switch: Sendable { case dataSource, jackOnly }

  private let inner: SimulatedBackend
  private let switching: Switch
  private var opens = 0
  private(set) var scheduledAfterSwitch = 0
  nonisolated let events: AsyncStream<DeviceEvent>

  init(scenario: Scenario, switching: Switch = .dataSource) {
    inner = SimulatedBackend(scenario: scenario)
    self.switching = switching
    events = inner.events
  }

  var openCount: Int { opens }

  func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws -> BackendInfo {
    var info = try await inner.open(setup, templates: templates)
    opens += 1
    switch switching {
    case .dataSource:
      if opens > 1 { info.outputDevice?.output?.dataSource = "hdpn" }
    case .jackOnly:
      info.outputJack = opens > 1 ? "connected" : "disconnected"
    }
    return info
  }
  func start() async throws -> BackendInfo { try await inner.start() }
  func currentInputFrame() async -> Int64 { await inner.currentInputFrame() }
  func currentOutputFrame() async -> Int64 { await inner.currentOutputFrame() }
  func schedule(_ hits: [ScheduledHit]) async throws {
    if opens > 1 { scheduledAfterSwitch += hits.count }
    try await inner.schedule(hits)
  }
  func waitUntilCaptured(throughInputFrame frame: Int64) async throws {
    try await inner.waitUntilCaptured(throughInputFrame: frame)
  }
  func capture(_ range: Range<Int64>) async throws -> [Float] { try await inner.capture(range) }
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    await inner.stamps(covering: range)
  }
  func stampLog() async -> StampLog { await inner.stampLog() }
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval] {
    await inner.faults(overlappingInput: input, output: output)
  }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }
  func stop() async { await inner.stop() }
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
    let route = Set(
      DeviceListeners.outputRouteSelectors.compactMap { HALProperty.fourCharCode($0) })
    #expect(route == ["ssrc", "jack"])
  }

  /// The one comparison both output-route properties go through, against the value read at open,
  /// at registration and on every notification (the HAL wiring itself is the hardware test
  /// `theOutputRouteIsWatchedOnARealBuiltInOutput`).
  @Test(arguments: [
    ("dataSource", "ispk", "hdpn"), ("jackIsConnected", "disconnected", "connected"),
  ])
  func anOutputRoutePropertyThatLeavesItsOpenValueIsARouteChange(
    property: String, opened: String, now: String
  ) {
    #expect(
      DeviceListeners.routeChange(
        uid: "built-in", property: property, baseline: opened, now: opened)
        == nil)
    #expect(
      DeviceListeners.routeChange(uid: "built-in", property: property, baseline: opened, now: now)
        == .outputRouteChanged(uid: "built-in", property: property, from: opened, to: now))
    #expect(
      DeviceListeners.routeChange(uid: "built-in", property: property, baseline: opened, now: nil)
        == .outputRouteChanged(uid: "built-in", property: property, from: opened, to: "none"))
    #expect(
      DeviceListeners.routeChange(uid: "built-in", property: property, baseline: nil, now: nil)
        == nil)
  }

  // MARK: An output that switches route aborts (WR-14)

  @Test func anOutputRouteChangeIsADeviceChange() {
    let error = SoundPingError.forDeviceEvent(
      .outputRouteChanged(uid: "built-in", property: "dataSource", from: "ispk", to: "hdpn"))
    #expect(error.kind == .deviceChanged)
    #expect(error.code == "outputRouteChanged")
    #expect(error.context["from"] == "ispk")
    #expect(error.context["to"] == "hdpn")
    #expect(error.context["property"] == "dataSource")
  }

  @Test func headphonesPluggedInDuringTheRampAbortTheRunBeforeAnyHit() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let outcome = await Self.run(
      RouteChangeBackend(scenario: Scenario(jitterFrames: 0, seed: 5)), hits: 20, store: store)

    #expect(outcome.error?.kind == .deviceChanged)
    #expect(outcome.error?.code == "outputRouteChanged")
    #expect(Self.abortCodes(outcome.events) == ["outputRouteChanged"])
    #expect(!Self.hasFinished(outcome.events))
    #expect(Self.savedRunFiles(in: store).isEmpty)
  }

  @Test func headphonesPluggedInDuringAChannelProbeEndTheProbe() async throws {
    let scarlett = SimulatedCatalog.scarlett
    let setup = ResolvedSetup(
      output: scarlett.ref, input: scarlett.ref, outChannels: [1, 2], inChannel: 0,
      autoInChannel: true)
    var thrown: SoundPingError?
    do {
      _ = try await ChannelProbe().run(
        backend: RouteChangeBackend(scenario: Scenario(jitterFrames: 0, loopChannel: 7, seed: 3)),
        setup: setup, channels: scarlett.input?.channels ?? [])
    } catch {
      thrown = error as? SoundPingError
    }
    #expect(thrown?.kind == .deviceChanged)
    #expect(thrown?.code == "outputRouteChanged")
  }

  @Test func headphonesPluggedInBetweenTwoProbedChannelsEndTheProbe() async throws {
    // The built-in speakers get -12 dBFS; the next channel's open sees the headphone source. It
    // must not keep probing at -12 into the headphones (WR-15).
    let speakers = SimulatedCatalog.macSpeakers
    #expect(speakers.output?.dataSource == "ispk")
    let scarlett = SimulatedCatalog.scarlett
    let setup = ResolvedSetup(
      output: speakers.ref, input: scarlett.ref, outChannels: [1, 2], inChannel: 0,
      autoInChannel: true)
    let backend = RouteBetweenOpensBackend(
      scenario: Scenario(jitterFrames: 0, pathGainDb: -80, loopChannel: 7, seed: 3))
    var thrown: SoundPingError?
    do {
      _ = try await ChannelProbe().run(
        backend: backend, setup: setup, channels: Array((scarlett.input?.channels ?? []).prefix(3)))
    } catch {
      thrown = error as? SoundPingError
    }
    #expect(thrown?.kind == .deviceChanged)
    #expect(thrown?.code == "outputRouteChanged")
    #expect(thrown?.context["property"] == "dataSource")
    #expect(thrown?.context["from"] == "ispk")
    #expect(thrown?.context["to"] == "hdpn")
    #expect(await backend.openCount == 2, "the probe ends at the first reopen")
    #expect(await backend.scheduledAfterSwitch == 0, "nothing is played after the switch")
  }

  @Test func aJackPluggedInBetweenTwoProbedChannelsEndsTheProbeEvenOnTheSameDataSource()
    async throws
  {
    // Only the jack moves; the data source stays `ispk`. The jack state the probe started with is
    // carried across reopens like the data source, so it must not keep probing into headphones.
    let speakers = SimulatedCatalog.macSpeakers
    let scarlett = SimulatedCatalog.scarlett
    let setup = ResolvedSetup(
      output: speakers.ref, input: scarlett.ref, outChannels: [1, 2], inChannel: 0,
      autoInChannel: true)
    let backend = RouteBetweenOpensBackend(
      scenario: Scenario(jitterFrames: 0, pathGainDb: -80, loopChannel: 7, seed: 3),
      switching: .jackOnly)
    var thrown: SoundPingError?
    do {
      _ = try await ChannelProbe().run(
        backend: backend, setup: setup, channels: Array((scarlett.input?.channels ?? []).prefix(3)))
    } catch {
      thrown = error as? SoundPingError
    }
    #expect(thrown?.kind == .deviceChanged)
    #expect(thrown?.code == "outputRouteChanged")
    #expect(thrown?.context["property"] == "jackIsConnected")
    #expect(thrown?.context["from"] == "disconnected")
    #expect(thrown?.context["to"] == "connected")
    #expect(await backend.openCount == 2, "the probe ends at the first reopen")
    #expect(await backend.scheduledAfterSwitch == 0, "nothing is played after the switch")
  }

  // MARK: A buffer size that settles at the start is adopted (WR-05)

  private static func finishedResult(_ events: [RunEvent]) -> RunResult? {
    for case .finished(let result) in events { return result }
    return nil
  }

  @Test func aBufferSizeThatSettlesAtTheStartIsAdoptedAndRecorded() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    // open reports 128; once IO runs the devices are at 256. Nothing is played before that.
    let scenario = Scenario(jitterFrames: 0.5, bufferFrames: 128, settledBufferFrames: 256, seed: 5)
    let outcome = await Self.run(SimulatedBackend(scenario: scenario), hits: 20, store: store)

    #expect(outcome.error == nil)
    let result = try #require(Self.finishedResult(outcome.events))
    #expect(result.setup.outputBufferFrames == 256 && result.setup.inputBufferFrames == 256)
    let reported = try #require(result.reported)
    #expect(reported.output.bufferFrames == 256 && reported.input.bufferFrames == 256)
    let key = try #require(result.calibration?.key)
    #expect(key.outputBufferFrames == 256 && key.inputBufferFrames == 256)
    // The armed event says the same, so a reader of the stream sees the adopted size too.
    let armed = outcome.events.compactMap { event -> ArmedInfo? in
      if case .armed(let info) = event { return info }
      return nil
    }
    #expect(armed.first?.setup.inputBufferFrames == 256)
  }

  // MARK: Overload sizing follows the settled buffer (IN-18)

  @Test func theOverloadLookbackFollowsTheBufferTheDeviceSettledOn() {
    let baselines = BufferBaselines([7: 128])
    #expect(baselines.frames(7) == 128)
    baselines.beginSettling()
    baselines.adopt([7: 1024])
    #expect(baselines.frames(7) == 1024, "the 'over' handler reads the adopted size")
    // Two buffers, never less than 20 ms.
    #expect(DeviceListeners.overloadLookback(bufferFrames: 1024, rate: 48_000) == 2048)
    #expect(DeviceListeners.overloadLookback(bufferFrames: 128, rate: 48_000) == 960)
  }

  @Test func theFaultSettleGrowsWithTheSettledBufferButStaysInsideTheSpacingMargin() {
    for rate in [44_100.0, 48_000, 96_000] {
      for buffer in [16, 128, 256, 512, 1024, 2048, 4096] {
        let info = BackendInfo(
          sampleRate: rate, outputBufferFrames: buffer, inputBufferFrames: buffer / 2)
        let settle = HitListener.settle(for: info)
        let ms = Double(settle.frames) / rate * 1000
        #expect(ms >= HitListener.faultSettleMs - 0.05, "\(buffer) @ \(rate)")
        #expect(ms < HitScheduler.spacingMarginMs, "\(buffer) @ \(rate): \(ms) ms")
        let twoBuffers = 2.0 * Double(buffer) / rate * 1000
        #expect(settle.capped == (twoBuffers > HitListener.maxFaultSettleMs), "\(buffer) @ \(rate)")
        if !settle.capped { #expect(ms >= twoBuffers - 0.05, "\(buffer) @ \(rate)") }
      }
    }
    // 1024 frames at 48 kHz: one callback is 21 ms, so a fixed 20 ms settle was less than one.
    let typical = HitListener.settle(
      for: BackendInfo(sampleRate: 48_000, outputBufferFrames: 1024, inputBufferFrames: 1024))
    #expect(typical.frames == 2048 && !typical.capped)
  }

  @Test func aRunAtABufferTooLargeForTheFullSettleSaysSo() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let scenario = Scenario(
      jitterFrames: 0.5, bufferFrames: 128, settledBufferFrames: 2048, seed: 5)
    let outcome = await Self.run(SimulatedBackend(scenario: scenario), hits: 20, store: store)
    let result = try #require(Self.finishedResult(outcome.events))
    let warnings = result.preflight?.warnings ?? []
    #expect(warnings.contains { $0.contains("2048-frame buffer") }, "\(warnings)")

    let (small, cleanupSmall) = try Self.makeStore()
    defer { cleanupSmall() }
    let normal = await Self.run(
      SimulatedBackend(scenario: Scenario(jitterFrames: 0.5, seed: 5)), hits: 20, store: small)
    let normalWarnings = try #require(Self.finishedResult(normal.events)).preflight?.warnings ?? []
    #expect(!normalWarnings.contains { $0.contains("overload check") })
  }

  @Test func aChangeAfterTheSettledSizeIsAdoptedStillAborts() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let scenario = Scenario(
      jitterFrames: 0.5, bufferFrames: 128, settledBufferFrames: 256,
      faults: [Fault(kind: .bufferChange, atHit: 12)], seed: 5)
    let outcome = await Self.run(SimulatedBackend(scenario: scenario), hits: 20, store: store)

    #expect(outcome.error?.kind == .deviceChanged)
    #expect(outcome.error?.code == "bufferSizeChanged")
    #expect(!Self.hasFinished(outcome.events))
    #expect(Self.savedRunFiles(in: outcome.store).isEmpty)
  }

  @Test func theBufferBaselineIsReArmedAfterTheStartSettles() {
    let device = AudioDeviceID(42)
    let baselines = BufferBaselines([device: 128])
    #expect(baselines.changed(device, now: 128) == nil)
    #expect(baselines.changed(device, now: 256) == 128, "before the start, a change is news")

    baselines.beginSettling()
    #expect(baselines.changed(device, now: 256) == nil, "the settling is not news")
    #expect(baselines.changed(device, now: 512) == nil)

    baselines.adopt([device: 256])
    #expect(baselines.changed(device, now: 256) == nil, "the settled size is the baseline now")
    #expect(baselines.changed(device, now: 128) == 256, "a later change reports the new baseline")
  }
}
