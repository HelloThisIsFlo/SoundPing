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

/// One audio callback's timestamps: the input side and the output side it carried. A side the
/// callback did not have (a device without that direction, a skipped or untimestamped buffer) is nil.
struct StampEntry: Sendable, Equatable {
  var input: TimelinePoint?
  var output: TimelinePoint?
}

/// A fixed-size ring of callback timestamps, one entry per callback. An entry holds both directions
/// of that callback, so a duplex device's input and output stamps can only ever be paired with each
/// other (WR-03): a side that was skipped leaves its half of the entry empty and shifts nothing.
/// One writer (the IOProc of the device that owns the ring), any number of readers; the count is
/// published with a releasing store after the entry is written. Before it touches a slot the writer
/// also announces the write (`started`, then a release fence), so a reader that copied a slot can
/// tell afterwards whether a write may have been overwriting it and drop that copy (IN-16, the same
/// guard `readCapture` has). The columns come from `calloc`, so
/// pages nobody touched stay virtual: a ring sized for hours costs memory only for the callbacks
/// that actually happened. A noncopyable struct stored inline in `RTState`, so the audio thread
/// reaches it without reference counting.
struct StampRing: ~Copyable, Sendable {
  let capacity: Int
  // Eight columns, input side first. A side with zero frames is absent.
  nonisolated(unsafe) private let inputSampleTimes: UnsafeMutablePointer<Double>
  nonisolated(unsafe) private let inputHostTimes: UnsafeMutablePointer<UInt64>
  nonisolated(unsafe) private let inputRateScalars: UnsafeMutablePointer<Double>
  nonisolated(unsafe) private let inputFrameCounts: UnsafeMutablePointer<Int>
  nonisolated(unsafe) private let outputSampleTimes: UnsafeMutablePointer<Double>
  nonisolated(unsafe) private let outputHostTimes: UnsafeMutablePointer<UInt64>
  nonisolated(unsafe) private let outputRateScalars: UnsafeMutablePointer<Double>
  nonisolated(unsafe) private let outputFrameCounts: UnsafeMutablePointer<Int>
  private let written = Atomic<Int>(0)
  /// Writes begun so far: `written`, or one more while the writer is filling a slot.
  private let started = Atomic<Int>(0)

  init(capacity: Int) {
    self.capacity = Swift.max(1, capacity)
    let n = self.capacity
    inputSampleTimes = Self.zeroed(Double.self, n)
    inputHostTimes = Self.zeroed(UInt64.self, n)
    inputRateScalars = Self.zeroed(Double.self, n)
    inputFrameCounts = Self.zeroed(Int.self, n)
    outputSampleTimes = Self.zeroed(Double.self, n)
    outputHostTimes = Self.zeroed(UInt64.self, n)
    outputRateScalars = Self.zeroed(Double.self, n)
    outputFrameCounts = Self.zeroed(Int.self, n)
  }

  deinit {
    free(inputSampleTimes)
    free(inputHostTimes)
    free(inputRateScalars)
    free(inputFrameCounts)
    free(outputSampleTimes)
    free(outputHostTimes)
    free(outputRateScalars)
    free(outputFrameCounts)
  }

  private static func zeroed<T>(_ type: T.Type, _ count: Int) -> UnsafeMutablePointer<T> {
    calloc(count, MemoryLayout<T>.stride)!.bindMemory(to: T.self, capacity: count)
  }

  /// Callbacks logged so far (not capped by the capacity).
  var count: Int { written.load(ordering: .acquiring) }

  /// Real-time side. No allocation, no locks. An entry with neither side is not written.
  @_noLocks
  func append(input: StampSide, output: StampSide) {
    if input.frames <= 0, output.frames <= 0 { return }
    let n = written.load(ordering: .relaxed)
    let i = n % capacity
    started.store(n + 1, ordering: .releasing)
    atomicMemoryFence(ordering: .releasing)
    inputSampleTimes[i] = input.sampleTime
    inputHostTimes[i] = input.hostTime
    inputRateScalars[i] = input.rateScalar
    inputFrameCounts[i] = input.frames > 0 ? input.frames : 0
    outputSampleTimes[i] = output.sampleTime
    outputHostTimes[i] = output.hostTime
    outputRateScalars[i] = output.rateScalar
    outputFrameCounts[i] = output.frames > 0 ? output.frames : 0
    written.store(n + 1, ordering: .releasing)
  }

