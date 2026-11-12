import Foundation
import Testing

@testable import SoundPingKit

/// CAL-03: the host clock has to agree with the sample clock before anything aligns MIDI to audio.
/// Covers the tick arithmetic, the local timeline fit, the self-test verdict at its limits, and the
/// self-test inside a simulated same-device run.
@Suite struct ClockTests {
  private static let appleSilicon = HostClock(numer: 125, denom: 3)
  private static let intel = HostClock(numer: 1, denom: 1)

  // MARK: ticks and nanoseconds

  @Test(arguments: [appleSilicon, intel])
  func ticksRoundTripAboveTwoToTheFifty(clock: HostClock) {
    let bases: [UInt64] = [1 << 50, (1 << 50) + 12_345, 1 << 55, 1 << 58, UInt64(1) << 60 + 7]
    for ticks in bases {
      let nanos = clock.ticksToNanos(ticks)
      // Exact answer in 128-bit integers; Double must agree to its own precision.
      let exact = UInt128(ticks) * UInt128(clock.numer) / UInt128(clock.denom)
      #expect(abs(nanos - Double(exact)) <= Double(exact) * 1e-15, "ticks \(ticks)")
      let back = clock.nanosToTicks(nanos)
      #expect(abs(back - Double(ticks)) <= Swift.max(1, Double(ticks) * 1e-15), "ticks \(ticks)")
    }
  }

  @Test func theNaiveUInt64ProductWouldHaveOverflowedWhereDoubleDoesNot() {
    let ticks: UInt64 = 1 << 58  // ticks * 125 needs 65 bits
    #expect(ticks.multipliedReportingOverflow(by: 125).overflow)
    let nanos = Self.appleSilicon.ticksToNanos(ticks)
    #expect(nanos.isFinite)
    #expect(abs(nanos / (Double(ticks) * 125 / 3) - 1) < 1e-15)
  }

  @Test func oneSampleAt48kIsFiveHundredTicksAndTwentyThousandEightHundredThirtyThreeNanoseconds() {
    let clock = Self.appleSilicon
    #expect(abs(clock.ticks(forFrames: 1, sampleRate: 48_000) - 500) < 1e-9)
    #expect(abs(clock.frames(forTicks: 500, sampleRate: 48_000) - 1) < 1e-12)
    #expect(clock.nanosToWholeTicks(-5) == 0, "negative nanoseconds never wrap")
  }

  @Test func theSystemClockReportsAUsableTimebase() {
    let system = HostClock.system
    #expect(system.numer > 0 && system.denom > 0)
    #expect(system.timebase == HostTimebase(numer: system.numer, denom: system.denom))
  }

  // MARK: timeline fit

  /// Callbacks of a device whose sample clock runs `ppm` fast against the host. Host times are
  /// whole ticks, like the real thing, so the fit has to average the rounding away.
  private static func points(
    clock: HostClock, ppm: Double, callbacks: Int = 400, buffer: Int = 128,
    sampleOrigin: Double = 0, epoch: UInt64 = 1 << 50
  ) -> [TimelinePoint] {
    (0..<callbacks).map { index in
      let sample = sampleOrigin + Double(index * buffer)
      return TimelinePoint(
        sampleTime: sample,
        hostTime: trueHost(sample, clock: clock, ppm: ppm, origin: sampleOrigin, epoch: epoch)
          .roundedTicks,
        rateScalar: 1 / (1 + ppm * 1e-6), frames: buffer)
    }
  }

  private struct TrueHost {
    var exact: Double
    var roundedTicks: UInt64 { UInt64(exact.rounded()) }
  }

  private static func trueHost(
    _ sample: Double, clock: HostClock, ppm: Double, origin: Double, epoch: UInt64
  ) -> TrueHost {
    let seconds = (sample - origin) / (48_000 * (1 + ppm * 1e-6))
    return TrueHost(exact: Double(epoch) + clock.nanosToTicks(seconds * 1e9))
  }

