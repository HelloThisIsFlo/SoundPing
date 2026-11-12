import Foundation

/// What `--in-channel auto` heard on one input channel.
public struct ChannelScore: Codable, Sendable, Equatable {
  public var index: Int
  public var name: String
  /// The best confidence any probe on this channel reached.
  public var confidence: Double
  /// The level of the probe that reached it.
  public var levelDbfs: Double

  public init(index: Int, name: String, confidence: Double, levelDbfs: Double) {
    self.index = index
    self.name = name
    self.confidence = confidence
    self.levelDbfs = levelDbfs
  }
}

/// The channel that heard the chirp, how sure SoundPing is, and by how much it beat the runner-up.
public struct ChannelChoice: Codable, Sendable, Equatable {
  public var index: Int
  public var name: String
  public var confidence: Double
  public var margin: Double

  public init(index: Int, name: String, confidence: Double, margin: Double) {
    self.index = index
    self.name = name
    self.confidence = confidence
    self.margin = margin
  }
}

/// The result of `soundping run … --in-channel auto`: a probe, never a measurement. `--json` prints
/// exactly this object.
public struct ChannelProbeResult: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var type: String
  /// Every input channel, best first.
  public var channels: [ChannelScore]
  public var chosen: ChannelChoice
  /// Whether the choice was written into a saved setup.
  public var saved: Bool
  /// How to keep the choice when it was not saved.
  public var saveHint: String?

  public init(
    channels: [ChannelScore], chosen: ChannelChoice, saved: Bool = false, saveHint: String? = nil
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.type = "channelProbe"
    self.channels = channels
    self.chosen = chosen
    self.saved = saved
    self.saveHint = saveHint
  }
}

/// Finds the input channel that hears the chirp (D-11).
///
/// For each input channel of the resolved device it opens the backend on that channel, plays the
/// chirp from -48 dBFS in 12 dB steps up to the ceiling until it is heard clearly, and closes the
/// backend again, so the real-time capture path is the one a measurement uses. The channels are
/// then ranked by the best confidence they reached. The winner has to beat the runner-up by
/// `minMargin`, or the answer is `inChannelAmbiguous`: SoundPing never picks between two channels
/// that hear about the same. This is a probe: it writes no run and measures nothing.
public struct ChannelProbe: Sendable {
  /// The winner must beat the runner-up by this much confidence, or the answer is ambiguous.
  public static let minMargin = 0.2
  /// A channel that never reaches this heard nothing at all.
  public static let minConfidence = 0.5
  /// Probe levels climb in these steps from -48 dBFS up to the ceiling.
  public static let stepUpDb = 12.0
  /// Audio that does not arrive within this long on one channel is a stopped device.
  static let channelDeadline = Duration.seconds(60)

  public let resolver: any ResponsibleAppResolving

  public init(resolver: any ResponsibleAppResolving = ProcessTreeResolver()) {
    self.resolver = resolver
  }

  /// The listener whose ceiling the probe plays under: the `--listener` override's, else
  /// headphones when the output device is treated as headphones (any Bluetooth output, or a built-in
  /// output that is not clearly the speakers, -30 dBFS), else unknown (-18 dBFS). The
  /// channel is not known yet, so it cannot say whether it is a loopback, but whether the sound
  /// reaches a person's ears depends on the output device alone (T-01-28). A louder kind than the
  /// unknown one is never taken.
  static func listenerKind(
    options: PreflightOptions, setup: ResolvedSetup, output: DeviceInfo?
  ) -> ListenerKind {
    if let override = options.listener { return override }
    return LevelRamp.outputIsHeadphones(setup: setup, output: output) ? .headphones : .unknown
  }