  private func read(slot i: Int) -> StampEntry {
    var entry = StampEntry()
    if inputFrameCounts[i] > 0 {
      entry.input = TimelinePoint(
        sampleTime: inputSampleTimes[i], hostTime: inputHostTimes[i],
        rateScalar: inputRateScalars[i], frames: inputFrameCounts[i])
    }
    if outputFrameCounts[i] > 0 {
      entry.output = TimelinePoint(
        sampleTime: outputSampleTimes[i], hostTime: outputHostTimes[i],
        rateScalar: outputRateScalars[i], frames: outputFrameCounts[i])
    }
    return entry
  }

  /// The oldest ordinal no write had begun to overwrite by the time a copy finished. Called after
  /// the copy: the fence orders the copy's reads before the load of `started`.
  private func oldestIntactOrdinal() -> Int {
    atomicMemoryFence(ordering: .acquiring)
    return started.load(ordering: .acquiring) - capacity
  }

  /// The entry with this absolute ordinal, nil once the ring has overwritten it (or was
  /// overwriting it while it was read).
  func entry(at ordinal: Int) -> StampEntry? {
    let n = written.load(ordering: .acquiring)
    guard ordinal >= 0, ordinal < n, n - ordinal <= capacity else { return nil }
    let entry = read(slot: ordinal % capacity)
    guard ordinal >= oldestIntactOrdinal() else { return nil }
    return entry
  }

  /// Every entry still in the ring, oldest first. A slot the writer may have been overwriting while
  /// it was copied is dropped rather than returned torn.
  func snapshot() -> [StampEntry] {
    let n = written.load(ordering: .acquiring)
    let first = Swift.max(0, n - capacity)
    var entries: [StampEntry] = []
    entries.reserveCapacity(n - first)
    for ordinal in first..<n { entries.append(read(slot: ordinal % capacity)) }
    let intact = Swift.min(n, Swift.max(first, oldestIntactOrdinal()))
    return Array(entries[(intact - first)...])
  }
}

/// A fixed-size ring of fault intervals, each a range of sample labels of one direction and a cause
/// code. Same discipline as `StampRing`: one writer, preallocated, never resized, the count
/// published with a releasing store after the entry, and a write announced before it touches a
/// slot. Entries are appended in the order the writer found them, never merged: two glitches stay
/// two intervals (WR-01).
///
/// Before the writer overwrites a slot it folds that interval's upper bound into `forgottenUpper`
/// (a running maximum), so a reader knows the whole stretch below it is no longer described, even
/// when an old interval ends above the lower bound of everything still retained (IN-16).
struct FaultRing: ~Copyable, Sendable {
  let capacity: Int
  nonisolated(unsafe) private let lowers: UnsafeMutablePointer<Int>
  nonisolated(unsafe) private let uppers: UnsafeMutablePointer<Int>
  nonisolated(unsafe) private let causes: UnsafeMutablePointer<Int>
  private let written = Atomic<Int>(0)
  /// Writes begun so far: `written`, or one more while the writer is filling a slot.
  private let started = Atomic<Int>(0)
  /// The highest upper bound of any interval the ring has overwritten; `Int.min` until it wraps.
  private let forgottenUpper = Atomic<Int>(Int.min)

  init(capacity: Int) {
    self.capacity = Swift.max(1, capacity)
    lowers = .allocate(capacity: self.capacity)
    lowers.initialize(repeating: 0, count: self.capacity)
    uppers = .allocate(capacity: self.capacity)
    uppers.initialize(repeating: 0, count: self.capacity)
    causes = .allocate(capacity: self.capacity)
    causes.initialize(repeating: 0, count: self.capacity)
  }

  deinit {
    lowers.deallocate()
    uppers.deallocate()
    causes.deallocate()
  }

  /// Faults recorded so far (not capped by the capacity).
  var count: Int { written.load(ordering: .acquiring) }

  /// Real-time side. No allocation, no locks. Callers pass `upper > lower`.
  @_noLocks
  func append(lower: Int, upper: Int, cause: Int) {
    let n = written.load(ordering: .relaxed)
    let i = n % capacity
    if n >= capacity {
      // One writer: a plain load and store keep the running maximum; `started` publishes it.
      let old = uppers[i]
      if old > forgottenUpper.load(ordering: .relaxed) {
        forgottenUpper.store(old, ordering: .relaxed)
      }
    }
    started.store(n + 1, ordering: .releasing)
    atomicMemoryFence(ordering: .releasing)
    lowers[i] = lower
    uppers[i] = upper
    causes[i] = cause
    written.store(n + 1, ordering: .releasing)
  }

