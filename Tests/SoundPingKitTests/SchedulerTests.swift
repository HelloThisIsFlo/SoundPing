import Foundation
import Testing

@testable import SoundPingKit

@Suite struct SchedulerTests {
  private static let sampleRate = 48_000.0

  private static func parameters(seed: UInt64 = 42) -> RunParameters {
    RecipeRegistry.roundTrip.defaultParameters(seed: seed)
  }

  private static func schedule(_ parameters: RunParameters) -> [ScheduledHit] {
    HitScheduler.schedule(
      parameters: parameters, startFrame: 0, sampleRate: sampleRate, gain: 0.03,
      templateId: parameters.templateId)
  }

  private static func gapsInFrames(_ hits: [ScheduledHit]) -> [Int64] {
    zip(hits.dropFirst(), hits).map { $0.outputFrame - $1.outputFrame }
  }

  private static func spacingError(
    _ parameters: RunParameters, templateDurationMs: Double
  ) -> SoundPingError? {
    do {
      try HitScheduler.validate(parameters, templateDurationMs: templateDurationMs)
      return nil
    } catch let error as SoundPingError {
      return error
    } catch {
      return SoundPingError.internalFailure("other", "\(error)")
    }
  }

  @Test func everyGapLiesInTheSpacingRange() {
    let parameters = Self.parameters()
    let gaps = Self.gapsInFrames(Self.schedule(parameters))
    let low = Int64((parameters.spacingMinMs / 1000 * Self.sampleRate).rounded())
    let high = Int64((parameters.spacingMaxMs / 1000 * Self.sampleRate).rounded())
    #expect(gaps.count == parameters.hits + parameters.warmup - 1)
    #expect(gaps.allSatisfy { (low...high).contains($0) })
    #expect(low == 21_600 && high == 36_000)  // [450, 750] ms at 48 kHz
  }

  @Test func gapsAreNotAllEqual() {
    let gaps = Self.gapsInFrames(Self.schedule(Self.parameters()))
    #expect(Set(gaps).count > 1)
  }

  @Test func theSameSeedReproducesTheSchedule() {
    #expect(Self.schedule(Self.parameters(seed: 7)) == Self.schedule(Self.parameters(seed: 7)))
  }

  @Test func aDifferentSeedChangesTheSchedule() {
    #expect(Self.schedule(Self.parameters(seed: 7)) != Self.schedule(Self.parameters(seed: 8)))
  }

  @Test func theWarmupCountIsRespected() {
    var parameters = Self.parameters()
    parameters.hits = 12
    parameters.warmup = 3
    let hits = Self.schedule(parameters)
    #expect(hits.count == 15)
    let phases = hits.map { HitScheduler.phase(forHit: $0.index, warmup: parameters.warmup) }
    #expect(phases.filter { $0 == .warmup }.count == 3)
    #expect(phases.filter { $0 == .measure }.count == 12)
    #expect(phases.prefix(3).allSatisfy { $0 == .warmup })
  }

  @Test func aSpacingBelowTheRequirementIsRefused() {
    var parameters = Self.parameters()
    parameters.spacingMinMs = 300
    parameters.maxLatencyMs = 350
    let error = Self.spacingError(parameters, templateDurationMs: 30)
    #expect(error?.code == "spacingTooShort")
    #expect(error?.kind == .usage)
  }

  @Test func defaultsPassSpacingGuard() throws {
    let defaults = Self.parameters()
    for id in StimulusLibrary.ids {
      let template = try StimulusLibrary.template(id: id, sampleRate: Self.sampleRate)
      #expect(
        Self.spacingError(defaults, templateDurationMs: template.durationMs) == nil,
        "template '\(id)' (\(template.durationMs) ms) is refused by the default spacing")
    }
    // 450 = 350 + 50 + 50: equal passes, a template longer than 50 ms needs wider spacing.
    #expect(Self.spacingError(defaults, templateDurationMs: 50) == nil)
    #expect(Self.spacingError(defaults, templateDurationMs: 50.5)?.code == "spacingTooShort")
  }

  @Test func aNonFiniteOrPositiveLevelIsRefused() {
    for level in [Double.nan, .infinity, -.infinity, 3] {
      var parameters = Self.parameters()
      parameters.levelDbfs = level
      #expect(
        Self.spacingError(parameters, templateDurationMs: 30)?.code == "invalidParameters",
        "level \(level) must be refused")
    }
    var parameters = Self.parameters()
    parameters.levelDbfs = -24
    #expect(Self.spacingError(parameters, templateDurationMs: 30) == nil)
  }
}
