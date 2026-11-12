import CoreAudio
import Foundation
import Synchronization

// The work one audio callback does. Everything here is reachable from the HAL's real-time thread,
// so every function is `@_noLocks`: the compiler refuses reference counting, allocation and locks
// in them (T-01-23). They use only `RTState`'s preallocated buffers and atomics.

/// Captures the selected input channel and logs the callback's input stamp.
@_noLocks
func ioCycleInput(
  _ rt: RTState, _ data: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>
) {
}

/// Zeroes every output buffer, then (on the output device) logs the output stamp and mixes the
/// scheduled hits into the selected output channels.
@_noLocks
func ioCycleOutput(
  _ rt: RTState, _ data: UnsafeMutablePointer<AudioBufferList>,
  _ time: UnsafePointer<AudioTimeStamp>, isOutputDevice: Bool
) {
}
