import Foundation

public enum SweepDirection: String, Codable, Sendable {
  case up, down
  /// Not a sweep: the click control.
  case none
}

public enum TemplateKind: String, Codable, Sendable { case chirp, click }

/// A test sound as data (D-13): the sampled buffer plus the analytic generator behind it, so a
/// simulated device can render it at an exact fractional delay and a real one can play the samples.
public struct StimulusTemplate: Sendable {
  public let id: String
  public let kind: TemplateKind
  public let sampleRate: Double
  public let durationMs: Double
  public let bandLowHz: Double
  public let bandHighHz: Double
  public let direction: SweepDirection
  public let samples: [Float]
  private let generator: @Sendable (Double) -> Float

  public init(
    id: String,
    kind: TemplateKind = .chirp,
    sampleRate: Double,
    durationMs: Double,
    bandLowHz: Double,
    bandHighHz: Double,
    direction: SweepDirection,
    generator: @escaping @Sendable (Double) -> Float
  ) {
    self.id = id
    self.kind = kind
    self.sampleRate = sampleRate
    self.durationMs = durationMs
    self.bandLowHz = bandLowHz
    self.bandHighHz = bandHighHz
    self.direction = direction
    self.generator = generator
    let count = Int((durationMs / 1000 * sampleRate).rounded())
    self.samples = (0..<count).map { generator(Double($0) / sampleRate) }
  }

  /// The analytic value at `t` seconds after the stimulus starts; zero outside its duration.
  public func value(atSeconds t: Double) -> Float { generator(t) }

  /// The same stimulus regenerated at another sample rate.
  public func atSampleRate(_ rate: Double) throws -> StimulusTemplate {
    rate == sampleRate ? self : try StimulusLibrary.template(id: id, sampleRate: rate)
  }
}

public enum StimulusLibrary {
  /// Every template is 50 ms or shorter: the arm-time spacing guard leaves room for no more.
  public static let ids: [String] = [
    "chirp-loopback", "chirp-speaker", "chirp-loopback-down", "chirp-speaker-down", "click",
  ]

  public static func template(id: String, sampleRate: Double) throws -> StimulusTemplate {
    switch id {
    case "chirp-loopback", "chirp-loopback-down":
      // D-12: exponential sweep, 30 ms, Tukey alpha 0.1, loopback band 100 Hz to min(20 kHz, 0.45 fs).
      return sweep(
        id: id, sampleRate: sampleRate, lowHz: 100, highHz: Swift.min(20_000, 0.45 * sampleRate))
    case "chirp-speaker", "chirp-speaker-down":
      // D-12: the same sweep over the band a laptop speaker and microphone can carry.
      return sweep(
        id: id, sampleRate: sampleRate, lowHz: 300, highHz: Swift.min(8_000, 0.45 * sampleRate))
    case "click":
      // D-13: a 1 ms Hann pulse, the A/B control through the same correlator.
      return click(id: id, sampleRate: sampleRate, durationMs: 1)
    default:
      throw SoundPingError.usage(
        "unknownTemplate",
        "no stimulus template named '\(id)'; available: \(ids.joined(separator: ", "))",
        context: ["template": id])
    }
  }

  /// 30 ms exponential sweep over `lowHz...highHz`; ids ending in `-down` sweep downward (D-15).
  private static func sweep(id: String, sampleRate: Double, lowHz: Double, highHz: Double)
    -> StimulusTemplate
  {
    let down = id.hasSuffix("-down")
    return chirp(
      id: id, sampleRate: sampleRate, durationMs: 30, startHz: down ? highHz : lowHz,
      endHz: down ? lowHz : highHz, tukeyAlpha: 0.1)
  }

  /// A Hann-windowed pulse. Its band is nominal: up to the first null of the window, 2 / duration.
  static func click(id: String, sampleRate: Double, durationMs: Double) -> StimulusTemplate {
    let duration = durationMs / 1000
    let generator: @Sendable (Double) -> Float = { t in
      guard t >= 0, t < duration else { return 0 }
      return Float(0.5 * (1 - cos(2 * Double.pi * t / duration)))
    }
    return StimulusTemplate(
      id: id, kind: .click, sampleRate: sampleRate, durationMs: durationMs, bandLowHz: 0,
      bandHighHz: 2 / duration, direction: .none, generator: generator)
  }

  static func chirp(
    id: String, sampleRate: Double, durationMs: Double, startHz: Double, endHz: Double,
    tukeyAlpha alpha: Double
  ) -> StimulusTemplate {
    let duration = durationMs / 1000
    let k = log(endHz / startHz)
    let generator: @Sendable (Double) -> Float = { t in
      guard t >= 0, t < duration else { return 0 }
      let x = t / duration
      let phase = 2 * Double.pi * startHz * duration / k * (exp(x * k) - 1)
      return Float(tukey(x, alpha: alpha) * sin(phase))
    }
    return StimulusTemplate(
      id: id, sampleRate: sampleRate, durationMs: durationMs,
      bandLowHz: Swift.min(startHz, endHz), bandHighHz: Swift.max(startHz, endHz),
      direction: endHz >= startHz ? .up : .down, generator: generator)
  }

  /// Tukey (tapered cosine) window on x in [0, 1].
  static func tukey(_ x: Double, alpha: Double) -> Double {
    let edge = alpha / 2
    if x < edge { return 0.5 * (1 + cos(2 * Double.pi / alpha * (x - edge))) }
    if x > 1 - edge { return 0.5 * (1 + cos(2 * Double.pi / alpha * (x - 1 + edge))) }
    return 1
  }
}
