import CoreAudio
import Foundation
import Testing

@testable import SoundPingKit

/// A hand-built AudioBufferList with interleaved Float32 buffers, like the one the HAL passes to
/// an IOProc. Owns its memory.
final class SyntheticBuffers {
  let list: UnsafeMutableAudioBufferListPointer
  let frames: Int
  let widths: [Int]

  init(widths: [Int], frames: Int, fill: Float = 0) {
    self.widths = widths
    self.frames = frames
    list = AudioBufferList.allocate(maximumBuffers: widths.count)
    for (i, width) in widths.enumerated() {
      let count = frames * width
      let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
      data.initialize(repeating: fill, count: count)
      list[i] = AudioBuffer(
        mNumberChannels: UInt32(width), mDataByteSize: UInt32(count * 4), mData: data)
    }
  }

  deinit {
    for buffer in list { buffer.mData?.deallocate() }
    free(list.unsafeMutablePointer)
  }

  var pointer: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }

  func sample(buffer: Int, frame: Int, channel: Int) -> Float {
    list[buffer].mData!.assumingMemoryBound(to: Float.self)[frame * widths[buffer] + channel]
  }

  func set(buffer: Int, frame: Int, channel: Int, to value: Float) {
    list[buffer].mData!.assumingMemoryBound(to: Float.self)[frame * widths[buffer] + channel] =
      value
  }
}

func timeStamp(
  sample: Double, host: UInt64 = 1, rate: Double = 1,
  flags: AudioTimeStampFlags = [.sampleTimeValid, .hostTimeValid, .rateScalarValid]
) -> AudioTimeStamp {
  var stamp = AudioTimeStamp()
  stamp.mSampleTime = sample
  stamp.mHostTime = host
  stamp.mRateScalar = rate
  stamp.mFlags = flags
  return stamp
}

/// One IOProc callback over buffer lists of the `[2, 4]` channel layout, called the way the HAL
/// block calls `ioCycle`. A direction a test does not care about gets a scratch list.
func cycle(
  _ rt: RTState, captures: Bool = true, plays: Bool = true, hasInputs: Bool = true,
  hasOutputs: Bool = true, input: SyntheticBuffers? = nil, inputTime: AudioTimeStamp,
  output: SyntheticBuffers? = nil, outputTime: AudioTimeStamp
) {
  let inList = input ?? SyntheticBuffers(widths: [2, 4], frames: 16)
  let outList = output ?? SyntheticBuffers(widths: [2, 4], frames: 16)
  var inTime = inputTime
  var outTime = outputTime
  ioCycle(
    rt, captures: captures, plays: plays, hasInputs: hasInputs, hasOutputs: hasOutputs,
    inputData: UnsafePointer(inList.pointer), inputTime: &inTime, outputData: outList.pointer,
    outputTime: &outTime)
}

/// An input-only callback, as a separate input device runs it.
func captureCycle(_ rt: RTState, _ input: SyntheticBuffers, _ time: AudioTimeStamp) {
  cycle(
    rt, captures: true, plays: false, hasOutputs: false, input: input, inputTime: time,
    outputTime: time)
}

/// An output-only callback, as a separate output device runs it.
func playCycle(
  _ rt: RTState, _ output: SyntheticBuffers, _ time: AudioTimeStamp, isOutputDevice: Bool = true
) {
  cycle(
    rt, captures: false, plays: isOutputDevice, hasInputs: false, inputTime: time,
    output: output, outputTime: time)
}

/// A scope whose channels are numbered across `streams` (channels per stream, in buffer order).
private func scope(streams: [Int]) -> ScopeInfo {
  var channels: [ChannelInfo] = []
  var index = 1
  for (streamIndex, width) in streams.enumerated() {
    for within in 0..<width {
      channels.append(
        ChannelInfo(
          index: index, name: "Ch \(index)", streamIndex: streamIndex, channelInStream: within + 1)
      )
      index += 1
    }
  }
  return ScopeInfo(
    channels: channels, deviceLatency: 0,
    streamLatencies: Array(repeating: 0, count: streams.count),
    safetyOffset: 0, bufferFrameSize: 16, bufferFrameSizeRange: FrameSizeRange(min: 16, max: 4096))
}

