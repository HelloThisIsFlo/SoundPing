import Foundation

/// Seeded random numbers (SplitMix64). The stdlib has no seedable generator, and the seed
/// stored in run.json is what makes a bug report reproducible.
public struct SplitMix64: RandomNumberGenerator, Sendable {
  private var state: UInt64

  public init(seed: UInt64) {
    state = seed
  }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    return Self.finalize(state)
  }

  /// Uniform in [0, 1).
  public mutating func nextDouble() -> Double {
    Double(next() >> 11) * 0x1p-53
  }

  /// The SplitMix64 output function, usable as a stateless hash.
  public static func finalize(_ value: UInt64) -> UInt64 {
    var z = value
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// What the simulated device does to the signal. Analytic: the stimulus is rendered at the exact
/// fractional delay, never resampled, so sub-sample recovery is testable.
public struct Scenario: Codable, Sendable, Equatable {
  public var latencyFrames: Double
  /// Gaussian sigma in frames, drawn once per hit from the seed.
  public var jitterFrames: Double
  public var noiseRms: Double
  /// Gain of the path in dB. Every rendered sample is clamped to [-1, 1] like a real converter,
  /// so a large value clips.
  public var pathGainDb: Double
  public var sampleRate: Double
  public var bufferFrames: Int
  /// Global hit indices (the numbering of `HitRecord.index`, warm-ups first) that never arrive:
  /// the stimulus is not rendered, the capture holds only noise.
  public var missedHits: [Int]
  /// Global hit indices during which the input drops `SimulatedBackend.xrunFrames` frames: the
  /// capture holds zeros there and the callback stamps jump, as after a real HAL glitch.
  public var xrunHits: [Int]
  /// How far the device's sample clock runs fast against the host clock, in parts per million.
  /// It shows up in the callbacks' `rateScalar` and in the host stamps, never in the labels.
  public var driftPPM: Double
  /// Shifts every input-direction host stamp by this many frames, as a driver that stamps its
  /// input late would. The clock self-test must fail when it exceeds its 2 frame limit.
  public var stampBiasFrames: Double
  public var seed: UInt64

  public init(
    latencyFrames: Double = 412.37,
    jitterFrames: Double = 0.5,
    noiseRms: Double = 0.001,
    pathGainDb: Double = 0,
    sampleRate: Double = 48_000,
    bufferFrames: Int = 128,
    missedHits: [Int] = [],
    xrunHits: [Int] = [],
    driftPPM: Double = 0,
    stampBiasFrames: Double = 0,
    seed: UInt64
  ) {
    self.latencyFrames = latencyFrames
    self.jitterFrames = jitterFrames
    self.noiseRms = noiseRms
    self.pathGainDb = pathGainDb
    self.sampleRate = sampleRate
    self.bufferFrames = bufferFrames
    self.missedHits = missedHits
    self.xrunHits = xrunHits
    self.driftPPM = driftPPM
    self.stampBiasFrames = stampBiasFrames
    self.seed = seed
  }

  // Hand-written so a run.json saved before the fault lists existed still decodes.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    latencyFrames = try c.decode(Double.self, forKey: .latencyFrames)
    jitterFrames = try c.decode(Double.self, forKey: .jitterFrames)
    noiseRms = try c.decode(Double.self, forKey: .noiseRms)
    pathGainDb = try c.decode(Double.self, forKey: .pathGainDb)
    sampleRate = try c.decode(Double.self, forKey: .sampleRate)
    bufferFrames = try c.decode(Int.self, forKey: .bufferFrames)
    missedHits = try c.decodeIfPresent([Int].self, forKey: .missedHits) ?? []
    xrunHits = try c.decodeIfPresent([Int].self, forKey: .xrunHits) ?? []
    driftPPM = try c.decodeIfPresent(Double.self, forKey: .driftPPM) ?? 0
    stampBiasFrames = try c.decodeIfPresent(Double.self, forKey: .stampBiasFrames) ?? 0
    seed = try c.decode(UInt64.self, forKey: .seed)
  }
}

extension ResolvedSetup {
  /// The duplex device every `--simulate` run uses.
  public static let simulatedDuplex = ResolvedSetup(
    output: DeviceRef(uid: "soundping-sim-duplex", name: "SoundPing Simulated Duplex"),
    input: DeviceRef(uid: "soundping-sim-duplex", name: "SoundPing Simulated Duplex"),
    outChannels: [1, 2],
    inChannel: 1,
    outChannelNames: ["Output 1", "Output 2"],
    inChannelName: "Input 1")
}

