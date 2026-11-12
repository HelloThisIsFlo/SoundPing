import Foundation

/// Runs a recipe against an `AudioBackend` and narrates it as a stream of `RunEvent`s (D-03).
/// Every renderer, the saved run.json and the later app read this one stream.
public actor RunCoordinator {
  private let backend: any AudioBackend
  private let store: RunStore
  private let resolver: any ResponsibleAppResolving

  /// `resolver` names the app that owns microphone consent when a run is refused for lack of it;
  /// tests pass a fake, everything else the process-tree walk.
  public init(
    backend: any AudioBackend, store: RunStore,
    resolver: any ResponsibleAppResolving = ProcessTreeResolver()
  ) {
    self.backend = backend
    self.store = store
    self.resolver = resolver
  }

  public nonisolated func run(_ request: RunRequest) -> AsyncThrowingStream<RunEvent, Error> {
    AsyncThrowingStream(RunEvent.self) { continuation in
      let session = Session(
        backend: backend, store: store, request: request, resolver: resolver,
        continuation: continuation)
      let task = Task {
        do {
          try await session.run()
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private enum Outcome: Sendable {
  case measured(RunResult)
  case eventsEnded
}

/// What the checks before the first sound settled: who owns the microphone permission, who will
/// hear the sound, how loud it may get and which chirp it is.
private struct PreflightPlan: Sendable {
  var permission: Preflight.PermissionOutcome
  var listener: ListenerKind
  var ceilingDbfs: Double
  var templateId: String
  var warnings: [String]
}

/// The level the ramp settled on, with the probes that got there.
private struct LockedLevel: Sendable {
  var levelDbfs: Double
  var probes: [ProbeRecord]
  var warnings: [String]
}

/// One run, start to finish. Never sleeps on the wall clock: it waits on sample positions.
private struct Session: Sendable {
  let backend: any AudioBackend
  let store: RunStore
  let request: RunRequest
  let resolver: any ResponsibleAppResolving
  let continuation: AsyncThrowingStream<RunEvent, Error>.Continuation

  func run() async throws {
    let parameters = request.parameters
    let nominals = try candidateTemplates()
    try HitScheduler.validate(parameters, templateDurationMs: nominals[0].durationMs)
    // A store file this build cannot read fails the run now, before any audio, not after it (T-01-21).
    _ = try ClockSelfTestStore.load(from: store.paths.clockSelfTest)
    _ = try CalibrationStore.load(from: store.paths.calibrations)

    let result: RunResult
    do {
      let info = try await backend.open(request.setup, templates: nominals)
      let plan = try await preflight(info: info)
      result = try await supervise(info: info, plan: plan, nominals: nominals)
      await backend.stop()
    } catch {
      await backend.stop()
      throw error
    }
    continuation.yield(.finished(result))
  }

  /// The requested template first, then both chirp bands when the listener picks the band.
  private func candidateTemplates() throws -> [StimulusTemplate] {
    var ids = [request.parameters.templateId]
    if request.preflight.templateFollowsListener {
      for id in ["chirp-loopback", "chirp-speaker"] where !ids.contains(id) { ids.append(id) }
    }
    return try ids.map { try StimulusLibrary.template(id: $0, sampleRate: 48_000) }
  }

  /// A named failure is announced on the stream, then thrown.
  private func fail(_ error: SoundPingError) -> SoundPingError {
    continuation.yield(.aborted(error))
    return error
  }

  /// The checks before any sound is played, in their fixed order: microphone permission, then the
  /// output's mute and volume. The level ramp is the third check and runs once the audio is going.
  private func preflight(info: BackendInfo) async throws -> PreflightPlan {
    let checks = Preflight(resolver: resolver)
    do {
      let permission = try await checks.checkPermission(on: backend)
      try await checks.checkOutput(on: backend)
      let listener =
        request.preflight.listener
        ?? LevelRamp.classify(
          setup: request.setup, output: info.outputDevice, input: info.inputDevice)
      let ceiling = try LevelRamp.resolveCeiling(
        kind: listener, maxLevelDbfs: request.preflight.maxLevelDbfs)
      let templateId =
        request.preflight.templateFollowsListener
        ? LevelRamp.templateId(for: listener) : request.parameters.templateId
      return PreflightPlan(
        permission: permission, listener: listener, ceilingDbfs: ceiling, templateId: templateId,
        warnings: [])
    } catch let error as SoundPingError {
      throw fail(error)
    }
  }

  /// Measures while listening for device events; a device change aborts the run (ENG-07).
  private func supervise(info: BackendInfo, plan: PreflightPlan, nominals: [StimulusTemplate])
    async throws -> RunResult
  {
    let monitor = FaultMonitor()
    let backend = self.backend
    let continuation = self.continuation
    return try await withThrowingTaskGroup(of: Outcome.self) { group in
      group.addTask {
        for await event in backend.events {
          if case .overload(_, let frame) = event {
            monitor.recordOverload(atInputFrame: frame)
            continue
          }
          let error = Session.abortError(for: event)
          continuation.yield(.aborted(error))
          throw error
        }
        return .eventsEnded
      }
      group.addTask {
        .measured(
          try await measure(info: info, plan: plan, nominals: nominals, monitor: monitor))
      }
      while let outcome = try await group.next() {
        if case .measured(let result) = outcome {
          group.cancelAll()
          return result
        }
      }
      throw SoundPingError.internalFailure("noResult", "the run ended without a result")
    }
  }

  private static func abortError(for event: DeviceEvent) -> SoundPingError {
    switch event {
    case .gone(let uid):
      return .deviceChanged(
        "deviceGone", "device '\(uid)' disappeared during the run", context: ["uid": uid])
    case .sampleRateChanged(let uid, let from, let to):
      return .deviceChanged(
        "sampleRateChanged", "device '\(uid)' changed sample rate from \(from) to \(to) Hz",
        context: ["uid": uid, "from": String(from), "to": String(to)])
    case .bufferSizeChanged(let uid, let from, let to):
      return .deviceChanged(
        "bufferSizeChanged", "device '\(uid)' changed buffer size from \(from) to \(to) frames",
        context: ["uid": uid, "from": String(from), "to": String(to)])
    case .streamConfigChanged(let uid):
      return .deviceChanged(
        "streamConfigChanged", "device '\(uid)' changed its stream configuration",
        context: ["uid": uid])
    case .ioStopped(let uid):
      return .deviceChanged(
        "ioStopped", "device '\(uid)' stopped unexpectedly", context: ["uid": uid])
    case .overload(let uid, _):
      return .internalFailure("unexpectedOverload", "overload on '\(uid)' is not an abort")
    }
  }

  private func measure(
    info: BackendInfo, plan: PreflightPlan, nominals: [StimulusTemplate], monitor: FaultMonitor
  ) async throws -> RunResult {
    // The folder exists before `armed` is announced, so the run id on the stream is the final one,
    // collision suffix included. A run that dies before run.json is written takes its empty folder along.
    let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let folder = try store.createRunFolder(
      recipeId: request.recipe.id, label: request.label, createdAt: createdAt)
    do {
      return try await measure(
        info: info, plan: plan, nominals: nominals, monitor: monitor, folder: folder,
        createdAt: createdAt)
    } catch {
      Self.removeIfEmpty(folder)
      throw error
    }
  }

  private static func removeIfEmpty(_ folder: URL) {
    let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    if entries?.isEmpty == true { try? FileManager.default.removeItem(at: folder) }
  }

  private func measure(
    info: BackendInfo, plan: PreflightPlan, nominals: [StimulusTemplate], monitor: FaultMonitor,
    folder: URL, createdAt: Date
  ) async throws -> RunResult {
    var parameters = request.parameters
    parameters.templateId = plan.templateId
    let recipe = request.recipe
    let sampleRate = info.sampleRate
    guard let nominal = nominals.first(where: { $0.id == plan.templateId }) else {
      throw SoundPingError.internalFailure(
        "unknownTemplate", "the template '\(plan.templateId)' was never opened")
    }
    let template = try nominal.atSampleRate(sampleRate)

    let runId = folder.lastPathComponent
    let snapshot = SetupSnapshot(
      setup: request.setup, sampleRate: sampleRate, bufferFrames: info.bufferFrames,
      simulated: info.simulation != nil)

    try await backend.start()
    var listener = HitListener(
      backend: backend, info: info, templateFrames: Int64(template.samples.count),
      maxLatencyMs: parameters.maxLatencyMs,
      twoDevice: request.setup.output.uid != request.setup.input.uid, monitor: monitor)
    try await listener.prepareClockMapping()

    // The third check: find the level, then lock it for every warm-up and measured hit (D-14).
    let locked = try await lockLevel(plan: plan, template: template, listener: &listener)
    continuation.yield(
      .levelLocked(
        LevelLock(
          levelDbfs: locked.levelDbfs, listenerKind: plan.listener, ceilingDbfs: plan.ceilingDbfs,
          templateId: plan.templateId)))
    let report = PreflightReport(
      permission: plan.permission.status, terminalApp: plan.permission.app.name,
      listenerKind: plan.listener, ceilingDbfs: plan.ceilingDbfs,
      lockedLevelDbfs: locked.levelDbfs, templateId: plan.templateId, probes: locked.probes,
      warnings: plan.warnings + locked.warnings)

    continuation.yield(
      .armed(ArmedInfo(runId: runId, recipe: recipe.ref, parameters: parameters, setup: snapshot)))

    guard locked.levelDbfs.isFinite else {
      throw SoundPingError.internalFailure(
        "nonFiniteLevel", "the locked level is not a finite dBFS value (\(locked.levelDbfs))")
    }
    let scheduled = HitScheduler.schedule(
      parameters: parameters,
      startFrame: await backend.currentOutputFrame(),
      sampleRate: sampleRate,
      gain: Float(pow(10, locked.levelDbfs / 20)),
      templateId: template.id)
    try await backend.schedule(scheduled)

    let correlator = Correlator(template: template)
    var records: [HitRecord] = []
    for hit in scheduled {
      try Task.checkCancellation()
      let heard = try await listener.listen(to: hit, with: correlator)

      var record = HitRecord(
        index: hit.index,
        phase: HitScheduler.phase(forHit: hit.index, warmup: parameters.warmup),
        outputFrame: hit.outputFrame)
      switch heard.detection {
      case .found(_, let confidence, let psr, _):
        let latency = heard.latencyFrames ?? 0
        record.latencyFrames = latency
        record.latencyMs = latency / sampleRate * 1000
        record.confidence = confidence
        record.psr = psr
        continuation.yield(.hit(record))
      case .rejected(let reason):
        record.rejection = reason
        continuation.yield(.rejected(record))
      }
      records.append(record)
    }

    return try await finish(
      records: records, info: info, snapshot: snapshot, parameters: parameters,
      preflight: report, folder: folder, createdAt: createdAt)
  }

  // MARK: Level ramp

  /// Plays uncounted probes until the chirp is heard clearly, and names the cause when it cannot
  /// be: only zeros, a clipping input, or nothing even at the ceiling (ENG-03, D-14). Each probe
  /// is an event on the stream and an entry in the saved report; none is a hit.
  private func lockLevel(
    plan: PreflightPlan, template: StimulusTemplate, listener: inout HitListener
  ) async throws -> LockedLevel {
    let fixed = request.parameters.levelDbfs
    var ramp = LevelRamp(ceilingDbfs: plan.ceilingDbfs, fixedLevelDbfs: fixed)
    var warnings: [String] = []
    if let fixed, fixed > plan.ceilingDbfs {
      warnings.append(
        String(
          format:
            "--level %.0f dBFS is above the %.0f dBFS ceiling for a %@ listener, so %.0f dBFS is used; pass --max-level to raise the ceiling",
          fixed, plan.ceilingDbfs, plan.listener.rawValue, plan.ceilingDbfs))
    }

    var player = ProbePlayer(backend: backend, template: template)
    var probes: [ProbeRecord] = []
    var level = ramp.firstLevel
    while true {
      try Task.checkCancellation()
      let played = try await player.play(atLevel: level, using: &listener)
      if played.silent { throw fail(await silenceError()) }
      probes.append(played.record)
      continuation.yield(.probe(played.record))

      switch ramp.record(
        level: level, confidence: played.record.confidence, peakDbfs: played.record.peakDbfs)
      {
      case .probe(let next):
        level = next
      case .lock(let locked, let warning):
        if let warning { warnings.append(warning) }
        return LockedLevel(levelDbfs: locked, probes: probes, warnings: warnings)
      case .fail(.clipping):
        throw fail(
          Preflight.clippingError(peakDbfs: played.record.peakDbfs, levelDbfs: level))
      case .fail(.nothingHeard):
        throw fail(
          Preflight.nothingHeardError(
            ceilingDbfs: plan.ceilingDbfs, listener: plan.listener, probes: probes.count,
            chosenLevel: fixed, terminalApp: plan.permission.app.name))
      }
    }
  }

  /// All-zero input is the permission when the system now says access is denied, and a dead
  /// signal path otherwise (a muted source, a wrong channel, a virtual device with nothing in it).
  private func silenceError() async -> SoundPingError {
    let status = await backend.permissionStatus()
    if let denied = Preflight.permissionError(status: status, app: resolver.resolve()) {
      return denied
    }
    return Preflight.silenceError(
      device: request.setup.input.name, channel: request.setup.inChannelName)
  }

  // MARK: Result

  /// Warm-ups stay in hits[] but never enter a statistic (D-04).
  private func finish(
    records: [HitRecord], info: BackendInfo, snapshot: SetupSnapshot, parameters: RunParameters,
    preflight: PreflightReport, folder: URL, createdAt: Date
  ) async throws -> RunResult {
    let runId = folder.lastPathComponent
    let measured = records.filter { $0.phase == .measure }
    let latencies = measured.compactMap { $0.rejection == nil ? $0.latencyFrames : nil }
    let stats = Stats.summarize(
      latencies: latencies, n: measured.count, sampleRate: info.sampleRate)

    var rejectedCounts = Dictionary(
      uniqueKeysWithValues: RejectionReason.allCases.map { ($0.rawValue, 0) })
    for record in measured {
      if let reason = record.rejection { rejectedCounts[reason.rawValue, default: 0] += 1 }
    }

    let sameDevice = request.setup.output.uid == request.setup.input.uid
    let log = await backend.stampLog()
    var figures = Measured(headline: .path, domain: sameDevice ? .sample : .host, path: stats)
    var selfTest: ClockSelfTestResult?
    var hostTimebase: HostTimebase?
    if !log.isEmpty { hostTimebase = info.hostClock.timebase }

    if sameDevice, !log.isEmpty {
      // The distance the app adds on top of the path: how far its output labels run ahead of its
      // input labels in the same callback. Read per callback, never assumed (RES-02).
      let ioOffsets = zip(log.input, log.output).map { $1.sampleTime - $0.sampleTime }
      let ioStats = Stats.summarize(
        latencies: ioOffsets, n: ioOffsets.count, sampleRate: info.sampleRate)
      if let medianIo = ioStats.median?.frames {
        figures.ioOffset = ioStats
        figures.appRoundTrip = Stats.summarize(
          latencies: latencies.map { $0 + medianIo }, n: measured.count,
          sampleRate: info.sampleRate)
        figures.headline = .appRoundTrip
      }

      // A same-device run proves its own clock before it reports (CAL-03, D-05).
      var halTimes: [Int: UInt64] = [:]
      for hit in measured where hit.rejection == nil {
        guard let path = hit.latencyFrames else { continue }
        let sample = Double(hit.outputFrame) + path
        if let host = await backend.halHostTime(forInputSample: sample) {
          halTimes[hit.index] = host
        }
      }
      let evaluated = ClockSelfTest.evaluate(
        hits: records, stampLog: log, sampleRate: info.sampleRate, hostClock: info.hostClock,
        halInputHostTimes: halTimes)
      selfTest = evaluated
      continuation.yield(.selfTest(evaluated))
    }

    // What macOS says about these devices, shown beside the measurement and never applied to it.
    var reported: ReportedLatency?
    if let outputDevice = info.outputDevice, let inputDevice = info.inputDevice {
      reported = ReportedLatency.compute(
        output: outputDevice, outChannels: request.setup.outChannels, input: inputDevice,
        inChannel: request.setup.inChannel, bufferFrames: info.bufferFrames,
        sampleRate: info.sampleRate)
    }

    var result = RunResult(
      runId: runId,
      runPath: "",
      createdAt: createdAt,
      toolVersion: SoundPingInfo.version,
      os: Self.operatingSystem(),
      recipe: request.recipe.ref,
      label: request.label,
      tags: request.tags,
      parameters: parameters,
      setup: snapshot,
      measured: figures,
      histogram: Stats.histogram(latencies: latencies),
      hits: records,
      rejectedCounts: rejectedCounts,
      segments: request.recipe.segments,
      corrections: [],
      simulation: info.simulation,
      selfTest: selfTest,
      hostTimebase: hostTimebase,
      reported: reported,
      preflight: preflight)

    result.runPath = folder.path
    let calibration = calibrationToStore(
      figures: figures, info: info, runId: runId, createdAt: createdAt)
    result.calibration = calibration.ref
    // run.json goes first: if it cannot be written, no calibration or self-test record is left
    // pointing at a run that does not exist (WR-02).
    try store.write(result, to: folder)
    if let record = calibration.record {
      try CalibrationStore.record(record, in: store.paths.calibrations)
    }
    if let selfTest {
      let key = ClockSelfTestKey(
        deviceUID: request.setup.output.uid, sampleRate: info.sampleRate,
        bufferFrames: info.bufferFrames)
      try ClockSelfTestStore.record(
        ClockSelfTestEntry(key: key, result: selfTest, runId: runId, measuredAt: createdAt),
        in: store.paths.clockSelfTest)
    }
    return result
  }

  /// A run that passes the valid-hit gate leaves a round-trip calibration keyed by its whole path
  /// (CAL-02); one that does not leaves nothing, and its result says so. This only decides; the
  /// caller writes the record once run.json is safely on disk. The calibration is a
  /// measurement kept for later comparison. It is never subtracted from anything (ENG-06).
  private func calibrationToStore(
    figures: Measured, info: BackendInfo, runId: String, createdAt: Date
  ) -> (ref: CalibrationRef, record: CalibrationRecord?) {
    let setup = request.setup
    let key = CalibrationKey(
      outputUID: setup.output.uid, outChannels: setup.outChannels, inputUID: setup.input.uid,
      inChannel: setup.inChannel, sampleRate: info.sampleRate, bufferFrames: info.bufferFrames)

    let path = figures.path
    let headline = figures.headlineStats
    guard let path, let headline, let value = headline.median, let pathMedian = path.median,
      path.valid >= request.parameters.requiredValidHits
    else {
      return (CalibrationRef(key: key, stored: false), nil)
    }
    let record = CalibrationRecord(
      key: key, headline: figures.headline, valueFrames: value.frames, valueMs: value.ms,
      pathFrames: pathMedian.frames, appRoundTripFrames: figures.appRoundTrip?.median?.frames,
      jitterFrames: headline.jitter?.frames ?? 0, valid: path.valid, n: path.n,
      domain: figures.domain, runId: runId, measuredAt: createdAt)
    return (CalibrationRef(key: key, stored: true), record)
  }

  private static func operatingSystem() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }
}
