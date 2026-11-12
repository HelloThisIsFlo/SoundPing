import CoreAudio
import Foundation
import Testing

@testable import SoundPingKit

/// Glitches are recorded as per-direction intervals and judged by a direct query, never by an event
/// stream or a single point (WR-01, IN-08).
@Suite struct FaultRecordingTests {
  private static func makeState(faultCapacity: Int = 4096, shared: Bool = true) -> RTState {
    RTState(
      RTState.Configuration(
        sampleRate: 48_000, inputSlot: ChannelSlot(buffer: 0, channelInBuffer: 0, channelsInBuffer: 2),
        outputSlots: [ChannelSlot(buffer: 0, channelInBuffer: 0, channelsInBuffer: 2)],
        templates: [[1, 2, 3, 4]], scheduleCapacity: 4, stampCapacity: 64,
        sharedDevice: shared, faultCapacity: faultCapacity))
  }

  private static func everyFault(_ rt: RTState) -> [FaultInterval] {
    rt.faults(overlappingInput: -1_000_000..<10_000_000, output: -1_000_000..<10_000_000)
  }

  private static func capture(
    _ rt: RTState, at sample: Double, flags: AudioTimeStampFlags? = nil
  ) {
    let buffers = SyntheticBuffers(widths: [2], frames: 16, fill: 0.5)
    let time =
      flags.map { timeStamp(sample: sample, flags: $0) } ?? timeStamp(sample: sample)
    captureCycle(rt, buffers, time)
  }

  private static func play(_ rt: RTState, at sample: Double, flags: AudioTimeStampFlags? = nil) {
    let buffers = SyntheticBuffers(widths: [2], frames: 16)
    let time =
      flags.map { timeStamp(sample: sample, flags: $0) } ?? timeStamp(sample: sample)
    playCycle(rt, buffers, time)
  }

  // MARK: Recording from the IOProc

