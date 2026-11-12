import CoreAudio
import Foundation
import Testing

@testable import SoundPingKit

/// A hand-built AudioBufferList with interleaved Float32 buffers, like the one the HAL passes to
/// an IOProc. Owns its memory.
private final class SyntheticBuffers {
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

private func timeStamp(sample: Double, host: UInt64 = 0, rate: Double = 1) -> AudioTimeStamp {
  var stamp = AudioTimeStamp()
  stamp.mSampleTime = sample
  stamp.mHostTime = host
  stamp.mRateScalar = rate
  stamp.mFlags = [.sampleTimeValid, .hostTimeValid, .rateScalarValid]
  return stamp
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
    channels: channels, deviceLatency: 0, streamLatencies: Array(repeating: 0, count: streams.count),
    safetyOffset: 0, bufferFrameSize: 16, bufferFrameSizeRange: FrameSizeRange(min: 16, max: 4096))
}

@Suite struct IOCycleTests {
  /// Output: stereo stream then a 4-channel stream (channels 1-2 | 3-6). Input: stereo then 4 channels.
  private static let outScope = scope(streams: [2, 4])
  private static let inScope = scope(streams: [2, 4])

  private static func makeState(
    outChannels: [Int] = [4, 5], inChannel: Int = 6, templates: [[Float]] = [[1, 2, 3, 4, 5, 6, 7, 8]],
    sampleRate: Double = 48_000, captureSeconds: Double = 8
  ) throws -> RTState {
    RTState(
      RTState.Configuration(
        sampleRate: sampleRate, captureSeconds: captureSeconds,
        inputSlot: ChannelSlot.slot(forChannel: inChannel, in: inScope),
        outputSlots: try outChannels.map {
          try #require(ChannelSlot.slot(forChannel: $0, in: outScope))
        },
        templates: templates, scheduleCapacity: 16, stampCapacity: 64))
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
    var time = timeStamp(sample: 1000)

    ioCycleOutput(rt, out.pointer, &time, isOutputDevice: true)

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
    var t1 = timeStamp(sample: 1000)
    var t2 = timeStamp(sample: 1016)

    ioCycleOutput(rt, first.pointer, &t1, isOutputDevice: true)
    ioCycleOutput(rt, second.pointer, &t2, isOutputDevice: true)

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
    var t1 = timeStamp(sample: 1000)
    ioCycleOutput(rt, out.pointer, &t1, isOutputDevice: true)
    // Frame 1004 carries hit 0's third sample (3) and hit 1's first (1).
    #expect(out.sample(buffer: 0, frame: 4, channel: 0) == 4)
    #expect(rt.scheduleCursor.load(ordering: .relaxed) == 0)

    let later = SyntheticBuffers(widths: [2, 4], frames: 16)
    var t2 = timeStamp(sample: 1016)
    ioCycleOutput(rt, later.pointer, &t2, isOutputDevice: true)
    #expect(rt.scheduleCursor.load(ordering: .relaxed) == 2)
  }

  @Test func aDeviceThatIsNotTheOutputDeviceIsOnlySilenced() throws {
    let rt = try Self.makeState(outChannels: [1])
    try rt.append([Self.entry(at: 1000, gain: 1)])
    let out = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 9)
    var time = timeStamp(sample: 1000)

    ioCycleOutput(rt, out.pointer, &time, isOutputDevice: false)

