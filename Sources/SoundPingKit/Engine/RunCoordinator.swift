import Foundation
import Synchronization

/// Runs a recipe against an `AudioBackend` and narrates it as a stream of `RunEvent`s (D-03).
/// Every renderer, the saved run.json and the later app read this one stream.
public actor RunCoordinator {
  private let backend: any AudioBackend
  private let store: RunStore

  public init(backend: any AudioBackend, store: RunStore) {
    self.backend = backend
    self.store = store
  }

  public nonisolated func run(_ request: RunRequest) -> AsyncThrowingStream<RunEvent, Error> {
    AsyncThrowingStream(RunEvent.self) { continuation in
      let session = Session(
        backend: backend, store: store, request: request, continuation: continuation)
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

/// Input frames an audio-thread overload touched, written by the device-event listener and read
/// by the measuring loop.
private final class FaultMonitor: Sendable {
  private let overloads = Mutex<[Int64]>([])

  func recordOverload(atInputFrame frame: Int64) {
    overloads.withLock { $0.append(frame) }
  }

  func hasOverload(in range: Range<Int64>) -> Bool {
    overloads.withLock { $0.contains(where: range.contains) }
  }
}

private enum Outcome: Sendable {
  case measured(RunResult)
  case eventsEnded
}

/// One run, start to finish. Never sleeps on the wall clock: it waits on sample positions.
private struct Session: Sendable {
  let backend: any AudioBackend
  let store: RunStore
  let request: RunRequest
  let continuation: AsyncThrowingStream<RunEvent, Error>.Continuation

  func run() async throws {
    let parameters = request.parameters
    let nominal = try StimulusLibrary.template(id: parameters.templateId, sampleRate: 48_000)
    try HitScheduler.validate(parameters, templateDurationMs: nominal.durationMs)
    // A store file this build cannot read fails the run now, before any audio, not after it (T-01-21).
    _ = try ClockSelfTestStore.load(from: store.paths.clockSelfTest)
    _ = try CalibrationStore.load(from: store.paths.calibrations)

    let result: RunResult
    do {
      let info = try await backend.open(request.setup, templates: [nominal])
      result = try await supervise(info: info, nominal: nominal)
      await backend.stop()
    } catch {
      await backend.stop()
      throw error
    }
    continuation.yield(.finished(result))
  }

  /// Measures while listening for device events; a device change aborts the run (ENG-07).
  private func supervise(info: BackendInfo, nominal: StimulusTemplate) async throws -> RunResult {
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
        .measured(try await measure(info: info, nominal: nominal, monitor: monitor))
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

  private func measure(info: BackendInfo, nominal: StimulusTemplate, monitor: FaultMonitor)
    async throws -> RunResult
  {
    // The folder exists before `armed` is announced, so the run id on the stream is the final one,
    // collision suffix included. A run that dies before run.json is written takes its empty folder along.
    let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let folder = try store.createRunFolder(
      recipeId: request.recipe.id, label: request.label, createdAt: createdAt)
    do {
      return try await measure(
        info: info, nominal: nominal, monitor: monitor, folder: folder, createdAt: createdAt)
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
    info: BackendInfo, nominal: StimulusTemplate, monitor: FaultMonitor, folder: URL,
    createdAt: Date
  ) async throws -> RunResult {
    let parameters = request.parameters
    let recipe = request.recipe
    let sampleRate = info.sampleRate
    let template = try nominal.atSampleRate(sampleRate)
    let templateFrames = Int64(template.samples.count)
    let maxLatencyFrames = Int64((parameters.maxLatencyMs / 1000 * sampleRate).rounded(.up))

    let runId = folder.lastPathComponent
    let snapshot = SetupSnapshot(
      setup: request.setup, sampleRate: sampleRate, bufferFrames: info.bufferFrames,
      simulated: info.simulation != nil)
    continuation.yield(
      .armed(
        ArmedInfo(runId: runId, recipe: recipe.ref, parameters: parameters, setup: snapshot)))

    try await backend.start()
    let twoDevice = request.setup.output.uid != request.setup.input.uid

    // Two devices count their samples separately, so a hit's input window is found through host
    // time: that needs a stretch of callbacks on both sides to fit before the first hit.
    var mapping: HostMapping?
    if twoDevice {
      let first = await backend.currentInputFrame()
      try await backend.waitUntilCaptured(
        throughInputFrame: first + Int64(Self.mappingWarmupCallbacks * info.bufferFrames))
      mapping = try HostMapping(log: await backend.stampLog(), info: info)
    }

    let level = parameters.levelDbfs ?? recipe.startLevelDbfs
    let scheduled = HitScheduler.schedule(
      parameters: parameters,
      startFrame: await backend.currentOutputFrame(),
      sampleRate: sampleRate,
      gain: Float(pow(10, level / 20)),
      templateId: template.id)
    try await backend.schedule(scheduled)

    let correlator = Correlator(template: template)
    let prerollFrames = Int64((Self.windowPrerollMs / 1000 * sampleRate).rounded(.up))
    var records: [HitRecord] = []
    for hit in scheduled {
      try Task.checkCancellation()
      // One device: output and input share their sample labels, so the stimulus is listened for
      // from the frame it was played. Two devices: from where host time puts it on the input clock.
      let range: Range<Int64>
      if let mapping {
        range = mapping.inputWindow(
          forOutputFrame: hit.outputFrame, prerollFrames: prerollFrames,
          lengthFrames: maxLatencyFrames + templateFrames)
      } else {
        range = hit.outputFrame..<(hit.outputFrame + maxLatencyFrames + templateFrames)
      }
      try await backend.waitUntilCaptured(throughInputFrame: range.upperBound)
      if twoDevice { mapping = try HostMapping(log: await backend.stampLog(), info: info) }

      var record = HitRecord(
        index: hit.index,
        phase: HitScheduler.phase(forHit: hit.index, warmup: parameters.warmup),
        outputFrame: hit.outputFrame)
      let detection: Detection
      if monitor.hasOverload(in: range) {
        detection = .rejected(.discontinuity)
      } else {
        let window = try await backend.capture(range)
        let stamps = await backend.stamps(covering: range)
        detection = correlator.detect(
          window: window, windowStartFrame: range.lowerBound, stamps: stamps)
      }

      switch detection {
      case .found(let frame, let confidence, let psr, _):
        // Same device: the distance between the two sample labels. Two devices: the distance
        // between the host times the two labels were stamped with, in frames at the nominal rate.
        let latency =
          mapping?.hostPathFrames(outputFrame: hit.outputFrame, inputSample: frame)
          ?? frame - Double(hit.outputFrame)
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
      records: records, info: info, snapshot: snapshot, folder: folder, createdAt: createdAt)
  }

  /// Listening starts this long before the stimulus is expected, so a mapping that is a few frames
  /// off (or a driver that stamps slightly early) still finds the hit.
  private static let windowPrerollMs = 5.0
  /// Callbacks that must be on record before two devices' clocks are fitted: the fit uses 33.
  private static let mappingWarmupCallbacks = 2 * DeviceTimeline.halfWindow + 8

  /// Warm-ups stay in hits[] but never enter a statistic (D-04).
  private func finish(
    records: [HitRecord], info: BackendInfo, snapshot: SetupSnapshot, folder: URL,
    createdAt: Date
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
      parameters: request.parameters,
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
      reported: reported)

    result.runPath = folder.path
    result.calibration = try storeCalibration(
      figures: figures, info: info, runId: runId, createdAt: createdAt)
    if let selfTest {
      let key = ClockSelfTestKey(
        deviceUID: request.setup.output.uid, sampleRate: info.sampleRate,
        bufferFrames: info.bufferFrames)
      try ClockSelfTestStore.record(
        ClockSelfTestEntry(key: key, result: selfTest, runId: runId, measuredAt: createdAt),
        in: store.paths.clockSelfTest)
    }
    try store.write(result, to: folder)
    return result
  }

  /// A run that passes the valid-hit gate leaves a round-trip calibration keyed by its whole path
  /// (CAL-02); one that does not leaves nothing, and its result says so. The calibration is a
  /// measurement kept for later comparison. It is never subtracted from anything (ENG-06).
  private func storeCalibration(
    figures: Measured, info: BackendInfo, runId: String, createdAt: Date
  ) throws -> CalibrationRef {
    let setup = request.setup
    let key = CalibrationKey(
      outputUID: setup.output.uid, outChannels: setup.outChannels, inputUID: setup.input.uid,
      inChannel: setup.inChannel, sampleRate: info.sampleRate, bufferFrames: info.bufferFrames)

    let path = figures.path
    let headline = figures.headlineStats
    guard let path, let headline, let value = headline.median, let pathMedian = path.median,
      path.valid >= request.parameters.requiredValidHits
    else {
      return CalibrationRef(key: key, stored: false)
    }
    try CalibrationStore.record(
      CalibrationRecord(
        key: key, headline: figures.headline, valueFrames: value.frames, valueMs: value.ms,
        pathFrames: pathMedian.frames, appRoundTripFrames: figures.appRoundTrip?.median?.frames,
        jitterFrames: headline.jitter?.frames ?? 0, valid: path.valid, n: path.n,
        domain: figures.domain, runId: runId, measuredAt: createdAt),
      in: store.paths.calibrations)
    return CalibrationRef(key: key, stored: true)
  }

  private static func operatingSystem() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }
}

/// The two devices' clocks of a two-device run, fitted from the callbacks logged so far. It places
/// each hit's input window and measures the hit through host time (CAL-03).
private struct HostMapping {
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
