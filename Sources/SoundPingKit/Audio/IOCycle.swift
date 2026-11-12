import CoreAudio
import Foundation
import Synchronization

// The work one audio callback does. Everything here is reachable from the HAL's real-time thread,
// so every function is `@_noLocks`: the compiler refuses reference counting, allocation and locks
// in them (T-01-23). They use only `RTState`'s preallocated buffers and atomics. Nothing in this
// file logs, suspends, spawns concurrent work or touches a queue.
//
// Buffer sizes are checked against the callback's own buffer list before every write, never
// trusted from the configuration alone (T-01-24): a stream layout that changed under the run
// costs one skipped callback, not a write past a buffer.

/// Bytes per sample: the backend only opens devices whose streams are 32-bit float.
private let bytesPerSample = 4

/// The nearest whole sample label, halves away from zero. `Double.rounded()` is not usable on the
/// audio thread: it needs the rounding-rule metadata, which `@_noLocks` refuses.
@_noLocks
@inline(__always)
private func nearestLabel(_ sampleTime: Double) -> Int {
  sampleTime >= 0 ? Int(sampleTime + 0.5) : -Int(0.5 - sampleTime)
}

/// Captures the selected input channel into the capture ring at its sample label, and logs the
/// callback's input stamp. A label that is not where the previous callback left off (beyond half a
/// frame, compared in Double) counts as a discontinuity: the gap is zero-filled, counted, and
/// remembered for the engine, which rejects every hit whose window touches it (ENG-07).
@_noLocks
func ioCycleInput(
  _ rt: RTState, _ data: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>
) {
  guard rt.hasInput else { return }
  let slot = rt.inputSlot
  let list = UnsafeRawPointer(data)
  guard slot.buffer < Int(list.load(as: UInt32.self)) else { return }
  let buffer = (list + rt.bufferListHeader + slot.buffer * rt.bufferStride).load(
    as: AudioBuffer.self)
  let channels = Int(buffer.mNumberChannels)
  guard channels > 0, channels == slot.channelsInBuffer, let source = buffer.mData else { return }
  let frames = Int(buffer.mDataByteSize) / (channels * bytesPerSample)
  let capacity = rt.captureCapacity
  guard frames > 0, frames <= capacity else { return }

  let sampleTime = time.pointee.mSampleTime
  guard sampleTime.isFinite, abs(sampleTime) < 1e15 else { return }
  let label = nearestLabel(sampleTime)

  var first = rt.inputFirstLabel.load(ordering: .relaxed)
  if !rt.inputStarted.load(ordering: .relaxed) {
    first = label
    rt.inputFirstLabel.store(label, ordering: .relaxed)
  } else {
    let expected = rt.inputNextLabel.load(ordering: .relaxed)
    if abs(sampleTime - Double(expected)) > 0.5 {
      rt.lastGapLabel.store(expected, ordering: .relaxed)
      rt.gapCount.wrappingAdd(1, ordering: .releasing)
      // Frames that never arrived read as silence, not as whatever the ring held a lap ago.
      if label > expected {
        let missing = Swift.min(label - expected, capacity)
        var position = (label - missing - first) % capacity
        if position < 0 { position += capacity }
        var filled = 0
        while filled < missing {
          rt.capture[position] = 0
          position += 1
          if position == capacity { position = 0 }
          filled += 1
        }
      }
    }
  }

  let samples = source.assumingMemoryBound(to: Float.self)
  var position = (label - first) % capacity
  if position < 0 { position += capacity }
  var frame = 0
  while frame < frames {
    rt.capture[position] = samples[frame * channels + slot.channelInBuffer]
    position += 1
    if position == capacity { position = 0 }
    frame += 1
  }

  rt.inputStamps.append(
    sampleTime: sampleTime, hostTime: time.pointee.mHostTime, rateScalar: time.pointee.mRateScalar,
    frames: frames)
  rt.inputNextLabel.store(label + frames, ordering: .releasing)
  rt.inputStarted.store(true, ordering: .releasing)
}

/// Zeroes every output buffer, then (on the output device) logs the output stamp and mixes every
/// scheduled hit that overlaps this callback, template times gain, into the selected output
/// channels. Hits sum where they overlap; every other channel stays silent.
@_noLocks
func ioCycleOutput(
  _ rt: RTState, _ data: UnsafeMutablePointer<AudioBufferList>,
  _ time: UnsafePointer<AudioTimeStamp>, isOutputDevice: Bool
) {
  let list = UnsafeMutableRawPointer(data)
  let bufferCount = Int(list.load(as: UInt32.self))
  var b = 0
  while b < bufferCount {
    let buffer = (list + rt.bufferListHeader + b * rt.bufferStride).load(as: AudioBuffer.self)
    if let memory = buffer.mData {
      let samples = memory.assumingMemoryBound(to: Float.self)
      let count = Int(buffer.mDataByteSize) / bytesPerSample
      var i = 0
      while i < count {
        samples[i] = 0
        i += 1
      }
    }
    b += 1
  }
  guard isOutputDevice, bufferCount > 0 else { return }

  let sampleTime = time.pointee.mSampleTime
  guard sampleTime.isFinite, abs(sampleTime) < 1e15 else { return }
  let label = nearestLabel(sampleTime)

  // The callback length, from the first buffer.
  let head = (list + rt.bufferListHeader).load(as: AudioBuffer.self)
  let headChannels = Int(head.mNumberChannels)
  guard headChannels > 0 else { return }
  let frames = Int(head.mDataByteSize) / (headChannels * bytesPerSample)
  guard frames > 0 else { return }

  rt.outputStamps.append(
    sampleTime: sampleTime, hostTime: time.pointee.mHostTime, rateScalar: time.pointee.mRateScalar,
    frames: frames)
  rt.outputNextLabel.store(label + frames, ordering: .releasing)
  rt.outputStarted.store(true, ordering: .releasing)

  // Entries before the cursor have finished playing. Hits are ascending, so the scan stops at the
  // first one that starts after this callback.
  let count = rt.scheduleCount.load(ordering: .acquiring)
  var cursor = rt.scheduleCursor.load(ordering: .relaxed)
  while cursor < count {
    let entry = rt.schedule[cursor]
    if entry.outputFrame + rt.templateLengths[entry.template] > label { break }
    cursor += 1
  }
  rt.scheduleCursor.store(cursor, ordering: .relaxed)

  var index = cursor
  while index < count {
    let entry = rt.schedule[index]
    index += 1
    if entry.outputFrame >= label + frames { break }
    let length = rt.templateLengths[entry.template]
    let start = Swift.max(entry.outputFrame, label)
    let end = Swift.min(entry.outputFrame + length, label + frames)
    if start >= end { continue }
    let template = rt.templateData + rt.templateOffsets[entry.template]

    var s = 0
    while s < rt.outputSlotCount {
      let slot = rt.outputSlots[s]
      s += 1
      guard slot.buffer < bufferCount else { continue }
      let buffer = (list + rt.bufferListHeader + slot.buffer * rt.bufferStride)
        .load(as: AudioBuffer.self)
      let channels = Int(buffer.mNumberChannels)
      guard channels > 0, channels == slot.channelsInBuffer, let memory = buffer.mData else {
        continue
      }
      let available = Int(buffer.mDataByteSize) / (channels * bytesPerSample)
      let destination = memory.assumingMemoryBound(to: Float.self)
      var x = start
      while x < end {
        let frame = x - label
        if frame < available {
          destination[frame * channels + slot.channelInBuffer] +=
            template[x - entry.outputFrame] * entry.gain
        }
        x += 1
      }
    }
  }
}
