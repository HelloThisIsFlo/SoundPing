import Foundation

public enum SweepDirection: String, Codable, Sendable { case up, down }

/// A test sound as data (D-13): the sampled buffer plus the analytic generator behind it, so a
/// simulated device can render it at an exact fractional delay and a real one can play the samples.
public struct StimulusTemplate: Sendable {
  public let id: String
  public let sampleRate: Double
  public let durationMs: Double
  public let bandLowHz: Double
  public let bandHighHz: Double
  public let direction: SweepDirection
  public let samples: [Float]
  private let generator: @Sendable (Double) -> Float

  public init(
    id: String,
    sampleRate: Double,
    durationMs: Double,
    bandLowHz: Double,
    bandHighHz: Double,
    direction: SweepDirection,
    generator: @escaping @Sendable (Double) -> Float
  ) {
    self.id = id
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
  public static let ids: [String] = ["chirp-loopback"]

  public static func template(id: String, sampleRate: Double) throws -> StimulusTemplate {
    switch id {
    case "chirp-loopback":
      // D-12: exponential sweep, 30 ms, Tukey alpha 0.1, loopback band 100 Hz to min(20 kHz, 0.45 fs).
      return chirp(
        id: id, sampleRate: sampleRate, durationMs: 30, startHz: 100,
        endHz: Swift.min(20_000, 0.45 * sampleRate), tukeyAlpha: 0.1)
    default:
      throw SoundPingError.usage(
        "unknownTemplate",
        "no stimulus template named '\(id)'; available: \(ids.joined(separator: ", "))",
        context: ["template": id])
    }
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
