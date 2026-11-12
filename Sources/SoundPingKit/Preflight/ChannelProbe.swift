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

  /// `setup` names the devices; `inChannel` is ignored and replaced by each of `channels` in turn.
  /// The probe plays under the run's loudness rule (`LevelRamp.runLoudness`, written down at
  /// `LevelRamp.loudness`): the output alone sets the ceiling, `--listener` can only lower it, and
  /// `--max-level` replaces it (T-01-28).
  public func run(
    backend: any AudioBackend, setup: ResolvedSetup, channels: [ChannelInfo],
    options: PreflightOptions = PreflightOptions(), templateId: String = "chirp-loopback"
  ) async throws -> ChannelProbeResult {
    guard !channels.isEmpty else {
      throw SoundPingError.usage(
        "deviceHasNoChannels", "\(setup.input.name) has no input channels to probe",
        context: ["device": setup.input.uid])
    }
    // Refuses a bad `--max-level` before anything plays; the loudness is decided once the output
    // device is known, before the first sound.
    if let maxLevel = options.maxLevelDbfs { _ = try LevelRamp.validatedMaxLevel(maxLevel) }
    // The loudness is the run's, worked out before the channel is known, so it never depends on
    // which channel is being probed.
    var unprobed = setup
    unprobed.inChannelName = nil
    // The loudness decided at the first open, and the output route (data source and jack state)
    // it was decided with.
    var decided: (loudness: LevelRamp.Loudness, dataSource: String?, jack: String?)?
    let nominal = try StimulusLibrary.template(id: templateId, sampleRate: 48_000)
    let checks = Preflight(resolver: resolver)

    var scores: [ChannelScore] = []
    var anythingHeard = false
    var anyUnjudged = false
    var app: ResponsibleApp?
    for (position, channel) in channels.enumerated() {
      var channelSetup = setup
      channelSetup.inChannel = channel.index
      channelSetup.inChannelName = channel.name
      channelSetup.autoInChannel = false

      let info = try await backend.open(channelSetup, templates: [nominal])
      let opened = channelSetup
      // The output device is the same for every channel, so its loudness is decided at the first
      // open, before the first sound (CR-02): headphones keep their -30 dBFS ceiling during the
      // probe, whatever --listener says (WR-13). Each reopen reads the output again and must still
      // see the route that loudness was decided with (WR-15): the backend's route watching starts
      // over at every open, so a switch between two channels (speakers to headphones) would
      // otherwise go unseen while the first channel's ceiling stays in force.
      let loudness = try LevelRamp.runLoudness(
        setup: unprobed, output: info.outputDevice, input: info.inputDevice, options: options)
      // The data source and the jack state are both carried, so a jack change alone (one whose
      // data source does not move with it) ends the probe too.
      let dataSource = info.outputDevice?.output?.dataSource
      let jack = info.outputJack
      if let decided {
        var moved: (property: String, from: String?, to: String?)?
        if dataSource != decided.dataSource {
          moved = ("dataSource", decided.dataSource, dataSource)
        } else if jack != decided.jack {
          moved = ("jackIsConnected", decided.jack, jack)
        } else if loudness != decided.loudness {
          moved = ("outputKind", decided.loudness.output.rawValue, loudness.output.rawValue)
        }
        if let moved {
          await backend.stop()
          throw SoundPingError.forDeviceEvent(
            .outputRouteChanged(
              uid: setup.output.uid, property: moved.property, from: moved.from ?? "none",
              to: moved.to ?? "none"))
        }
      } else {
        decided = (loudness, dataSource, jack)
      }
      let probeCeiling = loudness.ceilingDbfs
      do {
        if position == 0 {
          app = try await checks.checkPermission(on: backend).app
          try await checks.checkOutput(on: backend)
        }
        let score = try await withDeadline(watching: backend) {
          try await Self.probe(
            channel: channel, ceiling: probeCeiling, nominal: nominal, info: info, setup: opened,
            backend: backend)
        }
        anythingHeard = anythingHeard || score.heardSomething
        anyUnjudged = anyUnjudged || score.unjudged
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
      // Only zeros everywhere is a dead signal path; probes spoilt by glitches said nothing either
      // way, so they never make it "only zeros".
      if !anythingHeard, !anyUnjudged {
        throw Preflight.silenceError(device: setup.input.name, channel: nil)
      }
      guard let loudness = decided?.loudness else {
        throw SoundPingError.internalFailure("noLoudness", "the probe has no ceiling")
      }
      throw Preflight.nothingHeardError(
        loudness: loudness, probes: scores.count, playedLevel: nil, terminalApp: app?.name)
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
    /// A probe that was judged heard something (not only zeros).
    var heardSomething: Bool
    /// A probe stayed spoilt by glitches after its replays, so this channel was not fully judged.
    var unjudged: Bool
  }

  /// One channel: climb from -48 dBFS to the ceiling until the chirp is heard clearly, keeping the
  /// best confidence. An all-zero channel is dead and is not played louder; a clipping one is
  /// already loud enough. A probe spoilt by an overload or a lost-frames gap was not judged, so it
  /// is replayed at the same level (at most `LevelRamp.maxGlitchRetries` times, as the level ramp
  /// does) and never counts as heard (IN-19).
  private static func probe(
    channel: ChannelInfo, ceiling: Double, nominal: StimulusTemplate, info: BackendInfo,
    setup: ResolvedSetup, backend: any AudioBackend
  ) async throws -> Probed {
    let info = try await backend.start()
    let template = try nominal.atSampleRate(info.sampleRate)
    var listener = HitListener(
      backend: backend, info: info, templateFrames: Int64(template.samples.count),
      maxLatencyMs: RunParameters(seed: 0).maxLatencyMs,
      twoDevice: setup.output.uid != setup.input.uid)
    try await listener.prepareClockMapping()
    var player = ProbePlayer(backend: backend, template: template)

    var level = Swift.min(LevelRamp.firstProbeDbfs, ceiling)
    var best = ChannelScore(
      index: channel.index, name: channel.name, confidence: 0, levelDbfs: level)
    var heardSomething = false
    var unjudged = false
    var glitchRetries = 0
    while true {
      try Task.checkCancellation()
      let played = try await player.play(atLevel: level, using: &listener)
      if played.silent { break }
      if played.glitched {
        if glitchRetries < LevelRamp.maxGlitchRetries {
          glitchRetries += 1
          continue
        }
        unjudged = true
      } else {
        heardSomething = true
        if played.record.confidence > best.confidence {
          best.confidence = played.record.confidence
          best.levelDbfs = level
        }
        if played.record.confidence >= LevelRamp.confidenceTarget
          || played.record.peakDbfs >= LevelRamp.clippingDbfs
        {
          break
        }
      }
      if level >= ceiling { break }
      level = Swift.min(ceiling, level + stepUpDb)
      glitchRetries = 0
    }
    return Probed(score: best, heardSomething: heardSomething, unjudged: unjudged)
  }

  /// One channel's probe, raced against the backend's device events and a deadline. A sample-rate,
  /// buffer, stream-layout or device change ends the probe with the matching `deviceChanged` error,
  /// as it ends a run (IN-10): scores from before and after a change are never ranked together. An
  /// overload is not an event: a glitched probe is rejected by its recorded fault interval. A device
  /// that stops delivering audio altogether would leave the wait for samples hanging, so a deadline
  /// per channel ends that too.
  private func withDeadline<T: Sendable>(
    watching backend: any AudioBackend, _ work: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await work() }
      group.addTask {
        for await event in backend.events {
          throw SoundPingError.forDeviceEvent(event)
        }
        // The stream ended (the backend was stopped): nothing to report, wait to be cancelled.
        try await Task.sleep(for: .seconds(24 * 3600))
        throw CancellationError()
      }
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