  @Test func aForwardJumpIsOneInputLostFramesFaultAndStillZeroFills() throws {
    let rt = Self.makeState()
    Self.capture(rt, at: 5000)
    Self.capture(rt, at: 5080)  // 5016 expected: 64 frames lost
    #expect(
      Self.everyFault(rt)
        == [FaultInterval(direction: .input, frames: 5016..<5080, cause: .lostFrames)])
    let captured = try rt.readCapture(5000..<5096)
    #expect(captured[16..<80].allSatisfy { $0 == 0 })
  }

  @Test func twoJumpsBetweenTwoReadsStayTwoFaults() throws {
    let rt = Self.makeState()
    Self.capture(rt, at: 5000)
    Self.capture(rt, at: 5080)  // loses 5016..<5080
    Self.capture(rt, at: 5096)
    Self.capture(rt, at: 5200)  // loses 5112..<5200
    // Nothing read the faults in between; they are not collapsed into one.
    #expect(
      Self.everyFault(rt)
        == [
          FaultInterval(direction: .input, frames: 5016..<5080, cause: .lostFrames),
          FaultInterval(direction: .input, frames: 5112..<5200, cause: .lostFrames),
        ])
  }

  @Test func aBackwardJumpCoversTheLabelsBetweenTheNewAndTheExpectedOne() throws {
    let rt = Self.makeState()
    Self.capture(rt, at: 5000)
    Self.capture(rt, at: 5016)
    Self.capture(rt, at: 5000)  // the clock went back: 5032 expected, 5000 arrived
    let faults = Self.everyFault(rt)
    #expect(faults == [FaultInterval(direction: .input, frames: 5000..<5032, cause: .lostFrames)])
    #expect(faults.allSatisfy { !$0.frames.isEmpty })
  }

  @Test func aCallbackWithoutAHostTimeIsAnInvalidTimestampFaultInItsOwnDirection() throws {
    let input = Self.makeState()
    Self.capture(input, at: 5000)
    Self.capture(input, at: 5016, flags: [.sampleTimeValid, .rateScalarValid])
    #expect(
      Self.everyFault(input)
        == [FaultInterval(direction: .input, frames: 5016..<5032, cause: .invalidTimestamp)])

    let output = Self.makeState(shared: false)
    Self.play(output, at: 9000)
    Self.play(output, at: 9016, flags: [.sampleTimeValid])
    #expect(
      Self.everyFault(output)
        == [FaultInterval(direction: .output, frames: 9016..<9032, cause: .invalidTimestamp)])
  }

  @Test func anOutputLabelJumpIsAnOutputFaultInOutputLabels() throws {
    let rt = Self.makeState(shared: false)
    Self.play(rt, at: 9000)
    Self.play(rt, at: 9016)
    Self.play(rt, at: 9100)  // 9032 expected: 68 frames not played
    #expect(
      Self.everyFault(rt)
        == [FaultInterval(direction: .output, frames: 9032..<9100, cause: .lostFrames)])
    // Not in the input direction's label space.
    #expect(rt.faults(overlappingInput: 9000..<9200, output: 0..<10).isEmpty)
  }

  @Test func anOverloadOnACapturingDeviceCoversTheLookbackAndTheBufferInFlight() throws {
    let rt = Self.makeState()
    Self.capture(rt, at: 1000)  // the next input label is 1016
    rt.noteOverload(onInput: true, onOutput: false, lookbackFrames: 40, bufferFrames: 16)
    #expect(
      Self.everyFault(rt)
        == [FaultInterval(direction: .input, frames: 976..<1032, cause: .overload)])
  }

  @Test func anOverloadOnAnOutputOnlyDeviceLandsInOutputLabelsAndNotOnTheInputPosition() throws {
    let rt = Self.makeState(shared: false)
    Self.capture(rt, at: 7000)  // the input device is somewhere else entirely
    Self.play(rt, at: 90_000)  // the output device's next label is 90_016
    rt.noteOverload(onInput: false, onOutput: true, lookbackFrames: 960, bufferFrames: 16)
    #expect(
      Self.everyFault(rt)
        == [FaultInterval(direction: .output, frames: 89_056..<90_032, cause: .overload)])
    #expect(rt.faults(overlappingInput: 6_900..<7_100, output: 0..<10).isEmpty)
  }

  // MARK: Overlap, not containment

  @Test func aFaultIsReportedWhenItOverlapsTheWindowEvenPartly() throws {
    let rt = Self.makeState()
    let window: Range<Int64> = 100..<200
    rt.inputFaults.append(lower: 90, upper: 105, cause: faultLostFramesCode)
    #expect(rt.faults(overlappingInput: window, output: 0..<1).count == 1)
  }

  @Test func aFaultThatOnlyTouchesTheWindowsEdgeIsNotReported() throws {
    let rt = Self.makeState()
    rt.inputFaults.append(lower: 50, upper: 100, cause: faultLostFramesCode)  // ends at the lower bound
    rt.inputFaults.append(lower: 200, upper: 210, cause: faultLostFramesCode)  // starts at the upper bound
    #expect(rt.faults(overlappingInput: 100..<200, output: 0..<1).isEmpty)
  }

  // MARK: A wrapped record fails safe

  @Test func aWrappedFaultRingReportsWhatItHasForgottenInsteadOfPassingTheHit() throws {
    let rt = Self.makeState(faultCapacity: 4)
    for i in 0..<6 { rt.inputFaults.append(lower: i * 100, upper: i * 100 + 10, cause: 0) }
    // Entries 0 and 1 were overwritten; the oldest retained fault starts at 200.
    let below = rt.faults(overlappingInput: 0..<150, output: 0..<1)
    #expect(below.contains { $0.cause == .logOverwritten })
    #expect(below.first { $0.cause == .logOverwritten }?.frames == 0..<200)

    // A query that starts at or above the oldest retained fault only gets the real overlaps.
    let above = rt.faults(overlappingInput: 200..<420, output: 0..<1)
    #expect(above.count == 3)
    #expect(above.allSatisfy { $0.cause == .lostFrames })
    #expect(!above.contains { $0.cause == .logOverwritten })
  }

  @Test func aRingThatNeverWrappedNeverReportsOverwrittenFrames() throws {
    let rt = Self.makeState(faultCapacity: 4)
    rt.inputFaults.append(lower: 500, upper: 510, cause: 0)
    #expect(rt.faults(overlappingInput: 0..<100, output: 0..<100).isEmpty)
  }

  // MARK: HitListener asks the backend directly

  /// The simulator under a backend whose events never say anything and whose fault record is set by
  /// the test, with stamps that are continuous. Counts the reads of the capture.
  private actor FaultingBackend: AudioBackend {
    private let inner: SimulatedBackend
    private var recorded: [FaultInterval] = []
    private(set) var captureReads = 0
    nonisolated let events = AsyncStream<DeviceEvent> { _ in }

    init(scenario: Scenario) { inner = SimulatedBackend(scenario: scenario) }

    func record(_ faults: [FaultInterval]) { recorded = faults }

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
    func capture(_ range: Range<Int64>) async throws -> [Float] {
      captureReads += 1
      return try await inner.capture(range)
    }
    func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
      await inner.stamps(covering: range)
    }
    func stampLog() async -> StampLog { await inner.stampLog() }
    func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async
      -> [FaultInterval]
    {
      recorded.filter { fault in
        let query = fault.direction == .input ? input : output
        return fault.frames.lowerBound < query.upperBound
          && fault.frames.upperBound > query.lowerBound
      }
    }
    func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }
    func stop() async { await inner.stop() }
  }

  /// Listens for one hit on a clean simulated device with `faults` on record. `place` turns the hit
  /// into the faults, so a test can aim them at the window or the played chirp.
  private static func listen(
    faults place: (ScheduledHit, Int64) -> [FaultInterval]
  ) async throws -> (heard: HitListener.Heard, captureReads: Int) {
    let backend = FaultingBackend(scenario: Scenario(jitterFrames: 0, seed: 3))
    let template = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: 48_000)
    _ = try await backend.open(.simulatedDuplex, templates: [template])
    let info = try await backend.start()
    let frames = Int64(template.samples.count)
    var listener = HitListener(
      backend: backend, info: info, templateFrames: frames,
      maxLatencyMs: RunParameters(seed: 0).maxLatencyMs, twoDevice: false)
    let hit = ScheduledHit(
      index: 0, outputFrame: await backend.currentOutputFrame() + 4_800, gain: 0.5,
      templateId: template.id)
    try await backend.schedule([hit])
    await backend.record(place(hit, frames))
    let heard = try await listener.listen(to: hit, with: Correlator(template: template))
    return (heard, await backend.captureReads)
  }

  @Test func anInputFaultInTheWindowRejectsTheHitWithoutReadingTheCapture() async throws {
    // The chirp arrives about 412 frames after it is played.
    let (heard, reads) = try await Self.listen { hit, _ in
      [
        FaultInterval(
          direction: .input, frames: (hit.outputFrame + 400)..<(hit.outputFrame + 464),
          cause: .overload)
      ]
    }
    guard case .rejected(.discontinuity) = heard.detection else {
      Issue.record("expected a discontinuity rejection, got \(heard.detection)")
      return
    }
    #expect(heard.faulted)
    #expect(reads == 0)
  }

  @Test func anOutputFaultWhileTheChirpPlayedAlsoRejectsTheHit() async throws {
    let (heard, reads) = try await Self.listen { hit, frames in
      [
        FaultInterval(
          direction: .output, frames: (hit.outputFrame + frames - 8)..<(hit.outputFrame + frames + 8),
          cause: .lostFrames)
      ]
    }
    guard case .rejected(.discontinuity) = heard.detection else {
      Issue.record("expected a discontinuity rejection, got \(heard.detection)")
      return
    }
    #expect(heard.faulted)
    #expect(reads == 0)
  }

  @Test func aFaultOutsideBothRangesLeavesTheHitFound() async throws {
    let (heard, reads) = try await Self.listen { hit, frames in
      [
        // Long before the chirp in output labels, and long after its window in input labels.
        FaultInterval(
          direction: .output, frames: (hit.outputFrame - 2_000)..<(hit.outputFrame - 1_000),
          cause: .lostFrames),
        FaultInterval(
          direction: .input, frames: (hit.outputFrame + 60_000)..<(hit.outputFrame + 60_064),
          cause: .overload),
      ]
    }
    guard case .found = heard.detection else {
      Issue.record("expected the hit to be found, got \(heard.detection)")
      return
    }
    #expect(!heard.faulted)
    #expect(reads == 1)
  }
}
