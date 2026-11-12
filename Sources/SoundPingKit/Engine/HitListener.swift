import Accelerate
import Foundation

/// Listens for one scheduled hit: finds its input window, waits for the samples, and runs a
/// correlator over them. Warm-ups, measured hits, level probes and the channel probe all hear
/// through this one path, so a probe is judged exactly the way a hit is.
struct HitListener {
  let backend: any AudioBackend
  let info: BackendInfo
  let twoDevice: Bool
  private let templateFrames: Int64
  private let maxLatencyFrames: Int64
  private let prerollFrames: Int64
  private(set) var mapping: HostMapping?

  /// Listening starts this long before the stimulus is expected, so a mapping that is a few frames
  /// off (or a driver that stamps slightly early) still finds the hit.
  static let windowPrerollMs = 5.0
  /// Callbacks that must be on record before two devices' clocks are fitted: the fit uses 33.
  static let mappingWarmupCallbacks = 2 * DeviceTimeline.halfWindow + 8
  /// How long past the end of a window the listener waits before it asks for faults, so an HAL
  /// 'over' notification that arrives a little after its glitch lands before the window is judged.
  /// It must stay well below `HitScheduler.spacingMarginMs` (50): the wait may not reach the next
  /// hit. Best effort; how late the HAL really notifies needs hardware to know.
  static let faultSettleMs = 20.0

  init(
    backend: any AudioBackend, info: BackendInfo, templateFrames: Int64, maxLatencyMs: Double,
    twoDevice: Bool
  ) {
    self.backend = backend
    self.info = info
    self.twoDevice = twoDevice
    self.templateFrames = templateFrames
    self.maxLatencyFrames = Int64((maxLatencyMs / 1000 * info.sampleRate).rounded(.up))
    self.prerollFrames = Int64((Self.windowPrerollMs / 1000 * info.sampleRate).rounded(.up))
  }

  /// What one listening window held.
  struct Heard {
    var detection: Detection
    /// The latency of a found hit, in frames: same device, the distance between the two sample
    /// labels; two devices, between the host times the two labels were stamped with.
    var latencyFrames: Double?
    /// Loudest input sample of the window, 0 when nothing was captured.
    var peakAbs: Float
    /// Frames of the window. 0 when a recorded fault kept it from being read.
    var capturedFrames: Int
    /// A recorded fault interval overlaps the window or the played chirp, so the window was not read.
    var faulted = false
  }

  /// Two devices count their samples separately, so a hit's input window is found through host
  /// time: that needs a stretch of callbacks on both sides to fit before the first hit.
  mutating func prepareClockMapping() async throws {
    guard twoDevice else { return }
    let first = await backend.currentInputFrame()
    try await backend.waitUntilCaptured(
      throughInputFrame: first
        + Int64(
          Self.mappingWarmupCallbacks * Swift.max(info.outputBufferFrames, info.inputBufferFrames)))
    mapping = try HostMapping(log: await backend.stampLog(), info: info)
  }

  mutating func listen(to hit: ScheduledHit, with correlator: Correlator) async throws -> Heard {
    // One device: output and input share their sample labels, so the stimulus is listened for
    // from the frame it was played, less the same pre-roll. Without it a path of about zero
    // frames (a software loop) peaks at lag 0, which the correlator rejects as outside the
    // window. A driver that labels input slightly early gives a negative path, which is kept as
    // measured. Two devices: from where host time puts it on the input clock.
    let range: Range<Int64>
    if let mapping {
      range = mapping.inputWindow(
        forOutputFrame: hit.outputFrame, prerollFrames: prerollFrames,
        lengthFrames: maxLatencyFrames + templateFrames)
    } else {
      let start = Swift.max(0, hit.outputFrame - prerollFrames)
      range = start..<(hit.outputFrame + maxLatencyFrames + templateFrames)
    }
    let settleFrames = Int64((Self.faultSettleMs / 1000 * info.sampleRate).rounded(.up))
    try await backend.waitUntilCaptured(throughInputFrame: range.upperBound + settleFrames)
    if twoDevice { mapping = try HostMapping(log: await backend.stampLog(), info: info) }

    // Asked of the backend directly, after the window is captured: the record is complete below
    // the frames just waited for, and no event-stream hop sits between a glitch and this check
    // (WR-01). The chirp's own output frames count too: a glitch while it played changed it.
    let playedFrames = hit.outputFrame..<(hit.outputFrame + templateFrames)
    if !(await backend.faults(overlappingInput: range, output: playedFrames)).isEmpty {
      return Heard(
        detection: .rejected(.discontinuity), peakAbs: 0, capturedFrames: 0, faulted: true)
    }
    let window = try await backend.capture(range)
    let stamps = await backend.stamps(covering: range)
    let detection = correlator.detect(
      window: window, windowStartFrame: range.lowerBound, stamps: stamps)

    var peak: Float = 0
    if !window.isEmpty {
      window.withUnsafeBufferPointer {
        vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length($0.count))
      }
    }
    var latency: Double?
    if case .found(let frame, _, _, _) = detection {
      latency =
        mapping?.hostPathFrames(outputFrame: hit.outputFrame, inputSample: frame)
        ?? frame - Double(hit.outputFrame)
    }
    return Heard(
      detection: detection, latencyFrames: latency, peakAbs: peak, capturedFrames: window.count)
  }
}

/// The two devices' clocks of a two-device run, fitted from the callbacks logged so far. It places
/// each hit's input window and measures the hit through host time (CAL-03).
struct HostMapping {
  let output: DeviceTimeline
  let input: DeviceTimeline
  let clock: HostClock
  let sampleRate: Double

  init(log: StampLog, info: BackendInfo) throws {
    guard
      let output = DeviceTimeline(
        points: log.output, sampleRate: info.sampleRate, clock: info.hostClock),
      let input = DeviceTimeline(
        points: log.input, sampleRate: info.sampleRate, clock: info.hostClock)
    else {
      throw SoundPingError.internalFailure(
        "timelineUnavailable",
        "the backend logged no callback timestamps, so the two devices' clocks cannot be related")
    }
    self.output = output
    self.input = input
    self.clock = info.hostClock
    self.sampleRate = info.sampleRate
  }

  /// The input frames to listen to for a hit played at `outputFrame`: where the input device's
  /// clock stands when the output device plays that frame, less a pre-roll. The hit has not been
  /// heard yet when this is asked, so the output frame may lie beyond the log and be extrapolated;
  /// that only shifts the window by a frame or two, never the measurement.
  func inputWindow(forOutputFrame outputFrame: Int64, prerollFrames: Int64, lengthFrames: Int64)
    -> Range<Int64>
  {
    let host = output.hostTicks(forSample: Double(outputFrame))
    let start = Int64(input.sample(forHostTicks: host).rounded(.down)) - prerollFrames
    return start..<(start + prerollFrames + lengthFrames)
  }

  func hostPathFrames(outputFrame: Int64, inputSample: Double) -> Double {
    ClockSelfTest.hostPathFrames(
      outputSample: Double(outputFrame), inputSample: inputSample, output: output, input: input,
      sampleRate: sampleRate, clock: clock)
  }
}