/// A virtual-time `AudioBackend`: no CoreAudio, no wall clock. Frames "happen" when the
/// coordinator waits on a sample position, so a 100-hit run takes milliseconds (ENG-05).
public actor SimulatedBackend: AudioBackend {
  public nonisolated let scenario: Scenario
  public nonisolated let events: AsyncStream<DeviceEvent>

  private let eventContinuation: AsyncStream<DeviceEvent>.Continuation
  private var templates: [String: StimulusTemplate] = [:]
  private var hits: [ScheduledHit] = []
  /// Input frame where each simulated xrun drops `xrunFrames` frames, ascending.
  private var xrunGaps: [Int64] = []
  private var framesProcessed: Int64 = 0
  private var started = false

  /// How many input frames one simulated xrun loses.
  public static let xrunFrames: Int64 = 64

  // mach_timebase_info on Apple Silicon: nanoseconds = ticks * 125 / 3.
  public static let hostClock = HostClock(numer: 125, denom: 3)
  /// Where the virtual host clock starts, far enough from zero that tick values behave like a
  /// machine that has been up for weeks.
  private static let hostEpochTicks: UInt64 = 1 << 42

  public init(scenario: Scenario) {
    self.scenario = scenario
    let (stream, continuation) = AsyncStream<DeviceEvent>.makeStream()
    self.events = stream
    self.eventContinuation = continuation
  }

  public func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws
    -> BackendInfo
  {
    var regenerated: [String: StimulusTemplate] = [:]
    for template in templates {
      regenerated[template.id] = try template.atSampleRate(scenario.sampleRate)
    }
    self.templates = regenerated
    return BackendInfo(
      sampleRate: scenario.sampleRate, bufferFrames: scenario.bufferFrames, simulation: scenario,
      hostClock: Self.hostClock)
  }

  public func start() async throws {
    started = true
  }

  public func currentOutputFrame() async -> Int64 {
    framesProcessed
  }

  public func schedule(_ newHits: [ScheduledHit]) async throws {
    for hit in newHits where templates[hit.templateId] == nil {
      throw SoundPingError.internalFailure(
        "unknownTemplate",
        "hit \(hit.index) uses template '\(hit.templateId)' that was never opened"
      )
    }
    hits.append(contentsOf: newHits)
    hits.sort { $0.outputFrame < $1.outputFrame }
    try validateFaultIndices()
    xrunGaps = faultGaps()
  }

  /// A fault index that names no scheduled hit is a typo, not a no-op (T-01-15).
  private func validateFaultIndices() throws {
    let highest = hits.map(\.index).max() ?? -1
    for (name, indices) in [("sim-miss", scenario.missedHits), ("sim-xrun", scenario.xrunHits)] {
      if let bad = indices.first(where: { $0 < 0 || $0 > highest }) {
        throw SoundPingError.usage(
          "invalidParameters",
          "--\(name) names hit \(bad), but this run fires hits 0 through \(highest) (warm-ups first)",
          context: ["parameter": name, "value": String(bad), "highestHit": String(highest)])
      }
    }
  }

  /// Each xrun lands on the first buffer boundary after the middle of its hit's arrival, so the
  /// stimulus is cut in two the way a real glitch cuts it.
  private func faultGaps() -> [Int64] {
    let buffer = Int64(scenario.bufferFrames)
    let xrun = Set(scenario.xrunHits)
    return hits.compactMap { hit -> Int64? in
      guard xrun.contains(hit.index), let template = templates[hit.templateId] else { return nil }
      let start = Double(hit.outputFrame) + scenario.latencyFrames + jitter(forHit: hit.index)
      let middle = start + Double(template.samples.count) / 2
      return (Int64(middle.rounded(.up)) + buffer - 1) / buffer * buffer
    }.sorted()
  }

  public func waitUntilCaptured(throughInputFrame: Int64) async throws {
    guard started else {
      throw SoundPingError.internalFailure("notStarted", "the simulated backend was not started")
    }
    guard throughInputFrame > framesProcessed else { return }
    let buffer = Int64(scenario.bufferFrames)
    framesProcessed = (throughInputFrame + buffer - 1) / buffer * buffer
  }

  public func capture(_ range: Range<Int64>) async throws -> [Float] {
    guard range.lowerBound >= 0, range.upperBound <= framesProcessed else {
      throw SoundPingError.internalFailure(
        "captureBeyondProcessed",
        "frames \(range) are not captured yet (processed through \(framesProcessed))")
    }
    let count = Int(range.count)
    var out = [Float](repeating: 0, count: count)

    if scenario.noiseRms > 0 {
      let amplitude = scenario.noiseRms * 3.0.squareRoot()
      for offset in 0..<count {
        let frame = UInt64(bitPattern: range.lowerBound + Int64(offset))
        let hash = SplitMix64.finalize(
          scenario.seed ^ 0xD1B5_4A32_D192_ED03 &+ frame &* 0x9E37_79B9_7F4A_7C15)
        let uniform = Double(hash >> 11) * 0x1p-53
        out[offset] = Float((uniform * 2 - 1) * amplitude)
      }
    }

    let pathGain = pow(10, scenario.pathGainDb / 20)
    let missed = Set(scenario.missedHits)
    for hit in hits {
      guard !missed.contains(hit.index), let template = templates[hit.templateId] else { continue }
      let start = Double(hit.outputFrame) + scenario.latencyFrames + jitter(forHit: hit.index)
      let end = start + template.durationMs / 1000 * scenario.sampleRate
      guard end > Double(range.lowerBound), start < Double(range.upperBound) else { continue }
      let first = Swift.max(range.lowerBound, Int64(start.rounded(.up)))
      let last = Swift.min(range.upperBound, Int64(end.rounded(.up)))
      guard first < last else { continue }
      let scale = Double(hit.gain) * pathGain
      for frame in first..<last {
        let seconds = (Double(frame) - start) / scenario.sampleRate
        out[Int(frame - range.lowerBound)] += Float(
          scale * Double(template.value(atSeconds: seconds)))
      }
    }

    for gap in xrunGaps {
      let first = Swift.max(range.lowerBound, gap)
      let last = Swift.min(range.upperBound, gap + Self.xrunFrames)
      guard first < last else { continue }
      for frame in first..<last { out[Int(frame - range.lowerBound)] = 0 }
    }

    // A converter cannot go past full scale.
    for offset in 0..<count { out[offset] = Swift.max(-1, Swift.min(1, out[offset])) }
    return out
  }

  public func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    guard !range.isEmpty else { return [] }
    let buffer = Int64(scenario.bufferFrames)
    let firstBuffer = Swift.max(0, range.lowerBound) / buffer
    let lastBuffer = Swift.min(range.upperBound, framesProcessed).advanced(by: -1) / buffer
    guard firstBuffer <= lastBuffer else { return [] }
    return (firstBuffer...lastBuffer).map { index in
      let frame = index * buffer
      // After an xrun the device clock has run on: sample time jumps ahead of the frame count.
      let lost = Int64(xrunGaps.filter { $0 <= frame }.count) * Self.xrunFrames
      var stamp = callbackStamp(index: index)
      stamp.inputSampleTime = Double(frame + lost)
      return stamp
    }
  }

  public func stampLog() async -> StampLog {
    let buffer = Int64(scenario.bufferFrames)
    let callbacks = Int(framesProcessed / buffer)
    var log = StampLog()
    log.input.reserveCapacity(callbacks)
    log.output.reserveCapacity(callbacks)
    for index in 0..<callbacks {
      let stamp = callbackStamp(index: Int64(index))
      log.input.append(
        TimelinePoint(
          sampleTime: stamp.inputSampleTime, hostTime: stamp.inputHostTime,
          rateScalar: stamp.inputRateScalar, frames: stamp.frames))
      log.output.append(
        TimelinePoint(
          sampleTime: stamp.outputSampleTime, hostTime: stamp.outputHostTime,
          rateScalar: stamp.outputRateScalar, frames: stamp.frames))
    }
    return log
  }

  public func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }

  /// The callback with this index, stamped from one virtual host clock. The label of a frame maps
  /// to host time through the device's clock rate (drifted by `driftPPM`), so input and output
  /// stamps of the same device agree unless `stampBiasFrames` skews the input ones.
  private func callbackStamp(index: Int64) -> CallbackStamp {
    let frame = Double(index * Int64(scenario.bufferFrames))
    let host = hostTicks(forLabel: frame)
    let bias = Self.hostClock.ticks(
      forFrames: scenario.stampBiasFrames, sampleRate: scenario.sampleRate)
    let inputHost = UInt64(Swift.max(0, (Double(host) + bias).rounded()))
    return CallbackStamp(
      inputSampleTime: frame, inputHostTime: inputHost, inputRateScalar: rateScalar,
      outputSampleTime: frame, outputHostTime: host, outputRateScalar: rateScalar,
      frames: scenario.bufferFrames)
  }

  /// Host ticks at which the device's clock reads `label`.
  private func hostTicks(forLabel label: Double) -> UInt64 {
    let seconds = label / (scenario.sampleRate * (1 + scenario.driftPPM * 1e-6))
    return Self.hostEpochTicks + Self.hostClock.nanosToWholeTicks(seconds * 1e9)
  }

  /// Apple's definition: actual host ticks per frame over the nominal ones. A clock that runs
  /// fast spends fewer ticks per frame.
  private var rateScalar: Double { 1 / (1 + scenario.driftPPM * 1e-6) }

  public func stop() async {
    started = false
    eventContinuation.finish()
  }

  /// Per-hit jitter, a Gaussian draw keyed by the seed and the hit index so it never depends on
  /// the order the coordinator asks in.
  private func jitter(forHit index: Int) -> Double {
    guard scenario.jitterFrames > 0 else { return 0 }
    var rng = SplitMix64(
      seed: scenario.seed ^ 0x6A09_E667_F3BC_C909 &+ UInt64(index) &* 0xBB67_AE85_84CA_A73B)
    let u1 = 1 - rng.nextDouble()
    let u2 = rng.nextDouble()
    return scenario.jitterFrames * (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
  }
}
