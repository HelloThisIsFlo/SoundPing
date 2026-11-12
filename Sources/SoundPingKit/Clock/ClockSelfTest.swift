/// The pass limits of the host-clock self-test (CAL-03, RESEARCH A2). Both are inclusive.
public struct ClockSelfTestThresholds: Codable, Sendable, Equatable {
  /// |median Δ| must not exceed this many frames.
  public var medianFrames: Double
  /// The 95th percentile of |Δ| must not exceed this many frames.
  public var p95Frames: Double

  public init(medianFrames: Double, p95Frames: Double) {
    self.medianFrames = medianFrames
    self.p95Frames = p95Frames
  }

  public static let standard = ClockSelfTestThresholds(medianFrames: 1, p95Frames: 2)
}

/// What the self-test found. Δ is the host-clock path minus the sample-clock path, per hit.
public struct ClockSelfTestResult: Codable, Sendable, Equatable {
  public var pass: Bool
  public var medianDeltaFrames: Double
  public var p95AbsDeltaFrames: Double
  /// Hits the statistics are made of.
  public var n: Int
  public var thresholds: ClockSelfTestThresholds
  /// Median gap, in frames, between our input timeline and the HAL's own translation of the same
  /// sample (`AudioDeviceTranslateTime`). A diagnostic third opinion; nil when the backend has none.
  public var halCrossCheckMedianFrames: Double?

  public init(
    pass: Bool, medianDeltaFrames: Double, p95AbsDeltaFrames: Double, n: Int,
    thresholds: ClockSelfTestThresholds = .standard, halCrossCheckMedianFrames: Double? = nil
  ) {
    self.pass = pass
    self.medianDeltaFrames = medianDeltaFrames
    self.p95AbsDeltaFrames = p95AbsDeltaFrames
    self.n = n
    self.thresholds = thresholds
    self.halCrossCheckMedianFrames = halCrossCheckMedianFrames
  }
}

/// Does the host clock agree with the sample clock? The one function behind both the check every
/// same-device run makes on itself and `soundping selftest clock` (CAL-03, D-05).
///
/// For each valid measured hit the sample-clock path is what the detector found
/// (`input sample - output sample`). The host-clock path is the same two samples run through the
/// per-direction timelines (`H_in(input sample) - H_out(output sample)`), converted to frames at the
/// nominal rate. If the stamps are honest the two agree; Δ is their difference. Phase 2 aligns MIDI
/// to audio through host time, so this has to hold first.
///
/// The host path always goes through the generic per-direction timelines that two-device runs use,
/// never through the duplex callback's own pair of stamps (RESEARCH L372).
public enum ClockSelfTest {
  public static func evaluate(
    hits: [HitRecord], stampLog: StampLog, sampleRate: Double, hostClock: HostClock,
    halInputHostTimes: [Int: UInt64] = [:]
  ) -> ClockSelfTestResult {
    guard
      let output = DeviceTimeline(
        points: stampLog.output, sampleRate: sampleRate, clock: hostClock),
      let input = DeviceTimeline(points: stampLog.input, sampleRate: sampleRate, clock: hostClock)
    else {
      return verdict(deltas: [])
    }

    var deltas: [Double] = []
    var halGaps: [Double] = []
    for hit in hits where hit.phase == .measure && hit.rejection == nil {
      guard let path = hit.latencyFrames else { continue }
      let outputSample = Double(hit.outputFrame)
      let inputSample = outputSample + path
      let host = hostPathFrames(
        outputSample: outputSample, inputSample: inputSample, output: output, input: input,
        sampleRate: sampleRate, clock: hostClock)
      guard host.isFinite else { continue }
      deltas.append(host - path)

      if let hal = halInputHostTimes[hit.index] {
        let ours = UInt64(Swift.max(0, input.hostTicks(forSample: inputSample).rounded()))
        let gapTicks = Double(Int64(bitPattern: hal &- ours))
        halGaps.append(hostClock.frames(forTicks: gapTicks, sampleRate: sampleRate))
      }
    }

    let halMedian = halGaps.isEmpty ? nil : Stats.percentile(halGaps.sorted(), 0.5)
    return verdict(deltas: deltas, halCrossCheckMedianFrames: halMedian)
  }

  /// The host-clock path of one hit in frames at `sampleRate`: when the input sample was captured
  /// minus when the output sample was played, both read off their own device's timeline.
  public static func hostPathFrames(
    outputSample: Double, inputSample: Double, output: DeviceTimeline, input: DeviceTimeline,
    sampleRate: Double, clock: HostClock
  ) -> Double {
    let ticks = input.hostTicks(forSample: inputSample) - output.hostTicks(forSample: outputSample)
    return clock.frames(forTicks: ticks, sampleRate: sampleRate)
  }

  /// The pass/fail rule on its own, for tests and for callers that already hold the Δ values.
  /// Passes when |median Δ| <= 1 and the 95th percentile of |Δ| <= 2 frames, both inclusive.
  /// No Δ at all proves nothing and fails.
  public static func verdict(
    deltas: [Double], thresholds: ClockSelfTestThresholds = .standard,
    halCrossCheckMedianFrames: Double? = nil
  ) -> ClockSelfTestResult {
    let finite = deltas.filter(\.isFinite)
    guard !finite.isEmpty else {
      return ClockSelfTestResult(
        pass: false, medianDeltaFrames: 0, p95AbsDeltaFrames: 0, n: 0, thresholds: thresholds,
        halCrossCheckMedianFrames: halCrossCheckMedianFrames)
    }
    let median = Stats.percentile(finite.sorted(), 0.5)
    let p95 = Stats.percentile(finite.map { abs($0) }.sorted(), 0.95)
    return ClockSelfTestResult(
      pass: abs(median) <= thresholds.medianFrames && p95 <= thresholds.p95Frames,
      medianDeltaFrames: median, p95AbsDeltaFrames: p95, n: finite.count, thresholds: thresholds,
      halCrossCheckMedianFrames: halCrossCheckMedianFrames)
  }
}