  /// `setup` names the devices; `inChannel` is ignored and replaced by each of `channels` in turn.
  /// The ceiling is the `--listener` override's, else the headphone ceiling for known headphones,
  /// else the unknown listener's (-18 dBFS); see `listenerKind`.
  public func run(
    backend: any AudioBackend, setup: ResolvedSetup, channels: [ChannelInfo],
    options: PreflightOptions = PreflightOptions(), templateId: String = "chirp-loopback"
  ) async throws -> ChannelProbeResult {
    guard !channels.isEmpty else {
      throw SoundPingError.usage(
        "deviceHasNoChannels", "\(setup.input.name) has no input channels to probe",
        context: ["device": setup.input.uid])
    }
    // Refuses a bad `--max-level` before anything plays; replaced once the output device is known.
    var listener = options.listener ?? .unknown
    var ceiling = try LevelRamp.resolveCeiling(kind: listener, maxLevelDbfs: options.maxLevelDbfs)
    let nominal = try StimulusLibrary.template(id: templateId, sampleRate: 48_000)
    let checks = Preflight(resolver: resolver)

    var scores: [ChannelScore] = []
    var anythingHeard = false
    var app: ResponsibleApp?
    for (position, channel) in channels.enumerated() {
      var channelSetup = setup
      channelSetup.inChannel = channel.index
      channelSetup.inChannelName = channel.name
      channelSetup.autoInChannel = false

      let info = try await backend.open(channelSetup, templates: [nominal])
      let opened = channelSetup
      if position == 0 {
        // The output device is the same for every channel, so it is classified once, before the
        // first sound (CR-02): headphones keep their -30 dBFS ceiling during the probe.
        listener = Self.listenerKind(
          options: options, setup: channelSetup, output: info.outputDevice)
        ceiling = try LevelRamp.resolveCeiling(kind: listener, maxLevelDbfs: options.maxLevelDbfs)
      }
      let probeCeiling = ceiling
      do {
        if position == 0 {
          app = try await checks.checkPermission(on: backend).app
          try await checks.checkOutput(on: backend)
        }
        let score = try await withDeadline {
          try await Self.probe(
            channel: channel, ceiling: probeCeiling, nominal: nominal, info: info, setup: opened,
            backend: backend)
        }
        anythingHeard = anythingHeard || score.heardSomething
        scores.append(score.score)
      } catch {
        await backend.stop()
        throw error
      }
      await backend.stop()
    }

    let ranked = scores.sorted {
      $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.index < $1.index
    }
    guard let best = ranked.first, best.confidence >= Self.minConfidence else {
      if !anythingHeard {
        throw Preflight.silenceError(device: setup.input.name, channel: nil)
      }
      throw Preflight.nothingHeardError(
        ceilingDbfs: ceiling, listener: listener, probes: scores.count, chosenLevel: nil,
        terminalApp: app?.name)
    }

    let runnerUp = ranked.dropFirst().first
    let margin = best.confidence - (runnerUp?.confidence ?? 0)
    guard margin >= Self.minMargin else {
      let close = ranked.filter { best.confidence - $0.confidence < Self.minMargin }
      let candidates = close.map { score in
        String(format: "%d = %@ (confidence %.2f)", score.index, score.name, score.confidence)
      }.joined(separator: ", ")
      throw SoundPingError.preflight(
        "inChannelAmbiguous",
        "More than one input channel hears the chirp about equally well: \(candidates)",
        context: [
          "candidates": candidates,
          "fix":
            "pick the channel yourself with --in-channel N (`soundping devices` lists them), or unplug whatever else feeds the other inputs",
        ])
    }
    return ChannelProbeResult(
      channels: ranked,
      chosen: ChannelChoice(
        index: best.index, name: best.name, confidence: best.confidence, margin: margin))
  }

  private struct Probed {
    var score: ChannelScore
    var heardSomething: Bool
  }

  /// One channel: climb from -48 dBFS to the ceiling until the chirp is heard clearly, keeping the
  /// best confidence. An all-zero channel is dead and is not played louder; a clipping one is
  /// already loud enough.
  private static func probe(
    channel: ChannelInfo, ceiling: Double, nominal: StimulusTemplate, info: BackendInfo,
    setup: ResolvedSetup, backend: any AudioBackend
  ) async throws -> Probed {
    let info = try await backend.start()
    let template = try nominal.atSampleRate(info.sampleRate)
    var listener = HitListener(
      backend: backend, info: info, templateFrames: Int64(template.samples.count),
      maxLatencyMs: RunParameters(seed: 0).maxLatencyMs,
      twoDevice: setup.output.uid != setup.input.uid, monitor: nil)
    try await listener.prepareClockMapping()
    var player = ProbePlayer(backend: backend, template: template)

    var level = Swift.min(LevelRamp.firstProbeDbfs, ceiling)
    var best = ChannelScore(
      index: channel.index, name: channel.name, confidence: 0, levelDbfs: level)
    var heardSomething = false
    while true {
      try Task.checkCancellation()
      let played = try await player.play(atLevel: level, using: &listener)
      if played.silent { break }
      heardSomething = true
      if played.record.confidence > best.confidence {
        best.confidence = played.record.confidence
        best.levelDbfs = level
      }
      if played.record.confidence >= LevelRamp.confidenceTarget
        || played.record.peakDbfs >= LevelRamp.clippingDbfs || level >= ceiling
      {
        break
      }
      level = Swift.min(ceiling, level + stepUpDb)
    }
    return Probed(score: best, heardSomething: heardSomething)
  }

  /// A device that stops delivering audio would leave the wait for samples hanging; nobody is
  /// listening to its events here, so a deadline per channel ends it.
  private func withDeadline<T: Sendable>(_ work: @escaping @Sendable () async throws -> T)
    async throws -> T
  {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await work() }
      group.addTask {
        try await Task.sleep(for: Self.channelDeadline)
        throw SoundPingError.deviceChanged(
          "ioStopped", "no audio arrived within \(Self.channelDeadline) on one input channel")
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw SoundPingError.internalFailure("noResult", "the channel probe produced nothing")
      }
      return first
    }
  }
}