  /// Every retained fault, oldest first, and the upper bound of the stretch the ring no longer
  /// describes (nil while nothing was overwritten). A slot the writer may have been overwriting
  /// while it was copied is dropped; its interval's upper bound is already folded into the
  /// forgotten bound by then, so dropping it fails safe.
  func retained() -> (entries: [(lower: Int, upper: Int, cause: Int)], forgottenUpper: Int?) {
    let n = written.load(ordering: .acquiring)
    let first = Swift.max(0, n - capacity)
    var entries: [(lower: Int, upper: Int, cause: Int)] = []
    entries.reserveCapacity(n - first)
    for ordinal in first..<n {
      let i = ordinal % capacity
      entries.append((lowers[i], uppers[i], causes[i]))
    }
    atomicMemoryFence(ordering: .acquiring)
    let begun = started.load(ordering: .acquiring)
    let forgotten = forgottenUpper.load(ordering: .relaxed)
    let intact = Swift.min(n, Swift.max(first, begun - capacity))
    return (Array(entries[(intact - first)...]), forgotten == Int.min ? nil : forgotten)
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
    /// Callbacks one stamp ring holds. 2^21 callbacks is days of audio at any real buffer size. The
    /// columns are `calloc`'d, so pages nobody touched stay virtual: raising this is not the fix for
    /// a wrapped ring. The clock self-test judges only hits inside the callbacks still logged (WR-03).
    var stampCapacity = 1 << 21
    /// One device plays and captures (a duplex interface): its callbacks carry both directions in
    /// one ring entry. False when an input device and a separate output device each write a ring.
    var sharedDevice = true
    /// Fault intervals each of the four fault rings holds. A ring that wraps answers queries below
    /// its oldest entry with a `logOverwritten` fault, so overflow rejects hits instead of passing them.
    var faultCapacity = 4096
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

  // MARK: Output

  let outputNextLabel = Atomic<Int>(0)
  let outputStarted = Atomic<Bool>(false)

  // MARK: Clock resets

  /// Set by the IOProc when a direction's sample time went backwards, as after an IO restart that
  /// reset the device clock (IN-17). Labels never fall: the lower label is not published, nothing
  /// more is captured or mixed in that direction, and the engine ends the run as a device change.
  let inputClockWentBack = Atomic<Bool>(false)
  let outputClockWentBack = Atomic<Bool>(false)
  let outputSlotCount: Int
  nonisolated(unsafe) let outputSlots: UnsafeMutablePointer<ChannelSlot>

  // MARK: Stamps, one ring per device that writes them

  /// Written by the capturing device's IOProc. On a shared (duplex) device it is the only ring and
  /// each entry carries both directions of that callback.
  let inputDeviceStamps: StampRing
  /// Written only by a separate output device on a two-device run; its entries carry the output side.
  let outputDeviceStamps: StampRing
  let sharedDevice: Bool

  // MARK: Faults, one single-writer ring per direction and per writer

  /// Written by the IOProc of the input direction: lost frames and untimestamped input callbacks.
  let inputFaults: FaultRing
  /// Written by the IOProc of the output direction. On a shared device the same IOProc writes this
  /// ring and `inputFaults`, which is fine: each ring has exactly one writer thread.
  let outputFaults: FaultRing
  /// Written only from `DeviceListeners`' serial queue, by `noteOverload`.
  let inputOverloads: FaultRing
  let outputOverloads: FaultRing

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

    sharedDevice = configuration.sharedDevice
    inputDeviceStamps = StampRing(capacity: configuration.stampCapacity)
    // On a shared device nothing writes the second ring, so it stays minimal.
    outputDeviceStamps = StampRing(
      capacity: configuration.sharedDevice ? 1 : configuration.stampCapacity)
    inputFaults = FaultRing(capacity: configuration.faultCapacity)
    outputFaults = FaultRing(capacity: configuration.faultCapacity)
    inputOverloads = FaultRing(capacity: configuration.faultCapacity)
    outputOverloads = FaultRing(capacity: configuration.faultCapacity)

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
  /// side of the same ring entry, which on a duplex device is the same callback, and are 0 when the
  /// entry has none (two devices, or a skipped output). An output stamp is never looked up by
  /// ordinal in another ring: ordinals of two devices' callbacks do not correspond (WR-03).
  ///
  /// An entry without an input side is skipped, so the sample times of the stamps returned jump
  /// across it and the correlator rejects the window.
  func callbackStamps(covering range: Range<Int64>) -> [CallbackStamp] {
    let n = inputDeviceStamps.count
    var found: [CallbackStamp] = []
    var ordinal = n - 1
    while ordinal >= 0, let entry = inputDeviceStamps.entry(at: ordinal) {
      ordinal -= 1
      guard let input = entry.input else { continue }
      let end = input.sampleTime + Double(input.frames)
      if end <= Double(range.lowerBound) { break }
      if input.sampleTime < Double(range.upperBound) {
        let output = entry.output
        found.append(
          CallbackStamp(
            inputSampleTime: input.sampleTime, inputHostTime: input.hostTime,
            inputRateScalar: input.rateScalar,
            outputSampleTime: output?.sampleTime ?? 0, outputHostTime: output?.hostTime ?? 0,
            outputRateScalar: output?.rateScalar ?? 0, frames: input.frames))
      }
    }
    return found.reversed()
  }

  /// Every logged callback, per direction. Each ring is read once, so both lists come from the
  /// same instant. `ioOffsetFrames` is built from single ring entries that hold both sides, never
  /// by pairing the two lists.
  func stampLog() -> StampLog {
    let inputEntries = inputDeviceStamps.snapshot()
    let outputEntries = sharedDevice ? inputEntries : outputDeviceStamps.snapshot()
    var offsets: [Double] = []
    if sharedDevice {
      for entry in inputEntries {
        if let input = entry.input, let output = entry.output {
          offsets.append(output.sampleTime - input.sampleTime)
        }
      }
    }
    return StampLog(
      input: inputEntries.compactMap(\.input), output: outputEntries.compactMap(\.output),
      ioOffsetFrames: offsets)
  }

  // MARK: Faults

  /// Records an HAL processor-overload notification as an interval of `onInput`'s and/or
  /// `onOutput`'s label space: `lookbackFrames` before the direction's next label (the buffer the
  /// notification is about, plus the latency of the notification itself) up to the end of the
  /// buffer in flight, `bufferFrames` after it. An output device's overload lands in output labels,
  /// never on the input position (WR-01).
  ///
  /// May only be called from the listeners' serial queue: the two overload rings have that queue as
  /// their single writer.
  func noteOverload(onInput: Bool, onOutput: Bool, lookbackFrames: Int, bufferFrames: Int) {
    if onInput {
      let next = inputNextLabel.load(ordering: .acquiring)
      inputOverloads.append(
        lower: next - lookbackFrames, upper: next + Swift.max(1, bufferFrames),
        cause: faultOverloadCode)
    }
    if onOutput {
      let next = outputNextLabel.load(ordering: .acquiring)
      outputOverloads.append(
        lower: next - lookbackFrames, upper: next + Swift.max(1, bufferFrames),
        cause: faultOverloadCode)
    }
  }

  /// Every recorded fault that overlaps `input` (input faults) or `output` (output faults).
  ///
  /// The labels are loaded first, with acquiring loads: the IOProc appends a fault before the label
  /// store that follows it, so every fault below those labels is visible by the time the rings are
  /// read. Intervals are tested for overlap, not containment, and never merged.
  ///
  /// A ring that has overwritten old entries no longer knows what happened below the highest upper
  /// bound it overwrote. The part of a query below that bound gets one `logOverwritten` fault, so
  /// overflow rejects a hit instead of letting it through (IN-16).
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) -> [FaultInterval] {
    _ = inputNextLabel.load(ordering: .acquiring)
    _ = outputNextLabel.load(ordering: .acquiring)
    var found = Self.scan(
      inputFaults, inputOverloads, direction: .input, overlapping: input)
    found += Self.scan(
      outputFaults, outputOverloads, direction: .output, overlapping: output)
    return found
  }

