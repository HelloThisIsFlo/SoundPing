import CoreAudio
import Foundation
import Synchronization

/// Where one channel sits in a device's buffer list: which buffer (stream), which channel inside
/// it, and how many channels that buffer interleaves. Channel numbers in a setup count across the
/// whole list (D-11); the IOProc needs the buffer position.
struct ChannelSlot: Sendable, Equatable {
  var buffer: Int
  /// 0-based inside the buffer.
  var channelInBuffer: Int
  var channelsInBuffer: Int

  /// nil when the scope has no such channel.
  static func slot(forChannel channel: Int, in scope: ScopeInfo) -> ChannelSlot? {
    guard let info = scope.channels.first(where: { $0.index == channel }) else { return nil }
    let width = scope.channels.filter { $0.streamIndex == info.streamIndex }.count
    return ChannelSlot(
      buffer: info.streamIndex, channelInBuffer: info.channelInStream - 1, channelsInBuffer: width)
  }
}

/// One hit in the schedule ring: plain old data, so the IOProc reads it without touching memory
/// management.
struct ScheduleEntry: Sendable {
  var outputFrame: Int
  var gain: Float
  var template: Int
  var hitIndex: Int
}

/// A fixed-size ring of callback timestamps for one direction of one device. One writer (that
/// direction's IOProc), any number of readers; the count is published with a releasing store after
/// the entry is written. The columns come from `calloc`, so pages nobody touched stay virtual: a
/// ring sized for hours costs memory only for the callbacks that actually happened. A noncopyable
/// struct stored inline in `RTState`, so the audio thread reaches it without reference counting.
struct StampRing: ~Copyable, Sendable {
  let capacity: Int
  nonisolated(unsafe) private let sampleTimes: UnsafeMutablePointer<Double>
  nonisolated(unsafe) private let hostTimes: UnsafeMutablePointer<UInt64>
  nonisolated(unsafe) private let rateScalars: UnsafeMutablePointer<Double>
  nonisolated(unsafe) private let frameCounts: UnsafeMutablePointer<Int>
  private let written = Atomic<Int>(0)

  init(capacity: Int) {
    self.capacity = capacity
    sampleTimes = Self.zeroed(Double.self, capacity)
    hostTimes = Self.zeroed(UInt64.self, capacity)
    rateScalars = Self.zeroed(Double.self, capacity)
    frameCounts = Self.zeroed(Int.self, capacity)
  }

  deinit {
    free(sampleTimes)
    free(hostTimes)
    free(rateScalars)
    free(frameCounts)
  }

  private static func zeroed<T>(_ type: T.Type, _ count: Int) -> UnsafeMutablePointer<T> {
    calloc(count, MemoryLayout<T>.stride)!.bindMemory(to: T.self, capacity: count)
  }

  /// Callbacks logged so far (not capped by the capacity).
  var count: Int { written.load(ordering: .acquiring) }

  /// Real-time side. No allocation, no locks.
  @_noLocks
  func append(sampleTime: Double, hostTime: UInt64, rateScalar: Double, frames: Int) {
    let n = written.load(ordering: .relaxed)
    let i = n % capacity
    sampleTimes[i] = sampleTime
    hostTimes[i] = hostTime
    rateScalars[i] = rateScalar
    frameCounts[i] = frames
    written.store(n + 1, ordering: .releasing)
  }

  /// The entry with this absolute ordinal, nil once the ring has overwritten it.
  func point(at ordinal: Int) -> TimelinePoint? {
    let n = written.load(ordering: .acquiring)
    guard ordinal >= 0, ordinal < n, n - ordinal <= capacity else { return nil }
    let i = ordinal % capacity
    return TimelinePoint(
      sampleTime: sampleTimes[i], hostTime: hostTimes[i], rateScalar: rateScalars[i],
      frames: frameCounts[i])
  }

  /// Every entry still in the ring, oldest first.
  func snapshot() -> [TimelinePoint] {
    let n = written.load(ordering: .acquiring)
    let first = Swift.max(0, n - capacity)
    var points: [TimelinePoint] = []
    points.reserveCapacity(n - first)
    for ordinal in first..<n {
      let i = ordinal % capacity
      points.append(
        TimelinePoint(
          sampleTime: sampleTimes[i], hostTime: hostTimes[i], rateScalar: rateScalars[i],
          frames: frameCounts[i]))
    }
    return points
  }
}

