import Foundation
import Testing

@testable import SoundPingKit

/// The matched filter on synthetic signals whose truth is exact: each template renders itself at a
/// fractional delay through its own analytic generator, so nothing is resampled.
@Suite struct CorrelatorTests {
  static let sampleRate = 48_000.0
  /// About the size of the real 350 ms listening window.
  static let windowFrames = 16_800

  /// `arrivals` are copies of the template at fractional frame delays; noise is uniform in
  /// ±`noise`, drawn from a seeded generator.
  static func render(
    _ template: StimulusTemplate, arrivals: [(delay: Double, gain: Double)], noise: Double = 0,
    seed: UInt64 = 1
  ) -> [Float] {
    var rng = SplitMix64(seed: seed)
    return (0..<windowFrames).map { frame in
      var value = 0.0
      for arrival in arrivals {
        let seconds = (Double(frame) - arrival.delay) / sampleRate
        value += arrival.gain * Double(template.value(atSeconds: seconds))
      }
      if noise > 0 { value += (rng.nextDouble() * 2 - 1) * noise }
      return Float(value)
    }
  }

  static func found(_ detection: Detection) -> (frame: Double, confidence: Double, psr: Double?)? {
    if case .found(let frame, let confidence, let psr, _) = detection {
      return (frame, confidence, psr)
    }
    return nil
  }