  private static func scan(
    _ writtenByIOProc: borrowing FaultRing, _ writtenByListeners: borrowing FaultRing,
    direction: FaultInterval.Direction, overlapping query: Range<Int64>
  ) -> [FaultInterval] {
    guard !query.isEmpty else { return [] }
    var found: [FaultInterval] = []
    var forgottenBelow: Int64?
    let first = writtenByIOProc.retained()
    let second = writtenByListeners.retained()
    for (entries, forgotten) in [
      (first.entries, first.forgottenUpper), (second.entries, second.forgottenUpper),
    ] {
      for entry in entries {
        let range = Int64(entry.lower)..<Int64(Swift.max(entry.upper, entry.lower + 1))
        guard range.lowerBound < query.upperBound, range.upperBound > query.lowerBound else {
          continue
        }
        let cause: FaultInterval.Cause
        switch entry.cause {
        case faultLostFramesCode: cause = .lostFrames
        case faultInvalidTimestampCode: cause = .invalidTimestamp
        default: cause = .overload
        }
        found.append(FaultInterval(direction: direction, frames: range, cause: cause))
      }
      if let forgotten {
        forgottenBelow = Swift.max(forgottenBelow ?? Int64(forgotten), Int64(forgotten))
      }
    }
    if let forgottenBelow, query.lowerBound < forgottenBelow {
      let end = Swift.min(query.upperBound, forgottenBelow)
      found.append(
        FaultInterval(
          direction: direction, frames: query.lowerBound..<end, cause: .logOverwritten))
    }
    return found
  }
}
