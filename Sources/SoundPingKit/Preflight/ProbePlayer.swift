import Foundation

/// Plays one uncounted test sound at a time and says how clearly it came back. The level ramp and
/// the input-channel probe both use it; neither writes anything to hits[].
///
/// A probe's index is negative (−1, −2, … in probe order). Hit indices start at 0, so a simulation
/// knob keyed by hit index (`--sim-miss`, `--sim-xrun`, `--sim-fault`) can never silence or
/// glitch a probe.
struct ProbePlayer {
  private let backend: any AudioBackend
  private let template: StimulusTemplate
  /// Accepts any confidence, so a probe reports how faint a chirp was rather than only that it
  /// fell short of the run's limit.
  private let correlator: Correlator
  private(set) var nextIndex = -1

  struct Played {
    var record: ProbeRecord
    /// The window held nothing but exact zeros (or nothing at all): no signal path exists.
    var silent: Bool
    /// A recorded fault or a lost-frames discontinuity touched the window, so the probe says nothing
    /// about how loud the chirp is: it reads as confidence 0 and no peak, like a missing chirp.
    var glitched: Bool
  }

  init(backend: any AudioBackend, template: StimulusTemplate) {
    self.backend = backend
    self.template = template
    self.correlator = Correlator(template: template, minConfidence: 0)
  }

  mutating func play(atLevel level: Double, using listener: inout HitListener) async throws
    -> Played
  {
    guard level.isFinite else {
      throw SoundPingError.internalFailure(
        "nonFiniteLevel", "a probe was asked for at a non-finite level (\(level) dBFS)")
    }
    let lead = Int64((HitScheduler.leadInMs / 1000 * template.sampleRate).rounded(.up))
    let hit = ScheduledHit(
      index: nextIndex, outputFrame: await backend.currentOutputFrame() + lead,
      gain: Float(pow(10, level / 20)), templateId: template.id)
    nextIndex -= 1
    try await backend.schedule([hit])

    let heard = try await listener.listen(to: hit, with: correlator)
    var confidence = 0.0
    if case .found(_, let value, _, _) = heard.detection { confidence = value }
    let record = ProbeRecord(
      index: hit.index, levelDbfs: level, confidence: confidence,
      peakDbfs: LevelRamp.dbfs(ofAbsolutePeak: heard.peakAbs))
    var glitched = heard.faulted
    if case .rejected(.discontinuity) = heard.detection { glitched = true }
    return Played(
      record: record, silent: !heard.faulted && heard.peakAbs == 0, glitched: glitched)
  }
}