@Suite struct IOCycleTests {
  /// Output: stereo stream then a 4-channel stream (channels 1-2 | 3-6). Input: stereo then 4 channels.
  private static let outScope = scope(streams: [2, 4])
  private static let inScope = scope(streams: [2, 4])

  private static func makeState(
    outChannels: [Int] = [4, 5], inChannel: Int = 6,
    templates: [[Float]] = [[1, 2, 3, 4, 5, 6, 7, 8]],
    sampleRate: Double = 48_000, captureSeconds: Double = 8, shared: Bool = true,
    stampCapacity: Int = 64
  ) throws -> RTState {
    RTState(
      RTState.Configuration(
        sampleRate: sampleRate, captureSeconds: captureSeconds,
        inputSlot: ChannelSlot.slot(forChannel: inChannel, in: inScope),
        outputSlots: try outChannels.map {
          try #require(ChannelSlot.slot(forChannel: $0, in: outScope))
        },
        templates: templates, scheduleCapacity: 16, stampCapacity: stampCapacity,
        sharedDevice: shared))
  }

  private static func entry(at frame: Int, gain: Float = 0.5, hit: Int = 0) -> ScheduleEntry {
    ScheduleEntry(outputFrame: frame, gain: gain, template: 0, hitIndex: hit)
  }

  // MARK: Channel slots

  @Test func channelNumbersCountAcrossStreams() throws {
    let slot = try #require(ChannelSlot.slot(forChannel: 5, in: Self.outScope))
    #expect(slot == ChannelSlot(buffer: 1, channelInBuffer: 2, channelsInBuffer: 4))
    #expect(ChannelSlot.slot(forChannel: 1, in: Self.outScope)?.buffer == 0)
    #expect(ChannelSlot.slot(forChannel: 7, in: Self.outScope) == nil)
  }

  // MARK: Output

  @Test func theScheduledTemplateLandsAtTheExactSampleOffsetOnlyOnTheSelectedChannels() throws {
    let rt = try Self.makeState(outChannels: [4, 5])
    try rt.append([Self.entry(at: 1005)])
    let out = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 9)
    let time = timeStamp(sample: 1000)

    playCycle(rt, out, time)

