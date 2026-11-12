/// What the HAL reports for one direction, in frames (RESEARCH Pattern 3).
public struct ScopeReport: Codable, Sendable, Equatable {
  public var deviceLatencyFrames: Int
  /// The stream that carries the chosen channel(s), never only the device property (RESEARCH P2).
  public var streamLatencyFrames: Int
  public var safetyOffsetFrames: Int
  public var bufferFrames: Int

  public init(
    deviceLatencyFrames: Int, streamLatencyFrames: Int, safetyOffsetFrames: Int, bufferFrames: Int
  ) {
    self.deviceLatencyFrames = deviceLatencyFrames
    self.streamLatencyFrames = streamLatencyFrames
    self.safetyOffsetFrames = safetyOffsetFrames
    self.bufferFrames = bufferFrames
  }

  /// Device plus stream latency: the part that belongs to the audio path itself.
  public var pathFrames: Int { deviceLatencyFrames + streamLatencyFrames }
}

/// The two sums macOS lets us compute for a device pair (RES-02). They sit next to the measured
/// figures so a mismatch shows which segment is off, and `expectedIoOffsetFrames` is what the
/// measured Δio is compared with to settle the safety-offset dispute with data (RESEARCH P3).
public struct ReportedLatency: Codable, Sendable, Equatable {
  public var output: ScopeReport
  public var input: ScopeReport
  public var sampleRate: Double
  /// Output (device + stream) plus input (device + stream). Compare with the measured `path`.
  public var pathFrames: Int
  public var pathMs: Double
  /// `pathFrames` plus both safety offsets and both buffers. Compare with `appRoundTrip`.
  public var appRoundTripFrames: Int
  public var appRoundTripMs: Double
  /// Both buffers plus both safety offsets: the figure the measured Δio should land near.
  public var expectedIoOffsetFrames: Int
  public var source: String

  public init(
    output: ScopeReport, input: ScopeReport, sampleRate: Double, pathFrames: Int, pathMs: Double,
    appRoundTripFrames: Int, appRoundTripMs: Double, expectedIoOffsetFrames: Int,
    source: String = "halReported"
  ) {
    self.output = output
    self.input = input
    self.sampleRate = sampleRate
    self.pathFrames = pathFrames
    self.pathMs = pathMs
    self.appRoundTripFrames = appRoundTripFrames
    self.appRoundTripMs = appRoundTripMs
    self.expectedIoOffsetFrames = expectedIoOffsetFrames
    self.source = source
  }

  /// `outputBufferFrames` and `inputBufferFrames` are SoundPing's own I/O buffer sizes on the two
  /// devices. They are equal on one duplex device and can differ on two, each device clamping the
  /// requested size to its own range. A direction the device does not have contributes zeros.
  public static func compute(
    output: DeviceInfo, outChannels: [Int], input: DeviceInfo, inChannel: Int,
    outputBufferFrames: Int, inputBufferFrames: Int, sampleRate: Double
  ) -> ReportedLatency {
    let out = report(output.output, channels: outChannels, bufferFrames: outputBufferFrames)
    let inp = report(input.input, channels: [inChannel], bufferFrames: inputBufferFrames)

    let path = out.pathFrames + inp.pathFrames
    let ioOffset =
      out.bufferFrames + inp.bufferFrames + out.safetyOffsetFrames + inp.safetyOffsetFrames
    let roundTrip = path + ioOffset
    let toMs = { (frames: Int) in sampleRate > 0 ? Double(frames) / sampleRate * 1000 : 0 }

    return ReportedLatency(
      output: out, input: inp, sampleRate: sampleRate,
      pathFrames: path, pathMs: toMs(path),
      appRoundTripFrames: roundTrip, appRoundTripMs: toMs(roundTrip),
      expectedIoOffsetFrames: ioOffset)
  }

  /// Several channels can sit in different streams; the slowest of those streams sets when all
  /// of them have sounded, so that is the one reported.
  private static func report(_ scope: ScopeInfo?, channels: [Int], bufferFrames: Int)
    -> ScopeReport
  {
    guard let scope else {
      return ScopeReport(
        deviceLatencyFrames: 0, streamLatencyFrames: 0, safetyOffsetFrames: 0,
        bufferFrames: bufferFrames)
    }
    let stream = channels.map { Int(scope.streamLatency(forChannel: $0)) }.max() ?? 0
    return ScopeReport(
      deviceLatencyFrames: Int(scope.deviceLatency), streamLatencyFrames: stream,
      safetyOffsetFrames: Int(scope.safetyOffset), bufferFrames: bufferFrames)
  }
}
