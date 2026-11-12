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

/// A device change the simulator makes happen part way through a run (ENG-07). `atHit` uses the
/// numbering of `HitRecord.index`, warm-ups first: the event fires when virtual time reaches that
/// hit's output frame.
public struct Fault: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case deviceGone
    case sampleRateChange
    case bufferChange
    case streamConfigChange
    /// An audio-thread overload: only the hit it lands in is rejected, the run goes on.
    case overload
  }

  public var kind: Kind
  public var atHit: Int

  public init(kind: Kind, atHit: Int) {
    self.kind = kind
    self.atHit = atHit
  }

  /// `<kind>@<hit>`, e.g. `sampleRateChange@30`. Anything else is a usage error.
  public static func parse(_ spec: String) throws -> Fault {
    let parts = spec.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])),
      let hit = Int(parts[1].trimmingCharacters(in: .whitespaces)), hit >= 0
    else {
      throw SoundPingError.usage(
        "invalidParameters",
        "--sim-fault takes <kind>@<hit> with a kind from \(Kind.allCases.map(\.rawValue).joined(separator: ", ")) and a hit index of 0 or more; got '\(spec)'",
        context: ["parameter": "sim-fault", "value": spec])
    }
    return Fault(kind: kind, atHit: hit)
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
  /// How far the output sample labels run ahead of the input ones within a callback, like a real
  /// duplex device (buffers plus safety offsets). Default `2 * bufferFrames + 28`.
  public var ioOffsetFrames: Int
  /// Device changes injected into the run, each at a hit index.
  public var faults: [Fault]
  /// The microphone permission the simulated process holds. Denied and restricted make the
  /// capture all zeros, which is what macOS does to a real process without consent.
  public var permission: PermissionStatus
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
    ioOffsetFrames: Int? = nil,
    faults: [Fault] = [],
    permission: PermissionStatus = .authorized,
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
    self.ioOffsetFrames = ioOffsetFrames ?? 2 * bufferFrames + 28
    self.faults = faults
    self.permission = permission
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
    ioOffsetFrames =
      try c.decodeIfPresent(Int.self, forKey: .ioOffsetFrames) ?? 2 * bufferFrames + 28
    faults = try c.decodeIfPresent([Fault].self, forKey: .faults) ?? []
    permission = try c.decodeIfPresent(PermissionStatus.self, forKey: .permission) ?? .authorized
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
///
/// One virtual host clock stamps every callback. On a single device (the output and input UIDs of
/// the setup are equal) output and input share their sample labels, as on a duplex interface: a
/// hit played at output frame `F` arrives at input frame `F + latency`, and each callback's output
/// label runs `ioOffsetFrames` ahead of its input label. With two different devices each keeps its
/// own labels, starting at unrelated origins, and the input device's clock drifts by `driftPPM`
/// against the host: only host time relates the two, the way it does for a MacBook's speakers and
/// microphone.
public actor SimulatedBackend: AudioBackend {
  public nonisolated let scenario: Scenario
  public nonisolated let events: AsyncStream<DeviceEvent>

  private let eventContinuation: AsyncStream<DeviceEvent>.Continuation
  private var templates: [String: StimulusTemplate] = [:]
  private var hits: [ScheduledHit] = []
  /// Input frame where each simulated xrun drops `xrunFrames` frames, ascending.
  private var xrunGaps: [Int64] = []
  /// Device events waiting for virtual time to reach their input frame, ascending.
  private var pendingEvents: [PendingEvent] = []
  private var outputUID = ""
  private var inputUID = ""

  private struct PendingEvent {
    var frame: Int64
    var event: DeviceEvent
    /// A change that ends the device's audio: the backend stops delivering once it has said so.
    var fatal: Bool
  }
  /// Input labels below this are captured (exclusive bound). Starts at the input origin.
  private var framesProcessed: Int64 = 0
  private var started = false
  private var twoDevices = false
  private var outputOrigin: Int64 = 0
  private var inputOrigin: Int64 = 0

  /// How many input frames one simulated xrun loses.
  public static let xrunFrames: Int64 = 64

  /// Where each device's sample labels start in two-device mode. Unrelated on purpose: a run that
  /// assumed the two label spaces were one would find nothing.
  static let twoDeviceOutputOrigin: Int64 = 96_000
  static let twoDeviceInputOrigin: Int64 = 7_654_321

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

    twoDevices = setup.output.uid != setup.input.uid
    outputUID = setup.output.uid
    inputUID = setup.input.uid
    outputOrigin = twoDevices ? Self.twoDeviceOutputOrigin : 0
    inputOrigin = twoDevices ? Self.twoDeviceInputOrigin : 0
    framesProcessed = inputOrigin

    // The fixtures stand in for what the HAL would report; a device they do not know reports nothing.
    let catalog = (try? SimulatedCatalog().listing().audio) ?? []
    return BackendInfo(
      sampleRate: scenario.sampleRate, bufferFrames: scenario.bufferFrames, simulation: scenario,
      hostClock: Self.hostClock,
      outputDevice: catalog.first { $0.uid == setup.output.uid },
      inputDevice: catalog.first { $0.uid == setup.input.uid })
  }

  public func start() async throws {
    started = true
  }

  public func currentOutputFrame() async -> Int64 {
    guard twoDevices else { return framesProcessed }
    // The output device's clock has run for as long as the input device's has, on the host clock.
    let elapsedSeconds = Double(framesProcessed - inputOrigin) / inputLabelsPerHostSecond
    return outputOrigin + Int64((elapsedSeconds * scenario.sampleRate).rounded())
  }

  public func currentInputFrame() async -> Int64 {
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
    pendingEvents = faultEvents()
  }

  /// A fault index that names no scheduled hit is a typo, not a no-op (T-01-15).
  private func validateFaultIndices() throws {
    let highest = hits.map(\.index).max() ?? -1
    for (name, indices) in [
      ("sim-miss", scenario.missedHits), ("sim-xrun", scenario.xrunHits),
      ("sim-fault", scenario.faults.map(\.atHit)),
    ] {
      if let bad = indices.first(where: { $0 < 0 || $0 > highest }) {
        throw SoundPingError.usage(
          "invalidParameters",
          "--\(name) names hit \(bad), but this run fires hits 0 through \(highest) (warm-ups first)",
          context: ["parameter": name, "value": String(bad), "highestHit": String(highest)])
      }
    }
  }

  /// An overload is an xrun that also announces itself on the event stream, the way the HAL's
  /// processor-overload notification does; the lost frames reject the hit through the stamps.
  private var xrunIndices: Set<Int> {
    Set(scenario.xrunHits).union(scenario.faults.filter { $0.kind == .overload }.map(\.atHit))
  }

  /// Each xrun lands on the first buffer boundary after the middle of its hit's arrival, so the
  /// stimulus is cut in two the way a real glitch cuts it.
  private func gapFrame(of hit: ScheduledHit) -> Int64? {
    guard xrunIndices.contains(hit.index), let template = templates[hit.templateId] else {
      return nil
    }
    let buffer = Int64(scenario.bufferFrames)
    let middle = arrivalFrame(of: hit) + Double(template.samples.count) / 2
    let relative = Int64(middle.rounded(.up)) - inputOrigin
    return inputOrigin + (relative + buffer - 1) / buffer * buffer
  }

  private func faultGaps() -> [Int64] {
    hits.compactMap(gapFrame(of:)).sorted()
  }

  /// The device events the faults ask for, each at the input frame where its hit's output frame
  /// falls on the input device's labels.
  private func faultEvents() -> [PendingEvent] {
    var events: [PendingEvent] = []
    for fault in scenario.faults {
      guard let hit = hits.first(where: { $0.index == fault.atHit }) else { continue }
      let frame = inputOrigin + (hit.outputFrame - outputOrigin)
      switch fault.kind {
      case .deviceGone:
        events.append(PendingEvent(frame: frame, event: .gone(uid: outputUID), fatal: true))
      case .sampleRateChange:
        let to = scenario.sampleRate == 44_100 ? 48_000.0 : 44_100.0
        events.append(
          PendingEvent(
            frame: frame,
            event: .sampleRateChanged(uid: outputUID, from: scenario.sampleRate, to: to),
            fatal: true))
      case .bufferChange:
        events.append(
          PendingEvent(
            frame: frame,
            event: .bufferSizeChanged(
              uid: outputUID, from: scenario.bufferFrames, to: scenario.bufferFrames * 2),
            fatal: true))
      case .streamConfigChange:
        events.append(
          PendingEvent(frame: frame, event: .streamConfigChanged(uid: outputUID), fatal: true))
      case .overload:
        if let gap = gapFrame(of: hit) {
          events.append(
            PendingEvent(
              frame: gap, event: .overload(uid: inputUID, atInputFrame: gap), fatal: false))
        }
      }
    }
    return events.sorted { $0.frame < $1.frame }
  }

  public func waitUntilCaptured(throughInputFrame: Int64) async throws {
    guard started else {
      throw SoundPingError.internalFailure("notStarted", "the simulated backend was not started")
    }
    guard throughInputFrame > framesProcessed else { return }
    let buffer = Int64(scenario.bufferFrames)
    let relative = throughInputFrame - inputOrigin
    framesProcessed = inputOrigin + (relative + buffer - 1) / buffer * buffer
    try await deliverDueEvents()
  }

  /// Says what happened while the frames just processed went by. After a change that ends the
  /// device's audio the wait never returns, like the wait on a device that vanished, until the
  /// coordinator reacts to the event and cancels it.
  private func deliverDueEvents() async throws {
    while let next = pendingEvents.first, next.frame < framesProcessed {
      pendingEvents.removeFirst()
      eventContinuation.yield(next.event)
      if next.fatal {
        while true { try await Task.sleep(for: .seconds(3600)) }
      }
    }
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
      let start = arrivalFrame(of: hit)
      let end = start + template.durationMs / 1000 * stimulusFramesPerSecond
      guard end > Double(range.lowerBound), start < Double(range.upperBound) else { continue }
      let first = Swift.max(range.lowerBound, Int64(start.rounded(.up)))
      let last = Swift.min(range.upperBound, Int64(end.rounded(.up)))
      guard first < last else { continue }
      let scale = Double(hit.gain) * pathGain
      for frame in first..<last {
        let seconds = (Double(frame) - start) / stimulusFramesPerSecond
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
    // Without consent the system hands a process exact zeros, not an error.
    if scenario.permission == .denied || scenario.permission == .restricted {
      out = [Float](repeating: 0, count: count)
    }
    return out
  }

  public func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    guard !range.isEmpty else { return [] }
    let buffer = Int64(scenario.bufferFrames)
    let upper = Swift.min(range.upperBound, framesProcessed)
    guard upper > inputOrigin else { return [] }
    let firstBuffer = Swift.max(0, range.lowerBound - inputOrigin) / buffer
    let lastBuffer = (upper - 1 - inputOrigin) / buffer
    guard firstBuffer <= lastBuffer else { return [] }
    return (firstBuffer...lastBuffer).map { index in
      let frame = inputOrigin + index * buffer
      // After an xrun the device clock has run on: sample time jumps ahead of the frame count.
      let lost = Int64(xrunGaps.filter { $0 <= frame }.count) * Self.xrunFrames
      var stamp = callbackStamp(index: index)
      stamp.inputSampleTime = Double(frame + lost)
      return stamp
    }
  }

  /// Every callback so far. It ignores xruns: the log describes the clocks, and a lost-frames jump
  /// belongs to `stamps(covering:)`, which exists to expose it.
  public func stampLog() async -> StampLog {
    let buffer = Int64(scenario.bufferFrames)
    let callbacks = Int(Swift.max(0, framesProcessed - inputOrigin) / buffer)
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

  public func permissionStatus() async -> PermissionStatus { scenario.permission }

  public func stop() async {
    started = false
    eventContinuation.finish()
  }

  // MARK: - The virtual clocks

  /// The input device's clock drift against the host. On a single device the one clock is shared by
  /// both directions; with two, only the input device drifts and the output one is the reference.
  private var inputDriftPPM: Double { scenario.driftPPM }
  private var outputDriftPPM: Double { twoDevices ? 0 : scenario.driftPPM }

  /// Input labels that pass per host second.
  private var inputLabelsPerHostSecond: Double {
    scenario.sampleRate * (1 + inputDriftPPM * 1e-6)
  }

  /// Input frames per second of stimulus. One shared device clock samples the stimulus exactly as
  /// the output played it; a second, drifted clock samples it a little faster or slower.
  private var stimulusFramesPerSecond: Double {
    twoDevices ? inputLabelsPerHostSecond : scenario.sampleRate
  }

  /// The input frame where this hit's stimulus starts. Single device: the output frame plus the
  /// path. Two devices: the same instant on the input device's own clock, which has its own origin
  /// and runs `driftPPM` fast.
  private func arrivalFrame(of hit: ScheduledHit) -> Double {
    let path = scenario.latencyFrames + jitter(forHit: hit.index)
    guard twoDevices else { return Double(hit.outputFrame) + path }
    return Double(inputOrigin)
      + (Double(hit.outputFrame - outputOrigin) + path) * (1 + inputDriftPPM * 1e-6)
  }

  /// The callback with this index, stamped from one virtual host clock. A label maps to host time
  /// through its device's clock rate, so a duplex device's input and output stamps agree unless
  /// `stampBiasFrames` skews the input ones. Output labels run `ioOffsetFrames` ahead of input labels.
  private func callbackStamp(index: Int64) -> CallbackStamp {
    let buffer = Int64(scenario.bufferFrames)
    let inputLabel = inputOrigin + index * buffer
    let outputLabel = outputOrigin + index * buffer + Int64(scenario.ioOffsetFrames)
    let bias = Self.hostClock.ticks(
      forFrames: scenario.stampBiasFrames, sampleRate: scenario.sampleRate)
    let inputHost = UInt64(
      Swift.max(
        0,
        (Double(hostTicks(label: inputLabel, origin: inputOrigin, driftPPM: inputDriftPPM)) + bias)
          .rounded()))
    return CallbackStamp(
      inputSampleTime: Double(inputLabel), inputHostTime: inputHost,
      inputRateScalar: Self.rateScalar(driftPPM: inputDriftPPM),
      outputSampleTime: Double(outputLabel),
      outputHostTime: hostTicks(label: outputLabel, origin: outputOrigin, driftPPM: outputDriftPPM),
      outputRateScalar: Self.rateScalar(driftPPM: outputDriftPPM),
      frames: scenario.bufferFrames)
  }

  /// Host ticks at which a device whose labels start at `origin` reads `label`.
  private func hostTicks(label: Int64, origin: Int64, driftPPM: Double) -> UInt64 {
    let seconds = Double(label - origin) / (scenario.sampleRate * (1 + driftPPM * 1e-6))
    return Self.hostEpochTicks + Self.hostClock.nanosToWholeTicks(seconds * 1e9)
  }

  /// Apple's definition: actual host ticks per frame over the nominal ones. A clock that runs
  /// fast spends fewer ticks per frame.
  private static func rateScalar(driftPPM: Double) -> Double { 1 / (1 + driftPPM * 1e-6) }

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