  @Test func theLibraryHoldsEveryTemplateAsData() throws {
    #expect(
      Set(StimulusLibrary.ids)
        == [
          "chirp-loopback", "chirp-speaker", "chirp-loopback-down", "chirp-speaker-down", "click",
        ])
    for id in StimulusLibrary.ids {
      let template = try StimulusLibrary.template(id: id, sampleRate: Self.sampleRate)
      #expect(template.id == id)
      #expect(template.durationMs <= 50, "\(id) would break the arm-time spacing guard")
      #expect(!template.samples.isEmpty)
    }
    let loopback = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: Self.sampleRate)
    #expect(loopback.bandLowHz == 100 && loopback.bandHighHz == 20_000)
    let speaker = try StimulusLibrary.template(id: "chirp-speaker", sampleRate: Self.sampleRate)
    #expect(speaker.bandLowHz == 300 && speaker.bandHighHz == 8_000)
    #expect(speaker.direction == .up)
    #expect(
      try StimulusLibrary.template(id: "chirp-speaker-down", sampleRate: Self.sampleRate).direction
        == .down)
  }

  @Test(arguments: ["chirp-loopback", "chirp-speaker"])
  func chirpsAreSubSampleAccurateAtEveryFractionalDelay(id: String) throws {
    let template = try StimulusLibrary.template(id: id, sampleRate: Self.sampleRate)
    let correlator = Correlator(template: template)
    var worst = 0.0
    var lowestConfidence = 1.0

    for step in 0..<20 {
      for polarity in [1.0, -1.0] {
        let delay = 1000 + Double(step) * 0.05
        let window = Self.render(
          template, arrivals: [(delay, 0.8 * polarity)], noise: 0.05, seed: UInt64(step * 2 + 1))
        let hit = try #require(
          Self.found(correlator.detect(window: window, windowStartFrame: 0, stamps: [])),
          "\(id) delay \(delay) polarity \(polarity) was rejected")
        worst = Swift.max(worst, abs(hit.frame - delay))
        lowestConfidence = Swift.min(lowestConfidence, hit.confidence)
      }
    }
    #expect(worst <= 0.1, "\(id) worst error \(worst) frame")
    #expect(lowestConfidence >= 0.8, "\(id) lowest confidence \(lowestConfidence)")
  }

  @Test func theClickControlIsWithinHalfAFrame() throws {
    let template = try StimulusLibrary.template(id: "click", sampleRate: Self.sampleRate)
    let correlator = Correlator(template: template)
    var worst = 0.0
    for step in 0..<20 {
      for polarity in [1.0, -1.0] {
        let delay = 1000 + Double(step) * 0.05
        let window = Self.render(
          template, arrivals: [(delay, 0.8 * polarity)], noise: 0.05, seed: UInt64(step * 2 + 1))
        let hit = try #require(
          Self.found(correlator.detect(window: window, windowStartFrame: 0, stamps: [])))
        worst = Swift.max(worst, abs(hit.frame - delay))
      }
    }
    // Recorded for the click-vs-chirp comparison on the bench.
    print("click control: worst sub-sample error \(worst) frame")
    #expect(worst <= 0.5)
  }

  @Test func aLouderLaterReflectionNeverBeatsTheDirectPath() throws {
    let template = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: Self.sampleRate)
    let correlator = Correlator(template: template)
    let window = Self.render(template, arrivals: [(1000, 0.3), (1100, 0.5)])
    let hit = try #require(
      Self.found(correlator.detect(window: window, windowStartFrame: 0, stamps: [])))
    #expect(abs(hit.frame - 1000) <= 0.1)
  }

  @Test func threeComparableArrivalsAreAmbiguous() throws {
    let template = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: Self.sampleRate)
    let correlator = Correlator(template: template)
    // The first arrival is 0.55 of the strongest; two later ones reach 1.0 and 0.95, 200 frames
    // (more than 1 ms) apart.
    let window = Self.render(
      template, arrivals: [(1000, 0.275), (1200, 0.5), (1400, 0.475)])
    #expect(
      correlator.detect(window: window, windowStartFrame: 0, stamps: [])
        == .rejected(.ambiguousPeaks))
  }

  @Test func noiseAloneIsLowConfidenceAndSilenceIsNoPeak() throws {
    let template = try StimulusLibrary.template(id: "chirp-loopback", sampleRate: Self.sampleRate)
    let correlator = Correlator(template: template)
    let noise = (0..<Self.windowFrames).map { index -> Float in
      var rng = SplitMix64(seed: UInt64(index) &+ 99)
      return Float((rng.nextDouble() * 2 - 1) * 0.05)
    }
    #expect(
      correlator.detect(window: noise, windowStartFrame: 0, stamps: []) == .rejected(.lowConfidence)
    )
    let silence = [Float](repeating: 0, count: Self.windowFrames)
    #expect(correlator.detect(window: silence, windowStartFrame: 0, stamps: []) == .rejected(.noPeak))
  }

  @Test(arguments: ["chirp-loopback", "chirp-speaker"])
  func aCleanChirpReportsItsPeakToSidelobeRatio(id: String) throws {
    let template = try StimulusLibrary.template(id: id, sampleRate: Self.sampleRate)
    let correlator = Correlator(template: template)
    let window = Self.render(template, arrivals: [(1000.3, 0.5)], noise: 0.002)
    let hit = try #require(
      Self.found(correlator.detect(window: window, windowStartFrame: 0, stamps: [])))
    let psr = try #require(hit.psr)
    #expect(psr > 2, "\(id) psr \(psr)")
  }

  @Test func theUpAndDownSweepsStaySeparable() throws {
    for band in ["loopback", "speaker"] {
      let up = try StimulusLibrary.template(id: "chirp-\(band)", sampleRate: Self.sampleRate)
      let down = try StimulusLibrary.template(id: "chirp-\(band)-down", sampleRate: Self.sampleRate)
      #expect(up.direction == .up && down.direction == .down)
      #expect(up.bandLowHz == down.bandLowHz && up.bandHighHz == down.bandHighHz)

      // Slide the down twin along the up chirp and keep the best normalised correlation.
      let signal = Self.render(up, arrivals: [(500, 0.5)]).prefix(3000)
      let best = Self.bestNormalisedCorrelation(of: down.samples, in: Array(signal))
      #expect(best < 0.3, "\(band): up chirp vs down twin correlates at \(best)")

      // Control: the up chirp does find itself.
      #expect(Self.bestNormalisedCorrelation(of: up.samples, in: Array(signal)) > 0.9)
    }
  }

  /// Brute-force |ZNCC| maximum over every full-overlap lag.
  static func bestNormalisedCorrelation(of template: [Float], in signal: [Float]) -> Double {
    let p = template.count
    let templateEnergy = template.reduce(0.0) { $0 + Double($1) * Double($1) }
    var best = 0.0
    for lag in 0...(signal.count - p) {
      var dot = 0.0
      var energy = 0.0
      for index in 0..<p {
        let sample = Double(signal[lag + index])
        dot += sample * Double(template[index])
        energy += sample * sample
      }
      guard energy > 0 else { continue }
      best = Swift.max(best, abs(dot) / (templateEnergy * energy).squareRoot())
    }
    return best
  }
}
