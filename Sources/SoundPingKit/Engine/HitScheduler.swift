import Foundation

/// When hits fire (ENG-04, D-04): randomised spacing so a periodic interferer can't lock in,
/// drawn by a seeded SplitMix64 so the same seed reproduces the same schedule.
public enum HitScheduler {
  /// The first hit lands at least this long after the backend's current output frame.
  public static let leadInMs = 100.0
  /// Slack kept between the end of one hit's listening window and the next hit (RESEARCH P6).
  public static let spacingMarginMs = 50.0

  /// Arm-time checks, pure so tests call them directly (T-01-10).
  public static func validate(_ parameters: RunParameters, templateDurationMs: Double) throws {
    guard (1...10_000).contains(parameters.hits) else {
      throw SoundPingError.usage(
        "invalidParameters", "hits must be between 1 and 10000, got \(parameters.hits)",
        context: ["parameter": "hits", "value": String(parameters.hits)])
    }
    guard (0...100).contains(parameters.warmup) else {
      throw SoundPingError.usage(
        "invalidParameters", "warmup must be between 0 and 100, got \(parameters.warmup)",
        context: ["parameter": "warmup", "value": String(parameters.warmup)])
    }
    if let level = parameters.levelDbfs {
      guard level.isFinite, level <= 0 else {
        throw SoundPingError.usage(
          "invalidParameters", "level must be a finite dBFS value of 0 or below, got \(level)",
          context: ["parameter": "level", "value": String(level)])
      }
    }
    // The valid-hit gate: NaN or infinity would trap in requiredValidHits after the whole run was
    // measured, zero or less would switch the gate off, and more than 1 could never be passed.
    guard parameters.minValidFraction.isFinite, parameters.minValidFraction > 0,
      parameters.minValidFraction <= 1
    else {
      throw SoundPingError.usage(
        "invalidParameters",
        "minValidFraction must be above 0 and at most 1, got \(parameters.minValidFraction)",
        context: [
          "parameter": "minValidFraction", "value": String(parameters.minValidFraction),
        ])
    }
    let timings = [parameters.spacingMinMs, parameters.spacingMaxMs, parameters.maxLatencyMs]
    guard timings.allSatisfy({ $0.isFinite && $0 > 0 }),
      parameters.spacingMaxMs >= parameters.spacingMinMs
    else {
      throw SoundPingError.usage(
        "invalidParameters",
        "spacing and max latency must be positive and spacing max must not be below spacing min",
        context: [
          "spacingMinMs": String(parameters.spacingMinMs),
          "spacingMaxMs": String(parameters.spacingMaxMs),
          "maxLatencyMs": String(parameters.maxLatencyMs),
        ])
    }

    let required = parameters.maxLatencyMs + templateDurationMs + spacingMarginMs
    guard parameters.spacingMinMs >= required else {
      throw SoundPingError.usage(
        "spacingTooShort",
        "the shortest gap between hits (\(parameters.spacingMinMs) ms) is below max latency + stimulus + \(Int(spacingMarginMs)) ms (\(required) ms); a late hit would spill into the next one",
        context: [
          "spacingMinMs": String(parameters.spacingMinMs),
          "requiredMs": String(required),
        ])
    }
  }

  public static func phase(forHit index: Int, warmup: Int) -> RunPhase {
    index < warmup ? .warmup : .measure
  }

  /// All hits of a run, warm-ups first. Gaps are uniform in [spacingMinMs, spacingMaxMs].
  public static func schedule(
    parameters: RunParameters, startFrame: Int64, sampleRate: Double, gain: Float,
    templateId: String
  ) -> [ScheduledHit] {
    var rng = SplitMix64(seed: parameters.seed)
    var frame = startFrame + Int64((leadInMs / 1000 * sampleRate).rounded(.up))
    var hits: [ScheduledHit] = []
    hits.reserveCapacity(parameters.hits + parameters.warmup)
    for index in 0..<(parameters.warmup + parameters.hits) {
      if index > 0 {
        let gapMs =
          parameters.spacingMinMs
          + rng.nextDouble() * (parameters.spacingMaxMs - parameters.spacingMinMs)
        frame += Int64((gapMs / 1000 * sampleRate).rounded())
      }
      hits.append(ScheduledHit(index: index, outputFrame: frame, gain: gain, templateId: templateId))
    }
    return hits
  }
}
