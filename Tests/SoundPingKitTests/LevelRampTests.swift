import Foundation
import Testing

@testable import SoundPingKit

/// Forwards to the simulator but makes the first `glitches` listening windows report lost frames
/// (a jump in the callback sample times), as after a real overload. Only the probes are played in
/// those windows, so the ramp is what meets them.
private actor GlitchedWindowsBackend: AudioBackend {
  private let inner: SimulatedBackend
  private var remaining: Int
  nonisolated let events: AsyncStream<DeviceEvent>

  init(scenario: Scenario, glitches: Int) {
    inner = SimulatedBackend(scenario: scenario)
    remaining = glitches
    events = inner.events
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
    var stamps = await inner.stamps(covering: range)
    if remaining > 0, stamps.count >= 2 {
      remaining -= 1
      stamps[1].inputSampleTime += 4_096
    }
    return stamps
  }
  func stampLog() async -> StampLog { await inner.stampLog() }
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval] {
    await inner.faults(overlappingInput: input, output: output)
  }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }
  func stop() async { await inner.stop() }
}

/// The gentle auto-ramp and the checks around it (ENG-03, D-12, D-14): start at -48 dBFS, step up
/// by 6 dB, never above the listener's ceiling, lock the level, and name the cause when the room
/// is silent, clipping, muted or deaf.
@Suite struct LevelRampTests {
  // MARK: listener classification

  private static func setup(
    inChannelName: String? = nil, output: DeviceInfo, input: DeviceInfo
  ) -> ResolvedSetup {
    ResolvedSetup(
      output: output.ref, input: input.ref, outChannels: [1, 2], inChannel: 1,
      inChannelName: inChannelName)
  }

  private static let macSpeakers = SimulatedCatalog.macSpeakers
  private static let macMicrophone = SimulatedCatalog.macMicrophone
  private static let scarlett = SimulatedCatalog.scarlett
  private static let duplex = SimulatedCatalog.duplex

  private static func headphones() -> DeviceInfo {
    var device = SimulatedCatalog.macSpeakers
    device.output?.dataSource = "hdpn"
    return device
  }

  @Test func aLoopChannelOrAVirtualInputIsALoopback() {
    let byChannel = Self.setup(inChannelName: "Loop 1", output: Self.scarlett, input: Self.scarlett)
    #expect(
      LevelRamp.classify(setup: byChannel, output: Self.scarlett, input: Self.scarlett)
        == .loopback)