/// Everything the audio thread and the engine share, allocated once before the device starts and
/// never resized. The IOProc only writes capture data, stamps and its own cursors, with releasing
/// stores; the engine only reads them with acquiring loads and appends to the schedule ring.
/// Nothing here is a lock (T-01-23).
final class RTState: Sendable {
  struct Configuration {
    var sampleRate: Double
    var captureSeconds: Double = 8
    var inputSlot: ChannelSlot?
    var outputSlots: [ChannelSlot]
    /// Sample buffers of the stimulus templates at the device rate, indexed by `ScheduleEntry.template`.
    var templates: [[Float]]
    var scheduleCapacity = 32_768
    var stampCapacity = 1 << 21
  }

  // MARK: Layout of an AudioBufferList (computed once, read by the IOProc)

  let bufferListHeader: Int
  let bufferStride: Int

  // MARK: Capture ring (mono, indexed by input sample label)

  let hasInput: Bool
  let inputSlot: ChannelSlot
  let captureCapacity: Int
  nonisolated(unsafe) let capture: UnsafeMutablePointer<Float>
  /// Label of the first captured frame; constant once `inputStarted`.
  let inputFirstLabel = Atomic<Int>(0)
  /// Label of the next frame to be captured.
  let inputNextLabel = Atomic<Int>(0)
  let inputStarted = Atomic<Bool>(false)
  /// Sample-time discontinuities seen so far, and where the latest one began (the first missing label).
  let gapCount = Atomic<Int>(0)
  let lastGapLabel = Atomic<Int>(0)

  // MARK: Output

  let outputNextLabel = Atomic<Int>(0)
  let outputStarted = Atomic<Bool>(false)
  let outputSlotCount: Int
  nonisolated(unsafe) let outputSlots: UnsafeMutablePointer<ChannelSlot>

  // MARK: Stamps, one ring per direction

  let inputStamps: StampRing
  let outputStamps: StampRing

  // MARK: Schedule ring (single producer: the engine; single consumer: the IOProc)

  let scheduleCapacity: Int
  nonisolated(unsafe) let schedule: UnsafeMutablePointer<ScheduleEntry>
  let scheduleCount = Atomic<Int>(0)
  /// First entry the IOProc may still have to mix; entries before it have finished playing.
  let scheduleCursor = Atomic<Int>(0)

  // MARK: Templates (copied in once)

  let templateCount: Int
  nonisolated(unsafe) let templateData: UnsafeMutablePointer<Float>
  nonisolated(unsafe) let templateOffsets: UnsafeMutablePointer<Int>
  nonisolated(unsafe) let templateLengths: UnsafeMutablePointer<Int>

  init(_ configuration: Configuration) {
    bufferListHeader = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) ?? 8
    bufferStride = MemoryLayout<AudioBuffer>.stride

    hasInput = configuration.inputSlot != nil
    inputSlot =
      configuration.inputSlot ?? ChannelSlot(buffer: 0, channelInBuffer: 0, channelsInBuffer: 1)
    captureCapacity = Swift.max(1, Int(configuration.sampleRate * configuration.captureSeconds))
    capture = .allocate(capacity: captureCapacity)
    capture.initialize(repeating: 0, count: captureCapacity)

    outputSlotCount = configuration.outputSlots.count
    outputSlots = .allocate(capacity: Swift.max(1, outputSlotCount))
    outputSlots.initialize(
      repeating: ChannelSlot(buffer: 0, channelInBuffer: 0, channelsInBuffer: 1),
      count: Swift.max(1, outputSlotCount))
    for (i, slot) in configuration.outputSlots.enumerated() { outputSlots[i] = slot }

    inputStamps = StampRing(capacity: configuration.stampCapacity)
    outputStamps = StampRing(capacity: configuration.stampCapacity)

    scheduleCapacity = configuration.scheduleCapacity
    schedule = .allocate(capacity: scheduleCapacity)
    schedule.initialize(
      repeating: ScheduleEntry(outputFrame: 0, gain: 0, template: 0, hitIndex: 0),
      count: scheduleCapacity)

