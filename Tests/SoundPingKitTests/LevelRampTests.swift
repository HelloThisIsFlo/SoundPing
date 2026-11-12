import Foundation
import Testing

@testable import SoundPingKit

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

  @Test func aVirtualOutputIsALoopbackWhateverItsInput() {
    let setup = Self.setup(output: Self.duplex, input: Self.macMicrophone)
    #expect(
      LevelRamp.classify(setup: setup, output: Self.duplex, input: Self.macMicrophone)
        == .loopback)
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

  @Test func theChannelProbeAlsoKeepsTheHeadphoneCeilingOnABluetoothOutput() {
    let earbuds = Self.bluetooth(from: Self.macSpeakers)
    let setup = Self.setup(output: earbuds, input: Self.macMicrophone)
    #expect(
      ChannelProbe.listenerKind(options: PreflightOptions(), setup: setup, output: earbuds)
        == .headphones)
    #expect(
      ChannelProbe.listenerKind(
        options: PreflightOptions(listener: .speaker), setup: setup, output: earbuds) == .speaker,
      "--listener still wins")
  }

  @Test func eachListenerHasItsOwnCeiling() {
    #expect(LevelRamp.ceilingDbfs(for: .loopback) == -6)
    #expect(LevelRamp.ceilingDbfs(for: .speaker) == -12)
    #expect(LevelRamp.ceilingDbfs(for: .headphones) == -30)
    #expect(LevelRamp.ceilingDbfs(for: .unknown) == -18)
  }

  @Test func maxLevelReplacesTheCeilingAndMustNotBeAboveFullScale() throws {
    #expect(try LevelRamp.resolveCeiling(kind: .headphones, maxLevelDbfs: nil) == -30)
    #expect(try LevelRamp.resolveCeiling(kind: .headphones, maxLevelDbfs: -10) == -10)
    #expect(try LevelRamp.resolveCeiling(kind: .loopback, maxLevelDbfs: 0) == 0)
    #expect(throws: SoundPingError.self) {
      _ = try LevelRamp.resolveCeiling(kind: .loopback, maxLevelDbfs: 3)
    }
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

  @Test func nothingHeardOnAHeadphoneListenerPointsAtMaxLevelForASpeaker() {
    let error = Preflight.nothingHeardError(
      ceilingDbfs: -30, listener: .headphones, probes: 4, chosenLevel: nil, terminalApp: nil)
    let fix = error.context["fix"] ?? ""
    #expect(fix.contains("--max-level"), "\(fix)")
    #expect(fix.contains("Bluetooth speaker"), "\(fix)")
    // Other listeners do not get the Bluetooth hint.
    let unknown = Preflight.nothingHeardError(
      ceilingDbfs: -18, listener: .unknown, probes: 4, chosenLevel: nil, terminalApp: nil)
    #expect(unknown.context["fix"]?.contains("--max-level") == false)
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
