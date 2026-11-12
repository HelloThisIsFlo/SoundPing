import Accelerate
import Foundation

public enum Detection: Sendable, Equatable {
  case found(frame: Double, confidence: Double, psr: Double?, peakAbs: Float)
  case rejected(RejectionReason)
}

/// Matched filter over a stimulus template (D-12, D-13). The template is data, so the same
/// correlator serves the chirp, the click control and every later recipe.
public struct Correlator: Sendable {
  public let template: StimulusTemplate
  public let minConfidence: Double
  private let templateEnergy: Double

  public init(template: StimulusTemplate, minConfidence: Double = 0.5) {
    self.template = template
    self.minConfidence = minConfidence
    var energy: Float = 0
    template.samples.withUnsafeBufferPointer {
      vDSP_svesq($0.baseAddress!, 1, &energy, vDSP_Length($0.count))
    }
    self.templateEnergy = Double(energy)
  }

  /// Finds the template in `window`, whose first sample is input frame `windowStartFrame`.
  /// The returned frame is where the template's first sample landed, sub-sample accurate.
  public func detect(window: [Float], windowStartFrame: Int64, stamps: [CallbackStamp]) -> Detection
  {
    let p = template.samples.count
    let lags = window.count - p + 1
    guard p > 0, lags >= 3 else { return .rejected(.outsideWindow) }

    // The device lost frames inside this window: whatever the filter would find is not a latency.
    if Self.hasDiscontinuity(stamps) { return .rejected(.discontinuity) }

    // Positive filter stride = correlation: corr[j] = sum_p window[j + p] * template[p].
    var corr = [Float](repeating: 0, count: lags)
    vDSP_conv(window, 1, template.samples, 1, &corr, 1, vDSP_Length(lags), vDSP_Length(p))

    // Magnitude makes the detector polarity-proof.
    var magnitude = [Float](repeating: 0, count: lags)
    vDSP_vabs(corr, 1, &magnitude, 1, vDSP_Length(lags))

    var peak: Float = 0
    var peakIndex: vDSP_Length = 0
    vDSP_maxvi(magnitude, 1, &peak, &peakIndex, vDSP_Length(lags))
    guard peak > 0 else { return .rejected(.noPeak) }
    let i = Int(peakIndex)
    guard i > 0, i < lags - 1 else { return .rejected(.outsideWindow) }

    // A flat-topped template means the converter saturated and the shape, hence the peak, is wrong.
    if Self.isClipped(window, from: i, count: p) { return .rejected(.clipped) }

    // Normalised correlation at the integer peak: gain-invariant, 0...1.
    var segmentEnergy: Float = 0
    var segmentPeak: Float = 0
    window.withUnsafeBufferPointer {
      let segment = $0.baseAddress! + i
      vDSP_svesq(segment, 1, &segmentEnergy, vDSP_Length(p))
      vDSP_maxmgv(segment, 1, &segmentPeak, vDSP_Length(p))
    }
    let denominator = (templateEnergy * Double(segmentEnergy)).squareRoot()
    guard denominator > 0 else { return .rejected(.noPeak) }
    let confidence = Swift.min(1, Double(peak) / denominator)
    guard confidence >= minConfidence else { return .rejected(.lowConfidence) }

    // Parabolic interpolation on |c| for the sub-sample position.
    let a = Double(magnitude[i - 1])
    let b = Double(magnitude[i])
    let c = Double(magnitude[i + 1])
    let curvature = a - 2 * b + c
    let offset = curvature == 0 ? 0 : Swift.max(-0.5, Swift.min(0.5, 0.5 * (a - c) / curvature))

    return .found(
      frame: Double(windowStartFrame) + Double(i) + offset,
      confidence: confidence,
      psr: nil,
      peakAbs: segmentPeak)
  }

  /// Sample times of consecutive callbacks must continue each other. Compared in Double with half
  /// a frame of tolerance (ENG-07): a real clock reports whole frames, so anything larger is a gap.
  static func hasDiscontinuity(_ stamps: [CallbackStamp]) -> Bool {
    for (previous, next) in zip(stamps, stamps.dropFirst()) {
      let expected = previous.inputSampleTime + Double(previous.frames)
      if abs(next.inputSampleTime - expected) > discontinuityToleranceFrames { return true }
    }
    return false
  }

  /// Three or more consecutive samples at full scale in the span the template was matched to.
  static func isClipped(_ window: [Float], from start: Int, count: Int) -> Bool {
    var run = 0
    for index in start..<Swift.min(window.count, start + count) {
      if abs(window[index]) >= clipLevel {
        run += 1
        if run >= clipRunLength { return true }
      } else {
        run = 0
      }
    }
    return false
  }

  static let discontinuityToleranceFrames = 0.5
  static let clipLevel: Float = 0.999
  static let clipRunLength = 3
}