    // Output channels 4 and 5 are channels 2 and 3 (1-based) of the second stream: indices 1 and 2.
    for frame in 0..<16 {
      let expected: Float = (5..<13).contains(frame) ? 0.5 * Float(frame - 5 + 1) : 0
      #expect(out.sample(buffer: 1, frame: frame, channel: 1) == expected, "frame \(frame)")
      #expect(out.sample(buffer: 1, frame: frame, channel: 2) == expected, "frame \(frame)")
      // Every other channel stays silent, including leftovers the HAL might have handed us.
      #expect(out.sample(buffer: 1, frame: frame, channel: 0) == 0)
      #expect(out.sample(buffer: 1, frame: frame, channel: 3) == 0)
      #expect(out.sample(buffer: 0, frame: frame, channel: 0) == 0)
      #expect(out.sample(buffer: 0, frame: frame, channel: 1) == 0)
    }
  }

  @Test func aHitSplitAcrossTwoCallbacksIsContinuous() throws {
    let rt = try Self.makeState(outChannels: [1])
    try rt.append([Self.entry(at: 1012, gain: 1)])
    let first = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 9)
    let second = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 9)
    let t1 = timeStamp(sample: 1000)
    let t2 = timeStamp(sample: 1016)

    playCycle(rt, first, t1)
    playCycle(rt, second, t2)

    var played: [Float] = []
    for frame in 12..<16 { played.append(first.sample(buffer: 0, frame: frame, channel: 0)) }
    for frame in 0..<4 { played.append(second.sample(buffer: 0, frame: frame, channel: 0)) }
    #expect(played == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(first.sample(buffer: 0, frame: 11, channel: 0) == 0)
    #expect(second.sample(buffer: 0, frame: 4, channel: 0) == 0)
  }

  @Test func theCursorMovesPastFinishedHitsAndOverlappingHitsAdd() throws {
    let rt = try Self.makeState(outChannels: [1])
    try rt.append([Self.entry(at: 1002, gain: 1, hit: 0), Self.entry(at: 1004, gain: 1, hit: 1)])
    let out = SyntheticBuffers(widths: [2, 4], frames: 16)
    let t1 = timeStamp(sample: 1000)
    playCycle(rt, out, t1)
    // Frame 1004 carries hit 0's third sample (3) and hit 1's first (1).
    #expect(out.sample(buffer: 0, frame: 4, channel: 0) == 4)
    #expect(rt.scheduleCursor.load(ordering: .relaxed) == 0)

    let later = SyntheticBuffers(widths: [2, 4], frames: 16)
    let t2 = timeStamp(sample: 1016)
    playCycle(rt, later, t2)
    #expect(rt.scheduleCursor.load(ordering: .relaxed) == 2)
  }

  @Test func aDeviceThatIsNotTheOutputDeviceIsOnlySilenced() throws {
    let rt = try Self.makeState(outChannels: [1], shared: false)
    try rt.append([Self.entry(at: 1000, gain: 1)])
    let out = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 9)
    let time = timeStamp(sample: 1000)

    playCycle(rt, out, time, isOutputDevice: false)

    for frame in 0..<16 {
      #expect(out.sample(buffer: 0, frame: frame, channel: 0) == 0)
      #expect(out.sample(buffer: 1, frame: frame, channel: 3) == 0)
    }
    #expect(rt.outputDeviceStamps.count == 0)
    let started = rt.outputStarted.load(ordering: .relaxed)
    #expect(!started)
  }

  @Test func outputStampsAreLoggedWithTheirTimes() throws {
    let rt = try Self.makeState(shared: false)
    let out = SyntheticBuffers(widths: [2, 4], frames: 16)
    let t1 = timeStamp(sample: 2000, host: 777, rate: 1.00002)
    let t2 = timeStamp(sample: 2016, host: 888, rate: 1.00003)
    playCycle(rt, out, t1)
    playCycle(rt, out, t2)

    #expect(rt.outputDeviceStamps.count == 2)
    let secondEntry = rt.outputDeviceStamps.entry(at: 1)
    let secondSides = try #require(secondEntry)
    let second = try #require(secondSides.output)
    #expect(second.sampleTime == 2016 && second.hostTime == 888 && second.frames == 16)
    #expect(second.rateScalar == 1.00003)
    #expect(rt.outputNextLabel.load(ordering: .relaxed) == 2032)
  }

  // MARK: Input

  @Test func theSelectedInputChannelIsCapturedAtTheRightRingIndex() throws {
    let rt = try Self.makeState(inChannel: 6)
    // Input channel 6 is the fourth channel of the second stream (index 3). Every frame carries its
    // own label in that channel and a decoy in all the others.
    for start in [5000, 5016] {
      let input = SyntheticBuffers(widths: [2, 4], frames: 16, fill: -3)
      for frame in 0..<16 {
        input.set(buffer: 1, frame: frame, channel: 3, to: Float(start + frame))
      }
      let time = timeStamp(sample: Double(start), host: UInt64(start) * 10, rate: 0.99998)
      captureCycle(rt, input, time)
    }

    let captured = try rt.readCapture(5000..<5032)
    #expect(captured == (5000..<5032).map { Float($0) })
    #expect(rt.inputFirstLabel.load(ordering: .relaxed) == 5000)
    #expect(rt.inputNextLabel.load(ordering: .relaxed) == 5032)
    #expect(Self.everyFault(rt).isEmpty)

    // Reading a middle slice, and the stamps that overlap it.
    #expect(try rt.readCapture(5010..<5020) == (5010..<5020).map { Float($0) })
    let stamps = rt.callbackStamps(covering: 5010..<5020)
    #expect(stamps.map(\.inputSampleTime) == [5000, 5016])
    #expect(stamps.allSatisfy { $0.frames == 16 })
  }

  @Test func inputStampsAreLogged() throws {
    let rt = try Self.makeState()
    let input = SyntheticBuffers(widths: [2, 4], frames: 16)
    let t1 = timeStamp(sample: 100, host: 12_345, rate: 0.99999)
    captureCycle(rt, input, t1)

    #expect(rt.inputDeviceStamps.count == 1)
    let firstEntry = rt.inputDeviceStamps.entry(at: 0)
    let firstSides = try #require(firstEntry)
    let point = try #require(firstSides.input)
    #expect(point.sampleTime == 100 && point.hostTime == 12_345)
    #expect(point.rateScalar == 0.99999 && point.frames == 16)
    #expect(rt.stampLog().input == [point])
  }

  /// Every fault the state has recorded, whatever the direction.
  private static func everyFault(_ rt: RTState) -> [FaultInterval] {
    rt.faults(overlappingInput: -1_000_000..<10_000_000, output: -1_000_000..<10_000_000)
  }

  @Test func aSixtyFourFrameJumpOfTheLabelIsOneInputFaultAndLeavesSilence() throws {
    let rt = try Self.makeState()
    let loud = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 0.25)
    let t1 = timeStamp(sample: 5000)
    let t2 = timeStamp(sample: 5080)  // 5016 + 64: the next callback arrives 64 frames late
    captureCycle(rt, loud, t1)
    #expect(Self.everyFault(rt).isEmpty)
    captureCycle(rt, loud, t2)

    // The missing frames are one interval, in input labels: [expected, label).
    #expect(
      Self.everyFault(rt)
        == [FaultInterval(direction: .input, frames: 5016..<5080, cause: .lostFrames)])
    let captured = try rt.readCapture(5000..<5096)
    #expect(captured[0..<16].allSatisfy { $0 == 0.25 })
    #expect(captured[16..<80].allSatisfy { $0 == 0 })
    #expect(captured[80..<96].allSatisfy { $0 == 0.25 })
  }

  @Test func continuityIsComparedInDoubleWithAHalfFrameTolerance() throws {
    // Exactly half a frame off is still continuous; anything past it is a discontinuity.
    for (offset, gaps) in [(0.0, 0), (0.5, 0), (-0.5, 0), (0.75, 1), (-0.75, 1), (1.0, 1)] {
      let rt = try Self.makeState()
      let input = SyntheticBuffers(widths: [2, 4], frames: 16)
      let t1 = timeStamp(sample: 9000)
      let t2 = timeStamp(sample: 9016 + offset)
      captureCycle(rt, input, t1)
      captureCycle(rt, input, t2)
      #expect(Self.everyFault(rt).count == gaps, "offset \(offset)")
    }
  }

  @Test func theCaptureRingWrapsAndRefusesFramesItNoLongerHolds() throws {
    // 0.1 s at 1000 Hz: a 100-frame ring.
    let rt = try Self.makeState(sampleRate: 1_000, captureSeconds: 0.1)
    #expect(rt.captureCapacity == 100)
    for start in stride(from: 0, to: 240, by: 16) {
      let input = SyntheticBuffers(widths: [2, 4], frames: 16)
      for frame in 0..<16 {
        input.set(buffer: 1, frame: frame, channel: 3, to: Float(start + frame))
      }
      let time = timeStamp(sample: Double(start))
      captureCycle(rt, input, time)
    }
    // 15 callbacks of 16 frames: 240 captured. The newest 100 are still there.
    #expect(try rt.readCapture(200..<240) == (200..<240).map { Float($0) })
    #expect(throws: SoundPingError.self) { _ = try rt.readCapture(100..<140) }
    #expect(throws: SoundPingError.self) { _ = try rt.readCapture(230..<250) }
  }

  // MARK: Stamp entries (WR-03, IN-08)

  /// Output labels this far ahead of the input labels, like a real duplex device.
  private static let offset = 44.0
  private static let validFlags: AudioTimeStampFlags = [
    .sampleTimeValid, .hostTimeValid, .rateScalarValid,
  ]

  /// Runs `count` duplex callbacks of 16 frames. `adjust` can spoil one callback's times or buffers.
  private static func duplexRun(
    _ rt: RTState, count: Int,
    adjust: (Int, inout AudioTimeStamp, inout AudioTimeStamp, inout SyntheticBuffers) -> Void = {
      _, _, _, _ in
    }
  ) {
    for i in 0..<count {
      let input = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 0.25)
      var output = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 9)
      var inTime = timeStamp(sample: 1000 + Double(i * 16), host: UInt64(1000 + i * 16) * 10)
      var outTime = timeStamp(
        sample: 1000 + Double(i * 16) + offset, host: UInt64(1000 + i * 16) * 10 + 7)
      adjust(i, &inTime, &outTime, &output)
      cycle(rt, input: input, inputTime: inTime, output: output, outputTime: outTime)
    }
  }

  @Test func aSkippedOutputSideNeverShiftsLaterInputOutputPairs() throws {
    // Callback 4 loses its output side two ways: a time without sampleTimeValid, and a buffer list
    // with a zero-channel buffer. Under index pairing every pair after it was a buffer off.
    for variant in 0..<2 {
      let rt = try Self.makeState()
      Self.duplexRun(rt, count: 10) { i, _, outTime, output in
        guard i == 4 else { return }
        if variant == 0 {
          outTime.mFlags = [.hostTimeValid, .rateScalarValid]
        } else {
          output = SyntheticBuffers(widths: [0], frames: 16, fill: 9)
        }
      }
      let log = rt.stampLog()
      #expect(log.input.count == 10, "variant \(variant)")
      #expect(log.output.count == 9, "variant \(variant)")
      #expect(log.ioOffsetFrames.count == 9, "variant \(variant)")
      #expect(log.ioOffsetFrames.allSatisfy { $0 == Self.offset }, "variant \(variant)")
    }
  }

  @Test func aCallbackWithoutAValidHostTimeIsCapturedButNotStamped() throws {
    let rt = try Self.makeState()
    Self.duplexRun(rt, count: 10) { i, inTime, _, _ in
      if i == 4 { inTime.mFlags = [.sampleTimeValid, .rateScalarValid] }
    }
    // Its audio is captured at its label and the label moves on.
    #expect(rt.inputNextLabel.load(ordering: .relaxed) == 1160)
    #expect(try rt.readCapture(1064..<1080).allSatisfy { $0 == 0.25 })
    // Its entry has no input side, so the offsets and the input list skip it.
    let log = rt.stampLog()
    #expect(log.input.count == 9)
    #expect(log.input.allSatisfy { $0.hostTime > 0 })
    #expect(log.ioOffsetFrames.count == 9 && log.ioOffsetFrames.allSatisfy { $0 == Self.offset })
    // A window across it sees a jump in the stamps' sample times, so the correlator refuses it.
    let stamps = rt.callbackStamps(covering: 1048..<1096)
    #expect(Correlator.hasDiscontinuity(stamps))
    // A window clear of it is clean.
    #expect(!Correlator.hasDiscontinuity(rt.callbackStamps(covering: 1096..<1150)))
  }

  @Test func aCallbackWithoutAValidSampleTimeCapturesNothing() throws {
    let rt = try Self.makeState()
    Self.duplexRun(rt, count: 6) { i, inTime, _, _ in
      if i == 3 { inTime.mFlags = [.hostTimeValid, .rateScalarValid] }
    }
    // The skipped callback's frames (1048..<1064) read as the zero-filled gap the next callback leaves.
    #expect(rt.inputNextLabel.load(ordering: .relaxed) == 1096)
    let captured = try rt.readCapture(1000..<1096)
    #expect(captured[48..<64].allSatisfy { $0 == 0 })
    #expect(captured[0..<48].allSatisfy { $0 == 0.25 })
    #expect(captured[64..<96].allSatisfy { $0 == 0.25 })
    #expect(rt.stampLog().input.count == 5)
  }

  @Test func anOutputTimeWithoutAValidSampleTimeMixesNothingAndMovesNothing() throws {
    let rt = try Self.makeState(outChannels: [1])
    try rt.append([Self.entry(at: 1000, gain: 1)])
    let output = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 9)
    let time = timeStamp(sample: 1000, flags: [.hostTimeValid, .rateScalarValid])
    playCycle(rt, output, time)

    for frame in 0..<16 {
      #expect(output.sample(buffer: 0, frame: frame, channel: 0) == 0)
    }
    #expect(rt.outputNextLabel.load(ordering: .relaxed) == 0)
    let started = rt.outputStarted.load(ordering: .relaxed)
    #expect(!started)
    #expect(rt.stampLog().output.isEmpty)
  }

  @Test func aMissingRateScalarIsLoggedAsZero() throws {
    let rt = try Self.makeState()
    Self.duplexRun(rt, count: 1) { _, inTime, outTime, _ in
      inTime.mFlags = [.sampleTimeValid, .hostTimeValid]
      outTime.mFlags = [.sampleTimeValid, .hostTimeValid]
    }
    let log = rt.stampLog()
    #expect(log.input.map(\.rateScalar) == [0] && log.output.map(\.rateScalar) == [0])
  }

  @Test func twoDevicesLogTheirOwnRingsAndNeverPair() throws {
    let rt = try Self.makeState(shared: false)
    for i in 0..<12 {
      let input = SyntheticBuffers(widths: [2, 4], frames: 16)
      captureCycle(rt, input, timeStamp(sample: 7000 + Double(i * 16), host: 100 + UInt64(i)))
      // The output device runs on other labels and skips its fifth callback.
      if i != 4 {
        let output = SyntheticBuffers(widths: [2, 4], frames: 16)
        playCycle(
          rt, output, timeStamp(sample: 90_000 + Double(i * 16), host: 200 + UInt64(i)))
      }
    }
    let log = rt.stampLog()
    #expect(log.ioOffsetFrames.isEmpty)
    #expect(log.input.count == 12 && log.output.count == 11)
    #expect(log.input.allSatisfy { $0.sampleTime < 10_000 })
    #expect(log.output.allSatisfy { $0.sampleTime >= 90_000 })
    // Output fields of the input stamps come from nowhere: no ordinal lookup across devices.
    let stamps = rt.callbackStamps(covering: 7000..<7192)
    #expect(stamps.count == 12)
    #expect(stamps.allSatisfy { $0.outputSampleTime == 0 && $0.outputHostTime == 0 })
  }

  @Test func aWrappedStampRingKeepsTheNewestEntriesAndExactOffsets() throws {
    let rt = try Self.makeState(stampCapacity: 8)
    Self.duplexRun(rt, count: 20)
    let log = rt.stampLog()
    #expect(log.input.count == 8 && log.output.count == 8)
    #expect(log.ioOffsetFrames.count == 8)
    #expect(log.ioOffsetFrames.allSatisfy { $0 == Self.offset })
    #expect(log.input.first?.sampleTime == Double(1000 + 12 * 16))
    #expect(rt.inputDeviceStamps.entry(at: 3) == nil, "an overwritten ordinal is refused")
  }

  // MARK: Schedule ring

  @Test func theScheduleRingRefusesOutOfOrderAndOverflowingHits() throws {
    let rt = try Self.makeState()
    try rt.append([Self.entry(at: 500), Self.entry(at: 300, hit: 1)])
    #expect(throws: SoundPingError.self) { try rt.append([Self.entry(at: 100, hit: 2)]) }
    #expect(throws: SoundPingError.self) {
      try rt.append((0..<20).map { Self.entry(at: 1000 + $0, hit: $0) })
    }
    // The ring held its order: the earlier entry sits first.
    #expect(rt.schedule[0].outputFrame == 300 && rt.schedule[1].outputFrame == 500)
    #expect(rt.scheduleCount.load(ordering: .relaxed) == 2)
  }

  @Test func theTemplatesAreCopiedInOnceAndAddressedByIndex() throws {
    let rt = try Self.makeState(templates: [[1, 2, 3], [9, 8]])
    #expect(rt.templateCount == 2)
    #expect(rt.templateOffsets[1] == 3 && rt.templateLengths[0] == 3 && rt.templateLengths[1] == 2)
    #expect(rt.templateData[3] == 9)
  }

  // MARK: Source rules (T-01-23, T-01-25)

  private static let sourcesFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources", isDirectory: true)

  /// Every Swift file under Sources with its non-comment lines.
  private static func sourceLines() throws -> [(file: String, line: String)] {
    var found: [(String, String)] = []
    let enumerator = try #require(
      FileManager.default.enumerator(at: sourcesFolder, includingPropertiesForKeys: nil))
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let relative = String(url.path.dropFirst(sourcesFolder.path.count + 1))
      for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.hasPrefix("//") { found.append((relative, trimmed)) }
      }
    }
    return found
  }

  @Test func theOnlyDevicePropertyEverSetIsSoundPingsOwnBufferSize() throws {
    let lines = try Self.sourceLines()
    let setters = lines.filter {
      $0.line.contains("SetPropertyData") || $0.line.contains("AudioDeviceSetProperty")
        || $0.line.contains("AudioHardwareSetProperty")
    }
    // One call site, in the HAL backend, and its address is the buffer frame size.
    #expect(setters.count == 1, "set-property call sites: \(setters.map(\.file))")
    #expect(setters.first?.file == "SoundPingKit/Audio/HALBackend.swift")
    let backend = try String(
      contentsOf: Self.sourcesFolder.appendingPathComponent("SoundPingKit/Audio/HALBackend.swift"),
      encoding: .utf8)
    let call = try #require(backend.range(of: "AudioObjectSetPropertyData("))
    let before = backend[..<call.lowerBound].suffix(400)
    #expect(before.contains("HALProperty.address(kAudioDevicePropertyBufferFrameSize)"))
    // No other write path to the rate, volume, mute or defaults exists.
    for forbidden in [
      "kAudioDevicePropertyNominalSampleRate = ", "kAudioHardwarePropertyDefaultOutputDevice,",
    ] {
      #expect(!lines.contains { $0.line.contains("Set") && $0.line.contains(forbidden) })
    }
  }

  @Test func onlyTheAudioFolderTouchesCoreAudio() throws {
    let lines = try Self.sourceLines()
    let importers = Set(lines.filter { $0.line == "import CoreAudio" }.map(\.file))
    #expect(!importers.isEmpty)
    #expect(importers.allSatisfy { $0.hasPrefix("SoundPingKit/Audio/") }, "\(importers.sorted())")
    // The real-time file stays free of anything that suspends, spawns work or logs.
    let cycle = lines.filter { $0.file == "SoundPingKit/Audio/IOCycle.swift" }.map(\.line)
    for forbidden in [
      "print(", "await ", "async ", "Task {", "Task(", "DispatchQueue", "NSLock", ".withLock",
    ] {
      #expect(!cycle.contains { $0.contains(forbidden) }, "IOCycle.swift contains '\(forbidden)'")
    }
  }
}
