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
  public var pathGainDb: Double
  public var sampleRate: Double
  public var bufferFrames: Int
  public var seed: UInt64

  public init(
    latencyFrames: Double = 412.37,
    jitterFrames: Double = 0.5,
    noiseRms: Double = 0.001,
    pathGainDb: Double = 0,
    sampleRate: Double = 48_000,
    bufferFrames: Int = 128,
    seed: UInt64
  ) {
    self.latencyFrames = latencyFrames
    self.jitterFrames = jitterFrames
    self.noiseRms = noiseRms
    self.pathGainDb = pathGainDb
    self.sampleRate = sampleRate
    self.bufferFrames = bufferFrames
    self.seed = seed
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
  private var framesProcessed: Int64 = 0
  private var started = false

  // mach_timebase_info on Apple Silicon: nanoseconds = ticks * 125 / 3.
  private static let timebaseNumer = 125.0
  private static let timebaseDenom = 3.0

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
      sampleRate: scenario.sampleRate, bufferFrames: scenario.bufferFrames, simulation: scenario)
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
        "unknownTemplate", "hit \(hit.index) uses template '\(hit.templateId)' that was never opened"
      )
    }
    hits.append(contentsOf: newHits)
    hits.sort { $0.outputFrame < $1.outputFrame }
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
    for hit in hits {
      guard let template = templates[hit.templateId] else { continue }
      let start = Double(hit.outputFrame) + scenario.latencyFrames + jitter(forHit: hit.index)
      let end = start + template.durationMs / 1000 * scenario.sampleRate
      guard end > Double(range.lowerBound), start < Double(range.upperBound) else { continue }
      let first = Swift.max(range.lowerBound, Int64(start.rounded(.up)))
      let last = Swift.min(range.upperBound, Int64(end.rounded(.up)))
      guard first < last else { continue }
      let scale = Double(hit.gain) * pathGain
      for frame in first..<last {
        let seconds = (Double(frame) - start) / scenario.sampleRate
        out[Int(frame - range.lowerBound)] += Float(scale * Double(template.value(atSeconds: seconds)))
      }
    }
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
      let nanoseconds = Double(frame) / scenario.sampleRate * 1e9
      let ticks = UInt64((nanoseconds * Self.timebaseDenom / Self.timebaseNumer).rounded())
      return CallbackStamp(
        inputSampleTime: Double(frame), inputHostTime: ticks, inputRateScalar: 1,
        outputSampleTime: Double(frame), outputHostTime: ticks, outputRateScalar: 1,
        frames: scenario.bufferFrames)
    }
  }

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
