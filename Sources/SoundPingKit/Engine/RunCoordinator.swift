import Foundation

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
      let session = Session(backend: backend, store: store, request: request, continuation: continuation)
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

/// One run, start to finish. Never sleeps on the wall clock: it waits on sample positions.
private struct Session: Sendable {
  let backend: any AudioBackend
  let store: RunStore
  let request: RunRequest
  let continuation: AsyncThrowingStream<RunEvent, Error>.Continuation

  func run() async throws {
    let parameters = request.parameters
    let nominal = try StimulusLibrary.template(id: parameters.templateId, sampleRate: 48_000)

    let result: RunResult
    do {
      let info = try await backend.open(request.setup, templates: [nominal])
      result = try await measure(info: info, nominal: nominal)
      await backend.stop()
    } catch {
      await backend.stop()
      throw error
    }
    continuation.yield(.finished(result))
  }

  private func measure(info: BackendInfo, nominal: StimulusTemplate) async throws -> RunResult {
    let parameters = request.parameters
    let recipe = request.recipe
    let sampleRate = info.sampleRate
    let template = try nominal.atSampleRate(sampleRate)
    let templateFrames = Int64(template.samples.count)
    let maxLatencyFrames = Int64((parameters.maxLatencyMs / 1000 * sampleRate).rounded(.up))

    let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    let runId = RunStore.folderName(recipeId: recipe.id, label: request.label, createdAt: createdAt)
    let snapshot = SetupSnapshot(
      setup: request.setup, sampleRate: sampleRate, bufferFrames: info.bufferFrames,
      simulated: info.simulation != nil)
    continuation.yield(
      .armed(
        ArmedInfo(runId: runId, recipe: recipe.ref, parameters: parameters, setup: snapshot)))

    try await backend.start()
    let level = parameters.levelDbfs ?? recipe.startLevelDbfs
    let gain = Float(pow(10, level / 20))

    // Slice stub: evenly spaced hits at the midpoint of the spacing range, the first 100 ms in.
    let startFrame = await backend.currentOutputFrame()
    let gapFrames = Int64(
      ((parameters.spacingMinMs + parameters.spacingMaxMs) / 2 / 1000 * sampleRate).rounded())
    let firstFrame = startFrame + Int64((0.1 * sampleRate).rounded())
    let scheduled = (0..<parameters.hits).map {
      ScheduledHit(
        index: $0, outputFrame: firstFrame + Int64($0) * gapFrames, gain: gain,
        templateId: template.id)
    }
    try await backend.schedule(scheduled)

    let correlator = Correlator(template: template)
    var records: [HitRecord] = []
    for hit in scheduled {
      try Task.checkCancellation()
      let end = hit.outputFrame + maxLatencyFrames + templateFrames
      try await backend.waitUntilCaptured(throughInputFrame: end)
      let range = hit.outputFrame..<end
      let window = try await backend.capture(range)
      let stamps = await backend.stamps(covering: range)

      var record = HitRecord(index: hit.index, phase: .measure, outputFrame: hit.outputFrame)
      switch correlator.detect(window: window, windowStartFrame: hit.outputFrame, stamps: stamps) {
      case .found(let frame, let confidence, let psr, _):
        let latency = frame - Double(hit.outputFrame)
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

    return try finish(
      records: records, info: info, snapshot: snapshot, runId: runId, createdAt: createdAt)
  }

  private func finish(
    records: [HitRecord], info: BackendInfo, snapshot: SetupSnapshot, runId: String,
    createdAt: Date
  ) throws -> RunResult {
    let measured = records.filter { $0.phase == .measure }
    let latencies = measured.compactMap { $0.rejection == nil ? $0.latencyFrames : nil }
    let stats = Stats.summarize(latencies: latencies, n: measured.count, sampleRate: info.sampleRate)

    var rejectedCounts = Dictionary(
      uniqueKeysWithValues: RejectionReason.allCases.map { ($0.rawValue, 0) })
    for record in measured {
      if let reason = record.rejection { rejectedCounts[reason.rawValue, default: 0] += 1 }
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
      measured: Measured(headline: .path, domain: .sample, path: stats),
      histogram: Stats.histogram(latencies: latencies),
      hits: records,
      rejectedCounts: rejectedCounts,
      segments: request.recipe.segments,
      corrections: [],
      simulation: info.simulation)

    let folder = try store.createRunFolder(
      recipeId: request.recipe.id, label: request.label, createdAt: createdAt)
    result.runId = folder.lastPathComponent
    result.runPath = folder.path
    try store.write(result, to: folder)
    return result
  }

  private static func operatingSystem() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }
}