  @Test(arguments: [appleSilicon, intel], [-50.0, 0.0, 50.0])
  func theFitErrsByLessThanAHundredthOfAFrame(clock: HostClock, ppm: Double) throws {
    let timeline = try #require(
      DeviceTimeline(points: Self.points(clock: clock, ppm: ppm), sampleRate: 48_000, clock: clock))
    var worst = 0.0
    // Between callbacks (a fractional offset), inside the log, away from its edges.
    for index in stride(from: 20, to: 380, by: 7) {
      let sample = Double(index * 128) + 37.3
      let truth = Self.trueHost(sample, clock: clock, ppm: ppm, origin: 0, epoch: 1 << 50).exact
      let error = clock.frames(
        forTicks: timeline.hostTicks(forSample: sample) - truth, sampleRate: 48_000)
      worst = Swift.max(worst, abs(error))
    }
    #expect(worst < 0.01, "worst error \(worst) frames at \(ppm) ppm on \(clock)")
  }

  @Test func theInverseMapsHostTimeBackToTheSample() throws {
    let clock = Self.appleSilicon
    let timeline = try #require(
      DeviceTimeline(points: Self.points(clock: clock, ppm: 40), sampleRate: 48_000, clock: clock))
    for sample in [5_000.25, 20_000.5, 33_333.75] {
      let host = timeline.hostTicks(forSample: sample)
      #expect(abs(timeline.sample(forHostTicks: host) - sample) < 1e-3)  // Double resolves 2^50 ticks to 1/8 tick, 0.0003 frame
    }
  }

  @Test func theFitIsLocalAndNotOneGlobalLine() throws {
    // The clock runs at +0 ppm for the first half and +400 ppm for the second. One global line
    // would be wrong in both halves; a local fit is right in each.
    let clock = Self.appleSilicon
    var points = Self.points(clock: clock, ppm: 0, callbacks: 300)
    let pivot = points[299]
    for index in 1...300 {
      let sample = pivot.sampleTime + Double(index * 128)
      let seconds = Double(index * 128) / (48_000 * (1 + 400e-6))
      let host = Double(pivot.hostTime) + clock.nanosToTicks(seconds * 1e9)
      points.append(
        TimelinePoint(
          sampleTime: sample, hostTime: UInt64(host.rounded()), rateScalar: 1 / (1 + 400e-6),
          frames: 128))
    }
    let timeline = try #require(DeviceTimeline(points: points, sampleRate: 48_000, clock: clock))

    let early = timeline.fittedSlope(nearSample: 40 * 128 + 10)
    let late = timeline.fittedSlope(nearSample: 560 * 128 + 10)
    let nominal = clock.ticks(forFrames: 1, sampleRate: 48_000)
    #expect(abs(early / nominal - 1) < 2e-6, "first half runs at the nominal rate")
    #expect(abs(late / nominal - 1 / (1 + 400e-6)) < 2e-6, "second half runs 400 ppm fast")
  }

  @Test func theFittedSlopeAgreesWithTheRateScalar() throws {
    let clock = Self.appleSilicon
    let timeline = try #require(
      DeviceTimeline(points: Self.points(clock: clock, ppm: 50), sampleRate: 48_000, clock: clock))
    let sample = 25_000.0
    let fitted = timeline.fittedSlope(nearSample: sample)
    let implied = timeline.rateScalarSlope(nearSample: sample)
    #expect(abs(fitted / implied - 1) < 2e-6)
  }

  @Test func aQueryOutsideTheLogExtrapolatesFromItsEdge() throws {
    let clock = Self.appleSilicon
    let timeline = try #require(
      DeviceTimeline(points: Self.points(clock: clock, ppm: 20), sampleRate: 48_000, clock: clock))
    let beyond = Double(399 * 128 + 20_000)
    let truth = Self.trueHost(beyond, clock: clock, ppm: 20, origin: 0, epoch: 1 << 50).exact
    let error = clock.frames(
      forTicks: timeline.hostTicks(forSample: beyond) - truth, sampleRate: 48_000)
    #expect(abs(error) < 0.05)
  }

  @Test func aSingleCallbackFallsBackToTheRateScalarSlope() throws {
    let clock = Self.appleSilicon
    let point = TimelinePoint(sampleTime: 1_000, hostTime: 1 << 40, rateScalar: 1.0001, frames: 128)
    let timeline = try #require(DeviceTimeline(points: [point], sampleRate: 48_000, clock: clock))
    let expected = Double(1 << 40) + 500 * 1.0001 * 100
    #expect(abs(timeline.hostTicks(forSample: 1_100) - expected) < 1e-6)
  }

  @Test func noCallbacksMeansNoTimeline() {
    #expect(DeviceTimeline(points: [], sampleRate: 48_000, clock: Self.appleSilicon) == nil)
  }

  @Test func unsortedCallbacksAreOrderedBeforeTheFit() throws {
    let clock = Self.appleSilicon
    let ordered = Self.points(clock: clock, ppm: 10, callbacks: 80)
    let timeline = try #require(
      DeviceTimeline(points: ordered.reversed(), sampleRate: 48_000, clock: clock))
    let sample = 5_000.5
    let truth = Self.trueHost(sample, clock: clock, ppm: 10, origin: 0, epoch: 1 << 50).exact
    #expect(
      abs(clock.frames(forTicks: timeline.hostTicks(forSample: sample) - truth, sampleRate: 48_000))
        < 0.01)
  }

  // MARK: verdict at the limits

  private static func deltas(median: Double, p95: Double) -> [Double] {
    // 20 values, all within [median, p95]: the median is `median`, the 95th percentile of |Δ| is `p95`.
    var values = [Double](repeating: median, count: 18)
    values.append(contentsOf: [p95, p95])
    return values
  }

  @Test func theLimitsThemselvesPass() {
    let result = ClockSelfTest.verdict(deltas: Self.deltas(median: 1.0, p95: 2.0))
    #expect(result.medianDeltaFrames == 1.0)
    #expect(result.p95AbsDeltaFrames == 2.0)
    #expect(result.pass, "exactly 1.0 and 2.0 frames is inside the limits")
  }

  @Test func justPastTheMedianLimitFails() {
    let result = ClockSelfTest.verdict(deltas: Self.deltas(median: 1.01, p95: 1.5))
    #expect(result.medianDeltaFrames == 1.01)
    #expect(!result.pass)
  }

  @Test func justPastTheP95LimitFails() {
    let result = ClockSelfTest.verdict(deltas: Self.deltas(median: 0.5, p95: 2.01))
    #expect(result.p95AbsDeltaFrames == 2.01)
    #expect(!result.pass)
  }

  @Test func aNegativeMedianIsJudgedByItsMagnitude() {
    #expect(ClockSelfTest.verdict(deltas: Self.deltas(median: -1.0, p95: 1.5)).pass)
    #expect(!ClockSelfTest.verdict(deltas: Self.deltas(median: -1.01, p95: 1.5)).pass)
  }

  @Test func theThresholdsAreRecordedWithTheResult() {
    let result = ClockSelfTest.verdict(deltas: [0.1, 0.2])
    #expect(result.thresholds == ClockSelfTestThresholds(medianFrames: 1, p95Frames: 2))
  }

  @Test func noDeltasProveNothingAndFail() {
    let result = ClockSelfTest.verdict(deltas: [])
    #expect(!result.pass)
    #expect(result.n == 0)
  }

  // MARK: inside a simulated same-device run

  private static func makeStore() throws -> (store: RunStore, cleanup: @Sendable () -> Void) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    let paths = try StorePaths.resolve(flag: folder.path, environment: [:])
    return (RunStore(paths: paths), { try? FileManager.default.removeItem(at: folder) })
  }

  private static func run(_ scenario: Scenario, hits: Int = 20, store: RunStore) async throws
    -> (result: RunResult, events: [RunEvent])
  {
    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: scenario.seed)
    parameters.hits = hits
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: .simulatedDuplex)
    var events: [RunEvent] = []
    var finished: RunResult?
    for try await event in RunCoordinator(
      backend: SimulatedBackend(scenario: scenario), store: store
    )
    .run(request) {
      events.append(event)
      if case .finished(let result) = event { finished = result }
    }
    return (try #require(finished), events)
  }

  @Test func aSimulatedSameDeviceRunPassesItsOwnSelfTest() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let (result, events) = try await Self.run(
      Scenario(latencyFrames: 412.37, jitterFrames: 0.5, seed: 11), store: store)

    let selfTest = try #require(result.selfTest)
    #expect(selfTest.pass)
    #expect(abs(selfTest.medianDeltaFrames) < 0.1)
    #expect(selfTest.n == 20)
    #expect(selfTest.halCrossCheckMedianFrames == nil, "the simulator has no HAL to ask")
    #expect(result.hostTimebase == HostTimebase(numer: 125, denom: 3))

    // The event comes after the last hit and right before finished.
    let selfTestEvents = events.compactMap { event -> ClockSelfTestResult? in
      if case .selfTest(let value) = event { return value }
      return nil
    }
    #expect(selfTestEvents == [selfTest])
    if case .selfTest = events[events.count - 2] {
    } else {
      Issue.record("selfTest is not right before finished")
    }
  }

  @Test func theSelfTestSurvivesDriftOfFiftyPPMInEitherDirection() async throws {
    for ppm in [-50.0, 50.0] {
      let (store, cleanup) = try Self.makeStore()
      defer { cleanup() }
      let (result, _) = try await Self.run(
        Scenario(jitterFrames: 0, driftPPM: ppm, seed: 3), hits: 12, store: store)
      let selfTest = try #require(result.selfTest)
      #expect(selfTest.pass, "drift \(ppm) ppm")
      #expect(abs(selfTest.medianDeltaFrames) < 0.1, "drift \(ppm) ppm")
    }
  }

  @Test func aThreeFrameInputStampBiasFailsTheSelfTest() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let (result, _) = try await Self.run(
      Scenario(jitterFrames: 0.5, stampBiasFrames: 3, seed: 5), hits: 20, store: store)
    let selfTest = try #require(result.selfTest)
    #expect(!selfTest.pass)
    #expect(abs(selfTest.medianDeltaFrames - 3) < 0.1)
    // The measurement itself is untouched: the bias is in the stamps, not the audio.
    #expect(abs(try #require(result.measured.path?.median).frames - 412.37) < 0.2)
  }

  @Test func aBiasInsideTheLimitsStillPasses() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let (result, _) = try await Self.run(
      Scenario(jitterFrames: 0, stampBiasFrames: 0.9, seed: 5), hits: 20, store: store)
    #expect(try #require(result.selfTest).pass)
  }

  @Test func theHALCrossCheckReportsItsMedianGap() throws {
    // Hits at output frame 0 with a 400 frame path on a clean 48 kHz / 125:3 clock.
    let clock = Self.appleSilicon
    let points = Self.points(clock: clock, ppm: 0)
    let log = StampLog(input: points, output: points)
    let hits = (0..<5).map {
      HitRecord(
        index: $0, phase: .measure, outputFrame: Int64(5_000 + $0 * 3_000), latencyFrames: 400)
    }
    // The HAL says every input sample was captured exactly 2 frames (1000 ticks) later than we do.
    let timeline = DeviceTimeline(points: points, sampleRate: 48_000, clock: clock)!
    var hal: [Int: UInt64] = [:]
    for hit in hits {
      let ours = timeline.hostTicks(forSample: Double(hit.outputFrame) + 400)
      hal[hit.index] = UInt64((ours + 1_000).rounded())
    }
    let result = ClockSelfTest.evaluate(
      hits: hits, stampLog: log, sampleRate: 48_000, hostClock: clock, halInputHostTimes: hal)
    #expect(result.pass)
    #expect(abs(try #require(result.halCrossCheckMedianFrames) - 2) < 0.01)
  }

  @Test func rejectedAndWarmupHitsNeverEnterTheSelfTest() {
    let clock = Self.appleSilicon
    let points = Self.points(clock: clock, ppm: 0)
    let log = StampLog(input: points, output: points)
    let hits = [
      HitRecord(index: 0, phase: .warmup, outputFrame: 5_000, latencyFrames: 999),
      HitRecord(index: 1, phase: .measure, outputFrame: 8_000, latencyFrames: 400),
      HitRecord(index: 2, phase: .measure, outputFrame: 11_000, rejection: .noPeak),
    ]
    let result = ClockSelfTest.evaluate(
      hits: hits, stampLog: log, sampleRate: 48_000, hostClock: clock)
    #expect(result.n == 1)
    #expect(result.pass)
  }

  // MARK: clock-selftest.json

  private static func entry(
    uid: String = "dev", rate: Double = 48_000, buffer: Int = 128, pass: Bool = true,
    runId: String = "run-1"
  ) -> ClockSelfTestEntry {
    ClockSelfTestEntry(
      key: ClockSelfTestKey(deviceUID: uid, sampleRate: rate, bufferFrames: buffer),
      result: ClockSelfTestResult(
        pass: pass, medianDeltaFrames: 0.1, p95AbsDeltaFrames: 0.2, n: 10),
      runId: runId, measuredAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private static func tempFile() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("clock-selftest.json")
  }

  @Test func theLatestResultPerKeyWinsAndOtherKeysStay() throws {
    let url = Self.tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try ClockSelfTestStore.record(Self.entry(runId: "first"), in: url)
    try ClockSelfTestStore.record(Self.entry(rate: 44_100, runId: "other-rate"), in: url)
    try ClockSelfTestStore.record(Self.entry(pass: false, runId: "second"), in: url)

    let file = try ClockSelfTestStore.load(from: url)
    #expect(file.schemaVersion == 1)
    #expect(file.entries.count == 2)
    #expect(file.entries.first?.runId == "second")
    #expect(file.entries.first?.pass == false)
    #expect(file.entries.last?.runId == "other-rate")
  }

  @Test func aMissingFileIsEmptyAndABadOneIsAUsageErrorNamingIt() throws {
    let url = Self.tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(try ClockSelfTestStore.load(from: url).entries.isEmpty)

    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    for body in ["not json", #"{"schemaVersion": 2, "entries": []}"#] {
      try Data(body.utf8).write(to: url)
      do {
        _ = try ClockSelfTestStore.load(from: url)
        Issue.record("expected an error for \(body)")
      } catch let error as SoundPingError {
        #expect(error.kind == .usage)
        #expect(error.code == "clockSelfTestUnreadable")
        #expect(error.detail.contains(url.path))
      }
    }
  }

  @Test func aRunWritesTheStatusKeyedByDeviceRateAndBuffer() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let (result, _) = try await Self.run(Scenario(jitterFrames: 0, seed: 9), hits: 10, store: store)

    let key = ClockSelfTestKey(
      deviceUID: "soundping-sim-duplex", sampleRate: 48_000, bufferFrames: 128)
    let entry = try #require(try ClockSelfTestStore.entry(for: key, in: store.paths.clockSelfTest))
    #expect(entry.runId == result.runId)
    #expect(entry.pass)
  }

  @Test func anUnreadableStatusFileFailsTheRunBeforeAnyAudio() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    try Data("{".utf8).write(to: store.paths.clockSelfTest)
    do {
      _ = try await Self.run(Scenario(seed: 1), hits: 5, store: store)
      Issue.record("expected the run to fail")
    } catch let error as SoundPingError {
      #expect(error.code == "clockSelfTestUnreadable")
    }
    let runs = try FileManager.default.contentsOfDirectory(atPath: store.paths.runs.path)
    #expect(runs.isEmpty, "nothing was run, so no run folder exists")
  }

  @Test func theSelfTestEventEncodesFlatWithItsTypeKey() throws {
    let result = ClockSelfTestResult(
      pass: true, medianDeltaFrames: 0.1, p95AbsDeltaFrames: 0.2, n: 5)
    let data = try RunJSON.lineEncoder().encode(RunEvent.selfTest(result))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["type"] as? String == "selfTest")
    #expect(object["pass"] as? Bool == true)
    #expect(object["n"] as? Int == 5)
    #expect(try RunJSON.decoder().decode(RunEvent.self, from: data) == .selfTest(result))
  }

  @Test func theRunIdOnTheArmedEventIsTheFinalOneEvenWhenTwoRunsShareASecond() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    var armedIds: [String] = []
    var finalIds: [String] = []
    for _ in 0..<2 {
      let (result, events) = try await Self.run(
        Scenario(jitterFrames: 0, seed: 2), hits: 5, store: store)
      if case .armed(let info) = events.first { armedIds.append(info.runId) }
      finalIds.append(result.runId)
    }
    #expect(armedIds == finalIds)
    #expect(Set(finalIds).count == 2)
  }
}