    for frame in 0..<16 {
      #expect(out.sample(buffer: 0, frame: frame, channel: 0) == 0)
      #expect(out.sample(buffer: 1, frame: frame, channel: 3) == 0)
    }
    #expect(rt.outputStamps.count == 0)
    let started = rt.outputStarted.load(ordering: .relaxed)
    #expect(!started)
  }

  @Test func outputStampsAreLoggedWithTheirTimes() throws {
    let rt = try Self.makeState()
    let out = SyntheticBuffers(widths: [2, 4], frames: 16)
    var t1 = timeStamp(sample: 2000, host: 777, rate: 1.00002)
    var t2 = timeStamp(sample: 2016, host: 888, rate: 1.00003)
    ioCycleOutput(rt, out.pointer, &t1, isOutputDevice: true)
    ioCycleOutput(rt, out.pointer, &t2, isOutputDevice: true)

    #expect(rt.outputStamps.count == 2)
    let secondPoint = rt.outputStamps.point(at: 1)
    let second = try #require(secondPoint)
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
      for frame in 0..<16 { input.set(buffer: 1, frame: frame, channel: 3, to: Float(start + frame)) }
      var time = timeStamp(sample: Double(start), host: UInt64(start) * 10, rate: 0.99998)
      ioCycleInput(rt, input.pointer, &time)
    }

    let captured = try rt.readCapture(5000..<5032)
    #expect(captured == (5000..<5032).map { Float($0) })
    #expect(rt.inputFirstLabel.load(ordering: .relaxed) == 5000)
    #expect(rt.inputNextLabel.load(ordering: .relaxed) == 5032)
    #expect(rt.gapCount.load(ordering: .relaxed) == 0)

    // Reading a middle slice, and the stamps that overlap it.
    #expect(try rt.readCapture(5010..<5020) == (5010..<5020).map { Float($0) })
    let stamps = rt.callbackStamps(covering: 5010..<5020)
    #expect(stamps.map(\.inputSampleTime) == [5000, 5016])
    #expect(stamps.allSatisfy { $0.frames == 16 })
  }

  @Test func inputStampsAreLogged() throws {
    let rt = try Self.makeState()
    let input = SyntheticBuffers(widths: [2, 4], frames: 16)
    var t1 = timeStamp(sample: 100, host: 12_345, rate: 0.99999)
    ioCycleInput(rt, input.pointer, &t1)

    #expect(rt.inputStamps.count == 1)
    let firstPoint = rt.inputStamps.point(at: 0)
    let point = try #require(firstPoint)
    #expect(point.sampleTime == 100 && point.hostTime == 12_345)
    #expect(point.rateScalar == 0.99999 && point.frames == 16)
    #expect(rt.stampLog().input == [point])
  }

  @Test func aSixtyFourFrameJumpOfTheLabelSetsTheGapFlagAndLeavesSilence() throws {
    let rt = try Self.makeState()
    let loud = SyntheticBuffers(widths: [2, 4], frames: 16, fill: 0.25)
    var t1 = timeStamp(sample: 5000)
    var t2 = timeStamp(sample: 5080)  // 5016 + 64: the next callback arrives 64 frames late
    ioCycleInput(rt, loud.pointer, &t1)
    #expect(rt.gapCount.load(ordering: .relaxed) == 0)
    ioCycleInput(rt, loud.pointer, &t2)

    #expect(rt.gapCount.load(ordering: .relaxed) == 1)
    #expect(rt.lastGapLabel.load(ordering: .relaxed) == 5016)
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
      var t1 = timeStamp(sample: 9000)
      var t2 = timeStamp(sample: 9016 + offset)
      ioCycleInput(rt, input.pointer, &t1)
      ioCycleInput(rt, input.pointer, &t2)
      #expect(rt.gapCount.load(ordering: .relaxed) == gaps, "offset \(offset)")
    }
  }

  @Test func theCaptureRingWrapsAndRefusesFramesItNoLongerHolds() throws {
    // 0.1 s at 1000 Hz: a 100-frame ring.
    let rt = try Self.makeState(sampleRate: 1_000, captureSeconds: 0.1)
    #expect(rt.captureCapacity == 100)
    for start in stride(from: 0, to: 240, by: 16) {
      let input = SyntheticBuffers(widths: [2, 4], frames: 16)
      for frame in 0..<16 { input.set(buffer: 1, frame: frame, channel: 3, to: Float(start + frame)) }
      var time = timeStamp(sample: Double(start))
      ioCycleInput(rt, input.pointer, &time)
    }
    // 15 callbacks of 16 frames: 240 captured. The newest 100 are still there.
    #expect(try rt.readCapture(200..<240) == (200..<240).map { Float($0) })
    #expect(throws: SoundPingError.self) { _ = try rt.readCapture(100..<140) }
    #expect(throws: SoundPingError.self) { _ = try rt.readCapture(230..<250) }
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
    for forbidden in ["print(", "await ", "async ", "Task {", "Task(", "DispatchQueue", "NSLock", ".withLock"] {
      #expect(!cycle.contains { $0.contains(forbidden) }, "IOCycle.swift contains '\(forbidden)'")
    }
  }
}