    let byTransport = Self.setup(output: Self.duplex, input: Self.duplex)
    #expect(
      LevelRamp.classify(setup: byTransport, output: Self.duplex, input: Self.duplex) == .loopback)
  }

  // MARK: ears first (CR-03)

  @Test func aVirtualInputNeverLiftsTheCeilingOfAnOutputThatReachesEars() {
    let virtualInput = Self.duplex
    #expect(virtualInput.transport == "virtual")

    let headphones = Self.headphones()
    let onHeadphones = Self.setup(output: headphones, input: virtualInput)
    #expect(
      LevelRamp.classify(setup: onHeadphones, output: headphones, input: virtualInput)
        == .headphones)

    let earbuds = Self.bluetooth(from: Self.macSpeakers)
    let onBluetooth = Self.setup(output: earbuds, input: virtualInput)
    #expect(
      LevelRamp.classify(setup: onBluetooth, output: earbuds, input: virtualInput) == .headphones)

    let onSpeakers = Self.setup(output: Self.macSpeakers, input: virtualInput)
    #expect(
      LevelRamp.classify(setup: onSpeakers, output: Self.macSpeakers, input: virtualInput)
        == .speaker, "built-in speakers keep -12 dBFS, not the -6 dBFS loopback ceiling")
  }

  @Test func aLoopChannelOnAnotherDeviceNeverLiftsTheCeilingEither() {
    // "Loop 1" on the interface returns what the interface played, not what the laptop played.
    let headphones = Self.headphones()
    let onHeadphones = Self.setup(inChannelName: "Loop 1", output: headphones, input: Self.scarlett)
    #expect(
      LevelRamp.classify(setup: onHeadphones, output: headphones, input: Self.scarlett)
        == .headphones)

    let earbuds = Self.bluetooth(from: Self.macSpeakers)
    let onBluetooth = Self.setup(inChannelName: "Loop 1", output: earbuds, input: Self.scarlett)
    #expect(
      LevelRamp.classify(setup: onBluetooth, output: earbuds, input: Self.scarlett) == .headphones)

    let onSpeakers = Self.setup(
      inChannelName: "Loop 1", output: Self.macSpeakers, input: Self.scarlett)
    #expect(
      LevelRamp.classify(setup: onSpeakers, output: Self.macSpeakers, input: Self.scarlett)
        == .speaker)

    // An interface output next to a virtual input on another device is no loop either.
    let usb = Self.setup(output: Self.scarlett, input: Self.duplex)
    #expect(LevelRamp.classify(setup: usb, output: Self.scarlett, input: Self.duplex) == .unknown)
  }

  @Test func aVirtualOutputHeardByAMicrophoneIsNoLoop() {
    // CR-04: a virtual device that monitors to headphones or speakers reaches the microphone
    // acoustically, so it keeps the -18 dBFS unknown ceiling, not the -6 dBFS loopback one.
    let setup = Self.setup(output: Self.duplex, input: Self.macMicrophone)
    #expect(
      LevelRamp.classify(setup: setup, output: Self.duplex, input: Self.macMicrophone)
        == .unknown)
    let usbMic = Self.scarlett
    let onUSB = Self.setup(output: Self.duplex, input: usbMic)
    #expect(LevelRamp.classify(setup: onUSB, output: Self.duplex, input: usbMic) == .unknown)
  }

  @Test func aVirtualOutputIntoAVirtualInputIsALoopback() {
    // Two virtual devices on two UIDs (for example a virtual output routed into another one).
    var other = Self.duplex
    other.uid = "soundping-sim-other-virtual"
    let setup = Self.setup(output: Self.duplex, input: other)
    #expect(setup.output.uid != setup.input.uid)
    #expect(LevelRamp.classify(setup: setup, output: Self.duplex, input: other) == .loopback)
    // The recorded transports are enough when the device list is unavailable.
    let recorded = ResolvedSetup(
      output: Self.duplex.ref, input: Self.duplex.ref, outChannels: [1, 2], inChannel: 1)
    #expect(LevelRamp.classify(setup: recorded, output: nil, input: nil) == .loopback)
  }

  @Test func theBuiltInOutputIsHeadphonesOnItsHeadphoneSourceAndSpeakersOtherwise() {
    let headphones = Self.headphones()
    let onHeadphones = Self.setup(output: headphones, input: Self.macMicrophone)
    #expect(
      LevelRamp.classify(setup: onHeadphones, output: headphones, input: Self.macMicrophone)
        == .headphones)

    let onSpeakers = Self.setup(output: Self.macSpeakers, input: Self.macMicrophone)
    #expect(
      LevelRamp.classify(setup: onSpeakers, output: Self.macSpeakers, input: Self.macMicrophone)
        == .speaker)
  }

  @Test func aBuiltInOutputIsASpeakerOnlyWhenItClearlyReportsItsSpeakers() {
    // Fail safe (WR-12): a missing or unreadable data source picks the quieter ceiling.
    var unreadable = Self.macSpeakers
    unreadable.output?.dataSource = nil
    let setup = Self.setup(output: unreadable, input: Self.macMicrophone)
    #expect(LevelRamp.outputIsHeadphones(setup: setup, output: unreadable))
    #expect(
      LevelRamp.classify(setup: setup, output: unreadable, input: Self.macMicrophone)
        == .headphones)

    var other = Self.macSpeakers
    other.output?.dataSource = "hdmi"
    #expect(LevelRamp.outputIsHeadphones(setup: setup, output: other))

    // No device info at all (catalog miss): the transport the setup recorded is all there is.
    let recorded = ResolvedSetup(
      output: Self.macSpeakers.ref, input: Self.macMicrophone.ref, outChannels: [1, 2],
      inChannel: 1)
    #expect(LevelRamp.classify(setup: recorded, output: nil, input: nil) == .headphones)

    // The proven speakers keep the speaker ceiling.
    let speakers = Self.macSpeakers
    #expect(speakers.output?.dataSource == "ispk")
    #expect(!LevelRamp.outputIsHeadphones(setup: setup, output: speakers))
    #expect(
      LevelRamp.classify(setup: setup, output: speakers, input: Self.macMicrophone) == .speaker)
  }

  @Test func anythingElseIsUnknownBecauseAnInterfaceHeadphoneJackLooksLikeALineOut() {
    let setup = Self.setup(inChannelName: "Input 3", output: Self.scarlett, input: Self.scarlett)
    #expect(
      LevelRamp.classify(setup: setup, output: Self.scarlett, input: Self.scarlett) == .unknown)
  }

  private static func bluetooth(from base: DeviceInfo) -> DeviceInfo {
    var device = base
    device.transport = "bluetooth"
    return device
  }

  @Test func aBluetoothOutputIsHeadphonesWhateverItsDataSource() {
    let earbuds = Self.bluetooth(from: Self.macSpeakers)
    let setup = Self.setup(output: earbuds, input: Self.macMicrophone)
    #expect(
      LevelRamp.classify(setup: setup, output: earbuds, input: Self.macMicrophone) == .headphones)
    #expect(LevelRamp.outputIsHeadphones(setup: setup, output: earbuds))
    #expect(LevelRamp.ceilingDbfs(for: .headphones) == -30)

    // The device list may be unavailable; the transport the setup recorded is enough.
    var ref = earbuds.ref
    ref.transport = "bluetooth"
    let recorded = ResolvedSetup(
      output: ref, input: Self.macMicrophone.ref, outChannels: [1, 2], inChannel: 1)
    #expect(LevelRamp.classify(setup: recorded, output: nil, input: nil) == .headphones)
  }

  @Test func aUSBOutputStaysUnknownBecauseThereIsNoReliableWayToTellAHeadsetFromAnInterface() {
    let usb = Self.scarlett
    #expect(usb.transport == "usb")
    let setup = Self.setup(output: usb, input: Self.macMicrophone)
    #expect(LevelRamp.classify(setup: setup, output: usb, input: Self.macMicrophone) == .unknown)
    #expect(!LevelRamp.outputIsHeadphones(setup: setup, output: usb))
  }

  @Test func theChannelProbeAlsoKeepsTheHeadphoneCeilingOnABluetoothOutput() throws {
    let earbuds = Self.bluetooth(from: Self.macSpeakers)
    let setup = Self.setup(output: earbuds, input: Self.macMicrophone)
    let detected = try LevelRamp.probeLoudness(
      setup: setup, output: earbuds, options: PreflightOptions())
    #expect(detected.kind == .headphones)
    #expect(detected.ceilingDbfs == -30)
    // --listener names the listener and the band, but never lifts the headphone ceiling (WR-13).
    let named = try LevelRamp.probeLoudness(
      setup: setup, output: earbuds, options: PreflightOptions(listener: .speaker))
    #expect(named.kind == .speaker)
    #expect(named.ceilingDbfs == -30)
  }

  @Test func eachListenerHasItsOwnCeiling() {
    #expect(LevelRamp.ceilingDbfs(for: .loopback) == -6)
    #expect(LevelRamp.ceilingDbfs(for: .speaker) == -12)
    #expect(LevelRamp.ceilingDbfs(for: .headphones) == -30)
    #expect(LevelRamp.ceilingDbfs(for: .unknown) == -18)
  }

  @Test func maxLevelReplacesTheCeilingAndMustNotBeAboveFullScale() throws {
    let none = PreflightOptions()
    #expect(try LevelRamp.loudness(detected: .headphones, options: none).ceilingDbfs == -30)
    let louder = PreflightOptions(maxLevelDbfs: -10)
    #expect(try LevelRamp.loudness(detected: .headphones, options: louder).ceilingDbfs == -10)
    #expect(try LevelRamp.loudness(detected: .headphones, options: louder).source == .maxLevel)
    let quieter = PreflightOptions(maxLevelDbfs: -40)
    #expect(try LevelRamp.loudness(detected: .loopback, options: quieter).ceilingDbfs == -40)
    #expect(
      try LevelRamp.loudness(detected: .loopback, options: PreflightOptions(maxLevelDbfs: 0))
        .ceilingDbfs == 0)
    for bad in [3, Double.nan, .infinity, -.infinity] {
      #expect(throws: SoundPingError.self) {
        _ = try LevelRamp.loudness(detected: .loopback, options: PreflightOptions(maxLevelDbfs: bad))
      }
    }
  }

  @Test func theListenerFlagCanLowerTheCeilingButNeverRaiseIt() throws {
    let raise = try LevelRamp.loudness(
      detected: .headphones, options: PreflightOptions(listener: .loopback))
    #expect(raise.kind == .loopback, "the band and the reported listener follow the flag")
    #expect(raise.ceilingDbfs == -30)
    #expect(raise.source == .devices)
    #expect(raise.listenerNotRaisedWarning?.contains("--max-level") == true)

    let lower = try LevelRamp.loudness(
      detected: .loopback, options: PreflightOptions(listener: .headphones))
    #expect(lower.ceilingDbfs == -30)
    #expect(lower.source == .listenerFlag)
    #expect(lower.listenerNotRaisedWarning == nil)

    let unknownToLoop = try LevelRamp.loudness(
      detected: .unknown, options: PreflightOptions(listener: .loopback))
    #expect(unknownToLoop.ceilingDbfs == -18, "a cable loop on an interface needs --max-level")
  }

  @Test func theChirpBandFollowsTheListener() {
    #expect(LevelRamp.templateId(for: .loopback) == "chirp-loopback")
    for kind in [ListenerKind.speaker, .headphones, .unknown] {
      #expect(LevelRamp.templateId(for: kind) == "chirp-speaker")
    }
  }

  @Test func peakLevelIsReadInDbfsAndSilenceStaysFinite() {
    #expect(LevelRamp.dbfs(ofAbsolutePeak: 1) == 0)
    #expect(abs(LevelRamp.dbfs(ofAbsolutePeak: 0.5) - (-6.0206)) < 0.001)
    #expect(LevelRamp.dbfs(ofAbsolutePeak: 0).isFinite, "JSON cannot carry -infinity")
  }

  // MARK: the ramp itself

  /// Feeds a ramp the answers of a path: what the probe at each level heard.
  private static func drive(
    _ ramp: inout LevelRamp, heard: (Double) -> (confidence: Double, peak: Double)
  ) -> (levels: [Double], end: LevelRamp.Step) {
    var levels: [Double] = []
    var next = ramp.firstLevel
    while true {
      levels.append(next)
      let answer = heard(next)
      let step = ramp.record(level: next, confidence: answer.confidence, peakDbfs: answer.peak)
      if case .probe(let level) = step {
        next = level
      } else {
        return (levels, step)
      }
      if levels.count > 40 { return (levels, step) }
    }
  }

  @Test func theFirstProbeIsQuietAndEachFailedProbeStepsUpSixDecibels() {
    var ramp = LevelRamp(ceilingDbfs: -6)
    #expect(ramp.firstLevel == -48)

    // Heard clearly from -36 up; each step is +6 dB.
    let run = Self.drive(&ramp) { level in
      level >= -36 ? (0.95, level + 20) : (0.2, -80)
    }
    #expect(run.levels == [-48, -42, -36])
    #expect(run.end == .lock(-36, warning: nil))
  }

  @Test func theRampNeverGoesAboveTheCeilingAndThenNamesNothingHeard() {
    var ramp = LevelRamp(ceilingDbfs: -6)
    let run = Self.drive(&ramp) { _ in (0.1, -80) }
    #expect(run.levels == [-48, -42, -36, -30, -24, -18, -12, -6], "eight probes, none above -6")
    #expect(run.end == .fail(.nothingHeard))
  }

  @Test func aCeilingBetweenTwoStepsIsProbedAtExactlyTheCeiling() {
    var ramp = LevelRamp(ceilingDbfs: -20)
    let run = Self.drive(&ramp) { _ in (0.1, -80) }
    #expect(run.levels == [-48, -42, -36, -30, -24, -20])
    #expect(run.end == .fail(.nothingHeard))
  }

  @Test func theHeadphoneCeilingStopsTheRampAtMinusThirty() {
    var ramp = LevelRamp(ceilingDbfs: LevelRamp.ceilingDbfs(for: .headphones))
    let run = Self.drive(&ramp) { _ in (0.1, -80) }
    #expect(run.levels.max() == -30)
    #expect(run.end == .fail(.nothingHeard))
  }

  @Test func theFirstProbeIsNeverAboveTheCeilingEither() {
    let ramp = LevelRamp(ceilingDbfs: -60)
    #expect(ramp.firstLevel == -60)
  }

  @Test func aNonFiniteFixedLevelCannotDefeatTheCeiling() {
    for level in [Double.nan, .infinity, -.infinity] {
      let ramp = LevelRamp(ceilingDbfs: -30, fixedLevelDbfs: level)
      #expect(ramp.firstLevel.isFinite)
      #expect(ramp.firstLevel <= -30)
    }
  }

  @Test func aPeakOfExactlyMinusSixSatisfiesTheLockTarget() {
    var ramp = LevelRamp(ceilingDbfs: -6)
    #expect(ramp.record(level: -48, confidence: 0.9, peakDbfs: -6.0) == .lock(-48, warning: nil))
  }

  @Test func aHotButNotClippingPeakStillLocksWithAWarning() {
    var ramp = LevelRamp(ceilingDbfs: -6)
    let step = ramp.record(level: -48, confidence: 0.95, peakDbfs: -5.9)
    guard case .lock(let level, let warning) = step else {
      Issue.record("expected a lock, got \(step)")
      return
    }
    #expect(level == -48)
    #expect(warning == "input is hot")

    var edge = LevelRamp(ceilingDbfs: -6)
    #expect(
      edge.record(level: -48, confidence: 0.95, peakDbfs: -1.0001)
        == .lock(-48, warning: "input is hot"))
  }

  @Test func aPeakOfExactlyMinusOneCountsAsClippingAndStepsDownTwelve() {
    var ramp = LevelRamp(ceilingDbfs: -6)
    #expect(ramp.record(level: -36, confidence: 0.99, peakDbfs: -1.0) == .probe(-48))
    #expect(ramp.record(level: -48, confidence: 0.99, peakDbfs: -1.0) == .probe(-60))
    #expect(ramp.record(level: -60, confidence: 0.99, peakDbfs: -1.0) == .fail(.clipping))
  }

  @Test func clippingAtTheFirstProbeGetsTheFloorProbeThenFails() {
    var ramp = LevelRamp(ceilingDbfs: -6)
    #expect(ramp.record(level: -48, confidence: 1, peakDbfs: 0) == .probe(-60))
    #expect(ramp.record(level: -60, confidence: 1, peakDbfs: 0) == .fail(.clipping))
  }

  @Test func aLowerProbeAfterClippingLocksWhenItIsHeardClearly() {
    var ramp = LevelRamp(ceilingDbfs: -6)
    #expect(ramp.record(level: -48, confidence: 1, peakDbfs: 0) == .probe(-60))
    #expect(ramp.record(level: -60, confidence: 0.97, peakDbfs: -12) == .lock(-60, warning: nil))
  }

  @Test func aFixedLevelIsConfirmedByOneProbeWithTheSameChecks() {
    var heard = LevelRamp(ceilingDbfs: -6, fixedLevelDbfs: -20)
    #expect(heard.firstLevel == -20)
    #expect(heard.record(level: -20, confidence: 0.97, peakDbfs: -14) == .lock(-20, warning: nil))

    var clipped = LevelRamp(ceilingDbfs: -6, fixedLevelDbfs: -20)
    #expect(clipped.record(level: -20, confidence: 1, peakDbfs: -0.5) == .fail(.clipping))

    var deaf = LevelRamp(ceilingDbfs: -6, fixedLevelDbfs: -20)
    #expect(deaf.record(level: -20, confidence: 0.2, peakDbfs: -70) == .fail(.nothingHeard))

    var faint = LevelRamp(ceilingDbfs: -6, fixedLevelDbfs: -20)
    guard case .lock(-20, let warning?) = faint.record(level: -20, confidence: 0.7, peakDbfs: -40)
    else {
      Issue.record("a faint but present chirp at a chosen level still locks, with a warning")
      return
    }
    #expect(warning.contains("0.7"))
  }

  @Test func aFixedLevelAboveTheCeilingIsCappedToIt() {
    let ramp = LevelRamp(ceilingDbfs: -30, fixedLevelDbfs: -6)
    #expect(ramp.firstLevel == -30)
  }

  // MARK: through the engine

  private struct Collected {
    var events: [RunEvent]
    var error: SoundPingError?

    var result: RunResult? {
      if case .finished(let result) = events.last { return result }
      return nil
    }

    var probes: [ProbeRecord] {
      events.compactMap {
        if case .probe(let record) = $0 { return record }
        return nil
      }
    }

    var locks: [LevelLock] {
      events.compactMap {
        if case .levelLocked(let lock) = $0 { return lock }
        return nil
      }
    }

    /// One short tag per event, for order assertions.
    var tags: [String] {
      events.map {
        switch $0 {
        case .probe: return "probe"
        case .levelLocked: return "levelLocked"
        case .armed: return "armed"
        case .hit: return "hit"
        case .rejected: return "rejected"
        case .aborted: return "aborted"
        case .selfTest: return "selfTest"
        case .finished: return "finished"
        }
      }
    }
  }

  private static func run(
    _ scenario: Scenario, hits: Int = 20, level: Double? = nil,
    preflight: PreflightOptions = PreflightOptions(), setup: ResolvedSetup = .simulatedDuplex
  ) async throws -> Collected {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))

    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: scenario.seed)
    parameters.hits = hits
    parameters.levelDbfs = level
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: setup, preflight: preflight)
    let coordinator = RunCoordinator(backend: SimulatedBackend(scenario: scenario), store: store)

    var events: [RunEvent] = []
    var thrown: SoundPingError?
    do {
      for try await event in coordinator.run(request) { events.append(event) }
    } catch {
      thrown = error as? SoundPingError
    }
    return Collected(events: events, error: thrown)
  }

  @Test func aNormalRunRampsFromMinusFortyEightLocksAndThenPlaysWarmupsAndHits() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0.5, seed: 5))
    let result = try #require(collected.result)
    let preflight = try #require(result.preflight)

    #expect(preflight.probes.first?.levelDbfs == -48)
    #expect(preflight.lockedLevelDbfs <= preflight.ceilingDbfs)
    #expect(preflight.listenerKind == .loopback, "the simulated duplex is a virtual device")
    #expect(preflight.ceilingDbfs == -6)
    #expect(preflight.permission == .authorized)
    #expect(preflight.probes == collected.probes, "the report lists the probes the stream showed")

    #expect(result.hits.allSatisfy { $0.phase != .probe }, "probes never appear in hits[]")
    #expect(result.hits.filter { $0.phase == .warmup }.count == 5)
    #expect(result.hits.filter { $0.phase == .measure }.count == 20)
    #expect(try #require(result.measured.path).valid == 20)

    let lock = try #require(collected.locks.first)
    #expect(collected.locks.count == 1)
    #expect(lock.levelDbfs == preflight.lockedLevelDbfs)
    #expect(lock.ceilingDbfs == preflight.ceilingDbfs)
    #expect(lock.templateId == preflight.templateId)
  }

  @Test func theStreamIsProbesThenOneLevelLockedThenArmedThenHitsThenFinished() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0.5, seed: 5))
    let tags = collected.tags

    let lockedAt = try #require(tags.firstIndex(of: "levelLocked"))
    let armedAt = try #require(tags.firstIndex(of: "armed"))
    #expect(lockedAt + 1 == armedAt, "armed follows the lock directly")
    #expect(lockedAt >= 1, "at least one probe comes first")
    #expect(tags[..<lockedAt].allSatisfy { $0 == "probe" })
    #expect(tags.last == "finished")
    #expect(tags.suffix(from: armedAt + 1).filter { $0 == "hit" || $0 == "rejected" }.count == 25)
    #expect(!tags.suffix(from: armedAt).contains("probe"))
    #expect(collected.probes.map(\.index) == (1...collected.probes.count).map { -$0 })
  }

  @Test func probesNeverShareAnIndexWithACountedHitSoSimulationKnobsMissThem() async throws {
    // Every warm-up and measured hit never arrives, and one more is xrun'd and faulted: the ramp
    // still locks, because those knobs are keyed by hit index and the probes have negative ones.
    let scenario = Scenario(
      jitterFrames: 0, missedHits: Array(0...24), xrunHits: [3],
      faults: [Fault(kind: .overload, atHit: 3)], seed: 7)
    let collected = try await Self.run(scenario)

    #expect(collected.error == nil)
    let result = try #require(collected.result)
    let preflight = try #require(result.preflight)
    #expect(preflight.lockedLevelDbfs <= preflight.ceilingDbfs)
    #expect(try #require(result.measured.path).valid == 0)
    #expect(collected.locks.count == 1)
  }

  @Test func aHotPathLocksAtTheFirstProbeSoNoHitClips() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, pathGainDb: 30, seed: 9))
    let result = try #require(collected.result)
    let preflight = try #require(result.preflight)

    #expect(preflight.lockedLevelDbfs == -48)
    #expect(preflight.probes.count == 1)
    #expect((preflight.probes.first?.peakDbfs ?? 0) < -6)
    #expect(result.rejectedCounts[RejectionReason.clipped.rawValue] == 0)
    #expect(try #require(result.measured.path).valid == 20)
  }

  @Test func allZeroInputWithPermissionIsDigitalSilence() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, inputZeros: true, seed: 3))
    let error = try #require(collected.error)
    #expect(error.kind == .preflight)
    #expect(error.code == "inputDigitalSilence")
    #expect(collected.events.last == .aborted(error))
    #expect(!collected.tags.contains("armed"))
    #expect(collected.probes.count <= 1, "silence is named at the first probe, not after the ramp")
  }

  @Test func zerosUnderADeniedPermissionAreThePermissionNotSilence() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, permission: .denied, seed: 3))
    #expect(collected.error?.code == "micPermissionDenied")
    #expect(collected.probes.isEmpty)
  }

  @Test func aPathHotterThanEvenTheFloorProbeCanTakeIsClipping() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, pathGainDb: 66, seed: 3))
    let error = try #require(collected.error)
    #expect(error.code == "inputClipping")
    #expect(error.kind == .preflight)
    #expect(collected.probes.map(\.levelDbfs) == [-48, -60])
    #expect(!collected.tags.contains("armed"))
  }

  @Test func aDeafPathFailsAsNothingHeardAtTheCeilingAfterEveryStep() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, pathGainDb: -80, seed: 3))
    let error = try #require(collected.error)
    #expect(error.code == "nothingHeardAtCeiling")
    #expect(error.kind == .preflight)
    #expect(error.context["ceilingDbfs"] == "-6.0")
    #expect(
      error.context["fix"]?.isEmpty == false, "the hint names cable, permission, volume, gain")
    #expect(collected.probes.map(\.levelDbfs) == [-48, -42, -36, -30, -24, -18, -12, -6])
    #expect(!collected.tags.contains("armed"))
  }

  private static func runGlitched(glitches: Int, scenario: Scenario) async throws -> Collected {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))
    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: scenario.seed)
    parameters.hits = 5
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: .simulatedDuplex)
    let backend = GlitchedWindowsBackend(scenario: scenario, glitches: glitches)
    var events: [RunEvent] = []
    var thrown: SoundPingError?
    do {
      for try await event in RunCoordinator(backend: backend, store: store).run(request) {
        events.append(event)
      }
    } catch {
      thrown = error as? SoundPingError
    }
    return Collected(events: events, error: thrown)
  }

  @Test func aProbeSpoiltByAGlitchIsReplayedAtTheSameLevelNotStepped() async throws {
    let collected = try await Self.runGlitched(
      glitches: 2, scenario: Scenario(jitterFrames: 0, seed: 5))
    #expect(collected.error == nil, "\(String(describing: collected.error))")
    let levels = collected.probes.map(\.levelDbfs)
    #expect(levels.count >= 3)
    #expect(
      levels.prefix(3).allSatisfy { $0 == -48 }, "two glitched probes, then a clean one: \(levels)")
    #expect(collected.probes.prefix(2).allSatisfy { $0.confidence == 0 })
    #expect(collected.result != nil)
  }

  @Test func theReplaysAreBoundedSoARunOfGlitchesStillEndsTheRamp() async throws {
    let collected = try await Self.runGlitched(
      glitches: 1_000, scenario: Scenario(jitterFrames: 0, pathGainDb: -80, seed: 5))
    let error = try #require(collected.error)
    #expect(error.code == "nothingHeardAtCeiling")
    let levels = collected.probes.map(\.levelDbfs)
    #expect(levels.allSatisfy { $0 <= -6 })
    // Each level is played once plus its bounded replays.
    let perLevel = 1 + LevelRamp.maxGlitchRetries
    #expect(levels.count == 8 * perLevel, "\(levels.count)")
  }

  @Test func aZeroFramePathIsHeardAndMeasuredInsteadOfFailingThePreflight() async throws {
    // A software loop adds no converter latency: the chirp lands on the output frame itself.
    let collected = try await Self.run(Scenario(latencyFrames: 0, jitterFrames: 0, seed: 4))
    #expect(collected.error == nil, "\(String(describing: collected.error))")
    let result = try #require(collected.result)
    let path = try #require(result.measured.path)
    #expect(path.valid == 20)
    let median = try #require(path.median)
    #expect(abs(median.frames) < 0.1, "\(median.frames)")
  }

  @Test func aNegativePathIsKeptAsMeasuredNotRejectedAsOutsideTheWindow() async throws {
    // A driver that labels input a little early: the window reaches back before the output frame.
    let collected = try await Self.run(Scenario(latencyFrames: -24, jitterFrames: 0, seed: 4))
    #expect(collected.error == nil, "\(String(describing: collected.error))")
    let result = try #require(collected.result)
    #expect(result.rejectedCounts[RejectionReason.outsideWindow.rawValue] == 0)
    let path = try #require(result.measured.path)
    let median = try #require(path.median)
    #expect(abs(median.frames - -24) < 0.1, "\(median.frames)")
  }

  @Test func aBluetoothOutputRampsNoHigherThanTheHeadphoneCeiling() async throws {
    var output = DeviceRef(uid: "bt-speaker", name: "Bluetooth Speaker")
    output.transport = "bluetooth"
    let setup = ResolvedSetup(
      output: output, input: SimulatedCatalog.macMicrophone.ref, outChannels: [1, 2], inChannel: 1)
    let collected = try await Self.run(
      Scenario(jitterFrames: 0, pathGainDb: -80, seed: 3), setup: setup)
    let error = try #require(collected.error)
    #expect(error.code == "nothingHeardAtCeiling")
    #expect(error.context["listener"] == "headphones")
    #expect(error.context["ceilingDbfs"] == "-30.0")
    #expect(collected.probes.map(\.levelDbfs) == [-48, -42, -36, -30])
  }

  @Test func aBluetoothOutputWithAVirtualInputStillRampsNoHigherThanTheHeadphoneCeiling()
    async throws
  {
    var output = DeviceRef(uid: "bt-speaker", name: "Bluetooth Speaker")
    output.transport = "bluetooth"
    // A virtual device that carries other audio (not silent), on a different device than the output.
    let setup = ResolvedSetup(
      output: output, input: SimulatedCatalog.duplex.ref, outChannels: [1, 2], inChannel: 1,
      inChannelName: "Loop 1")
    let collected = try await Self.run(
      Scenario(jitterFrames: 0, pathGainDb: -80, seed: 3), setup: setup)
    let error = try #require(collected.error)
    #expect(error.code == "nothingHeardAtCeiling")
    #expect(error.context["listener"] == "headphones")
    #expect(error.context["ceilingDbfs"] == "-30.0")
    #expect(collected.probes.map(\.levelDbfs) == [-48, -42, -36, -30])
    #expect(collected.probes.allSatisfy { $0.levelDbfs <= -30 })
  }

  @Test func theListenerFlagOnABluetoothOutputRampsNoHigherThanTheHeadphoneCeiling() async throws {
    // WR-13: `--listener loopback` (or speaker) used to replace the headphone ceiling outright.
    var output = DeviceRef(uid: "bt-speaker", name: "Bluetooth Speaker")
    output.transport = "bluetooth"
    let setup = ResolvedSetup(
      output: output, input: SimulatedCatalog.macMicrophone.ref, outChannels: [1, 2], inChannel: 1)
    for named in [ListenerKind.loopback, .speaker, .unknown] {
      let collected = try await Self.run(
        Scenario(jitterFrames: 0, pathGainDb: -80, seed: 3),
        preflight: PreflightOptions(listener: named), setup: setup)
      let error = try #require(collected.error)
      #expect(error.code == "nothingHeardAtCeiling")
      #expect(error.context["ceilingDbfs"] == "-30.0", "--listener \(named)")
      #expect(error.context["detectedListener"] == "headphones")
      #expect(collected.probes.allSatisfy { $0.levelDbfs <= -30 }, "--listener \(named)")
    }

    // A run that locks reports the flag's listener, the headphone ceiling, and why.
    let locked = try await Self.run(
      Scenario(jitterFrames: 0, seed: 3), preflight: PreflightOptions(listener: .loopback),
      setup: setup)
    let preflight = try #require(locked.result?.preflight)
    #expect(preflight.listenerKind == .loopback)
    #expect(preflight.ceilingDbfs == -30)
    #expect(preflight.lockedLevelDbfs <= -30)
    #expect(preflight.warnings.contains { $0.contains("does not raise") }, "\(preflight.warnings)")
  }

  @Test func nothingHeardOnAHeadphoneListenerPointsAtMaxLevelForASpeaker() throws {
    let headphones = try LevelRamp.loudness(detected: .headphones, options: PreflightOptions())
    let error = Preflight.nothingHeardError(
      loudness: headphones, probes: 4, chosenLevel: nil, terminalApp: nil)
    let fix = error.context["fix"] ?? ""
    #expect(fix.contains("--max-level"), "\(fix)")
    #expect(fix.contains("Bluetooth speaker"), "\(fix)")
    #expect(fix.contains("--listener does not change"), "\(fix)")
    #expect(error.context["ceilingSource"] == "devices")

    // An unknown output: --max-level is the one way up, and the Bluetooth hint is not given.
    let unknown = Preflight.nothingHeardError(
      loudness: try LevelRamp.loudness(detected: .unknown, options: PreflightOptions()),
      probes: 4, chosenLevel: nil, terminalApp: nil)
    #expect(unknown.context["fix"]?.contains("--max-level") == true)
    #expect(unknown.context["fix"]?.contains("Bluetooth") == false)

    // A detected loop that hears nothing at -6 dBFS is a routing problem, not a ceiling one.
    let loop = Preflight.nothingHeardError(
      loudness: try LevelRamp.loudness(detected: .loopback, options: PreflightOptions()),
      probes: 8, chosenLevel: nil, terminalApp: nil)
    #expect(loop.context["fix"]?.contains("--max-level") == false)

    // A ceiling lowered by --listener names the flag; one set by --max-level says so.
    let lowered = Preflight.nothingHeardError(
      loudness: try LevelRamp.loudness(
        detected: .loopback, options: PreflightOptions(listener: .headphones)),
      probes: 4, chosenLevel: nil, terminalApp: nil)
    #expect(lowered.context["fix"]?.contains("--listener headphones lowered") == true)
    #expect(lowered.detail.contains("set by --listener headphones"), "\(lowered.detail)")
    let capped = Preflight.nothingHeardError(
      loudness: try LevelRamp.loudness(
        detected: .headphones, options: PreflightOptions(maxLevelDbfs: -20)),
      probes: 5, chosenLevel: nil, terminalApp: nil)
    #expect(capped.context["fix"]?.contains("your --max-level") == true)
  }

  @Test func aMutedOutputIsNamedBeforeTheFirstProbe() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, outputMuted: true, seed: 3))
    let error = try #require(collected.error)
    #expect(error.code == "outputMuted")
    #expect(error.kind == .preflight)
    #expect(collected.probes.isEmpty, "mute is checked before any sound is played")
  }

  @Test func theChecksRunInAFixedOrderAndTheFirstFailureWins() async throws {
    let denied = try await Self.run(
      Scenario(jitterFrames: 0, permission: .denied, inputZeros: true, outputMuted: true, seed: 3))
    #expect(denied.error?.code == "micPermissionDenied")

    let muted = try await Self.run(
      Scenario(jitterFrames: 0, inputZeros: true, outputMuted: true, seed: 3))
    #expect(muted.error?.code == "outputMuted")
  }

  @Test func theListenerOverrideSetsTheCeilingAndNothingIsEverPlayedAboveIt() async throws {
    let collected = try await Self.run(
      Scenario(jitterFrames: 0, pathGainDb: -80, seed: 3),
      preflight: PreflightOptions(listener: .headphones))
    #expect(collected.error?.code == "nothingHeardAtCeiling")
    #expect(collected.probes.map(\.levelDbfs) == [-48, -42, -36, -30])
    #expect(collected.probes.allSatisfy { $0.levelDbfs <= -30 })
  }

  @Test func maxLevelReplacesTheCeilingForTheRun() async throws {
    let collected = try await Self.run(
      Scenario(jitterFrames: 0, pathGainDb: -80, seed: 3),
      preflight: PreflightOptions(maxLevelDbfs: -20, listener: .headphones))
    #expect(collected.error?.code == "nothingHeardAtCeiling")
    #expect(collected.probes.last?.levelDbfs == -20)

    let ok = try await Self.run(
      Scenario(jitterFrames: 0, seed: 3),
      preflight: PreflightOptions(maxLevelDbfs: -10, listener: .headphones))
    #expect(ok.result?.preflight?.ceilingDbfs == -10)
  }

  @Test func aChosenLevelIsConfirmedByOneProbeAndCappedByTheCeiling() async throws {
    let chosen = try await Self.run(Scenario(jitterFrames: 0, seed: 3), level: -20)
    #expect(chosen.probes.map(\.levelDbfs) == [-20])
    #expect(chosen.result?.preflight?.lockedLevelDbfs == -20)

    let capped = try await Self.run(
      Scenario(jitterFrames: 0, seed: 3), level: -6,
      preflight: PreflightOptions(listener: .headphones))
    #expect(capped.result?.preflight?.lockedLevelDbfs == -30)
    #expect(capped.result?.preflight?.warnings.isEmpty == false, "the cap is said, not silent")
  }

  @Test func theChirpBandFollowsTheListenerUnlessATemplateWasNamed() async throws {
    let follows = try await Self.run(
      Scenario(jitterFrames: 0, seed: 3),
      preflight: PreflightOptions(listener: .speaker, templateFollowsListener: true))
    let result = try #require(follows.result)
    #expect(result.preflight?.templateId == "chirp-speaker")
    #expect(result.parameters.templateId == "chirp-speaker")
    #expect(follows.locks.first?.templateId == "chirp-speaker")
    #expect(try #require(result.measured.path).valid == 20)

    let named = try await Self.run(
      Scenario(jitterFrames: 0, seed: 3),
      preflight: PreflightOptions(listener: .speaker, templateFollowsListener: false))
    #expect(named.result?.preflight?.templateId == "chirp-loopback")
    #expect(named.result?.parameters.templateId == "chirp-loopback")
  }
}