    templateCount = configuration.templates.count
    let total = configuration.templates.reduce(0) { $0 + $1.count }
    templateData = .allocate(capacity: Swift.max(1, total))
    templateData.initialize(repeating: 0, count: Swift.max(1, total))
    templateOffsets = .allocate(capacity: Swift.max(1, templateCount))
    templateOffsets.initialize(repeating: 0, count: Swift.max(1, templateCount))
    templateLengths = .allocate(capacity: Swift.max(1, templateCount))
    templateLengths.initialize(repeating: 0, count: Swift.max(1, templateCount))
    var offset = 0
    for (i, samples) in configuration.templates.enumerated() {
      templateOffsets[i] = offset
      templateLengths[i] = samples.count
      for (j, value) in samples.enumerated() { templateData[offset + j] = value }
      offset += samples.count
    }
  }

  deinit {
    capture.deallocate()
    outputSlots.deallocate()
    schedule.deallocate()
    templateData.deallocate()
    templateOffsets.deallocate()
    templateLengths.deallocate()
  }

  // MARK: Engine side (allocation allowed; never called from the IOProc)

  /// Appends hits, ascending by output frame. The IOProc reads them in order, so a hit earlier than
  /// one already scheduled would be skipped; that is refused, not reordered.
  func append(_ hits: [ScheduleEntry]) throws {
    let sorted = hits.sorted { $0.outputFrame < $1.outputFrame }
    let used = scheduleCount.load(ordering: .relaxed)
    guard used + sorted.count <= scheduleCapacity else {
      throw SoundPingError.internalFailure(
        "scheduleFull",
        "the schedule ring holds \(scheduleCapacity) hits; \(used) are in it and \(sorted.count) more were asked for"
      )
    }
    if let first = sorted.first, used > 0, first.outputFrame < schedule[used - 1].outputFrame {
      throw SoundPingError.internalFailure(
        "scheduleOutOfOrder",
        "hit \(first.hitIndex) at output frame \(first.outputFrame) is earlier than one already scheduled"
      )
    }
    for (i, entry) in sorted.enumerated() {
      guard entry.template >= 0, entry.template < templateCount else {
        throw SoundPingError.internalFailure(
          "unknownTemplate", "hit \(entry.hitIndex) uses template slot \(entry.template)")
      }
      schedule[used + i] = entry
    }
    scheduleCount.store(used + sorted.count, ordering: .releasing)
  }

  /// The captured frames of `range`, in order. Frames before the first callback read as silence.
  func readCapture(_ range: Range<Int64>) throws -> [Float] {
    guard hasInput, inputStarted.load(ordering: .acquiring) else {
      throw SoundPingError.internalFailure("captureNotStarted", "no input audio has arrived yet")
    }
    let next = inputNextLabel.load(ordering: .acquiring)
    let first = inputFirstLabel.load(ordering: .relaxed)
    guard range.upperBound <= Int64(next) else {
      throw SoundPingError.internalFailure(
        "captureBeyondProcessed",
        "frames \(range) are not captured yet (captured through \(next))")
    }
    guard Int64(next) - range.lowerBound <= Int64(captureCapacity) else {
      throw SoundPingError.internalFailure(
        "captureOverwritten",
        "frames \(range) were overwritten in the capture ring (it holds \(captureCapacity) frames)")
    }
    var out = [Float](repeating: 0, count: Int(range.count))
    for (offset, label) in range.enumerated() where label >= Int64(first) {
      var position = (Int(label) - first) % captureCapacity
      if position < 0 { position += captureCapacity }
      out[offset] = capture[position]
    }
    // The writer may have lapped the reader while it copied; a copy that old is not trustworthy.
    let after = inputNextLabel.load(ordering: .acquiring)
    guard Int64(after) - range.lowerBound <= Int64(captureCapacity) else {
      throw SoundPingError.internalFailure(
        "captureOverwritten", "frames \(range) were overwritten while they were read")
    }
    return out
  }

  /// The input callbacks that overlap `range`, oldest first. Output fields come from the output
  /// callback with the same ordinal, which is the same callback on a duplex device.
  func callbackStamps(covering range: Range<Int64>) -> [CallbackStamp] {
    let n = inputStamps.count
    var found: [CallbackStamp] = []
    var ordinal = n - 1
    while ordinal >= 0, let input = inputStamps.point(at: ordinal) {
      let end = input.sampleTime + Double(input.frames)
      if end <= Double(range.lowerBound) { break }
      if input.sampleTime < Double(range.upperBound) {
        let output = outputStamps.point(at: ordinal)
        found.append(
          CallbackStamp(
            inputSampleTime: input.sampleTime, inputHostTime: input.hostTime,
            inputRateScalar: input.rateScalar,
            outputSampleTime: output?.sampleTime ?? 0, outputHostTime: output?.hostTime ?? 0,
            outputRateScalar: output?.rateScalar ?? 0, frames: input.frames))
      }
      ordinal -= 1
    }
    return found.reversed()
  }

  func stampLog() -> StampLog {
    StampLog(input: inputStamps.snapshot(), output: outputStamps.snapshot())
  }
}
