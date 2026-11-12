import Accelerate
import Foundation

public enum Detection: Sendable, Equatable {
  case found(frame: Double, confidence: Double, psr: Double?, peakAbs: Float)
  case rejected(RejectionReason)
}

/// Matched filter over a stimulus template (D-12, D-13). The template is data, so the same
/// correlator serves the chirp, the click control and every later recipe.
///
/// Per hit window: correlate, take |c| (polarity-proof), then
/// 1. reject a window with a sample-time gap (`discontinuity`) or a saturated peak (`clipped`);
/// 2. require a template to be present at all: the strongest peak needs confidence >=
///    `minConfidence` (`lowConfidence`);
/// 3. take the earliest local maximum at or above `firstPeakFraction` of the strongest, so a louder
///    later reflection never wins over the direct path;
/// 4. reject `ambiguousPeaks` when that first peak is weak and two strong arrivals follow it;
/// 5. refine the position with a parabola through |c| and report confidence and PSR.
///
/// Confidence is the normalised correlation at the integer peak minus the ratio of noise to signal
/// RMS, clamped at 0. The noise-ratio idea comes from Google OboeTester's LatencyAnalyzer; the
/// code here is our own (a gain-invariant ZNCC), nothing is copied.
public struct Correlator: Sendable {
  public let template: StimulusTemplate
  public let minConfidence: Double
  private let templateEnergy: Double
  /// A local maximum must beat every sample this close to it, about half the main lobe's width.
  private let peakNeighbourhood: Int
  /// 1 ms in frames: the exclusion zone for PSR and the spacing that makes two arrivals distinct.
  private let millisecondFrames: Int

  /// The earliest peak at or above this fraction of the strongest one is the direct path.
  static let firstPeakFraction: Float = 0.5
  /// The first peak counts as weak (candidate for ambiguity) below this fraction of the strongest.
  static let weakFirstPeakFraction: Float = 0.7
  /// Later arrivals this close to the strongest count as competing with it.
  static let strongLaterFraction: Float = 0.9
  static let discontinuityToleranceFrames = 0.5
  static let clipLevel: Float = 0.999
  static let clipRunLength = 3
  /// PSR is capped so a noise-free window reports a finite number (JSON has no infinity).
  static let maxPsr = 1e6

  public init(template: StimulusTemplate, minConfidence: Double = 0.5) {
    self.template = template
    self.minConfidence = minConfidence
    var energy: Float = 0
    template.samples.withUnsafeBufferPointer {
      vDSP_svesq($0.baseAddress!, 1, &energy, vDSP_Length($0.count))
    }
    self.templateEnergy = Double(energy)
    self.peakNeighbourhood = Swift.max(
      2, Int((template.sampleRate / (2 * Swift.max(template.bandHighHz, 1))).rounded(.up)))
    self.millisecondFrames = Swift.max(1, Int((template.sampleRate / 1000).rounded()))
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

    var strongest: Float = 0
    var strongestIndex: vDSP_Length = 0
    vDSP_maxvi(magnitude, 1, &strongest, &strongestIndex, vDSP_Length(lags))
    guard strongest > 0 else { return .rejected(.noPeak) }
    let top = Int(strongestIndex)
    guard top > 0, top < lags - 1 else { return .rejected(.outsideWindow) }

    // A flat-topped template means the converter saturated and the shape, hence the peak, is wrong.
    if Self.isClipped(window, from: top, count: p) { return .rejected(.clipped) }

    // Is there a template in this window at all? Judged on the strongest arrival: the direct path
    // can legitimately correlate less than a louder reflection that overlaps it.
    guard let topConfidence = confidence(window: window, corr: corr, at: top),
      topConfidence >= minConfidence
    else { return .rejected(.lowConfidence) }

    let candidates = localMaxima(magnitude, atLeast: Self.firstPeakFraction * strongest)
    guard let first = candidates.first else { return .rejected(.noPeak) }
    if first != top, Self.isClipped(window, from: first, count: p) { return .rejected(.clipped) }

    if magnitude[first] < Self.weakFirstPeakFraction * strongest {
      let rivals = candidates.filter {
        $0 > first && magnitude[$0] >= Self.strongLaterFraction * strongest
      }
      if let earliest = rivals.first, let latest = rivals.last,
        rivals.count >= 2, latest - earliest > millisecondFrames
      {
        return .rejected(.ambiguousPeaks)
      }
    }

    // Parabolic interpolation on |c| for the sub-sample position.
    let a = Double(magnitude[first - 1])
    let b = Double(magnitude[first])
    let c = Double(magnitude[first + 1])
    let curvature = a - 2 * b + c
    let offset = curvature == 0 ? 0 : Swift.max(-0.5, Swift.min(0.5, 0.5 * (a - c) / curvature))

    var segmentPeak: Float = 0
    window.withUnsafeBufferPointer {
      vDSP_maxmgv($0.baseAddress! + first, 1, &segmentPeak, vDSP_Length(p))
    }

    return .found(
      frame: Double(windowStartFrame) + Double(first) + offset,
      confidence: confidence(window: window, corr: corr, at: first) ?? 0,
      psr: peakToSidelobeRatio(magnitude, at: first),
      peakAbs: segmentPeak)
  }

  // MARK: - Pieces

  /// Local maxima of |c| (at the template's own resolution) at or above `threshold`, ascending.
  /// Index 0 and the last lag cannot be refined, so they are never candidates.
  private func localMaxima(_ magnitude: [Float], atLeast threshold: Float) -> [Int] {
    let w = peakNeighbourhood
    let last = magnitude.count - 1
    var found: [Int] = []
    for j in 1..<last where magnitude[j] >= threshold {
      let value = magnitude[j]
      let beatsEarlier = (Swift.max(0, j - w)..<j).allSatisfy { magnitude[$0] <= value }
      let beatsLater = ((j + 1)...Swift.min(last, j + w)).allSatisfy { magnitude[$0] < value }
      if beatsEarlier && beatsLater { found.append(j) }
    }
    return found
  }

  /// ZNCC at the integer peak minus the noise/signal RMS ratio, clamped at 0 and capped at 1.
  /// Nil when the aligned span is silent.
  private func confidence(window: [Float], corr: [Float], at index: Int) -> Double? {
    let p = template.samples.count
    var spanEnergy: Float = 0
    window.withUnsafeBufferPointer {
      vDSP_svesq($0.baseAddress! + index, 1, &spanEnergy, vDSP_Length(p))
    }
    let denominator = (templateEnergy * Double(spanEnergy)).squareRoot()
    guard denominator > 0 else { return nil }
    let zncc = Swift.min(1, Double(abs(corr[index])) / denominator)

    // Noise: everything outside the aligned span, with 1 ms of margin either side.
    let lowEdge = Swift.max(0, index - millisecondFrames)
    let highEdge = Swift.min(window.count, index + p + millisecondFrames)
    var noiseEnergy = 0.0
    window.withUnsafeBufferPointer { buffer in
      var part: Float = 0
      if lowEdge > 0 {
        vDSP_svesq(buffer.baseAddress!, 1, &part, vDSP_Length(lowEdge))
        noiseEnergy += Double(part)
      }
      if highEdge < window.count {
        vDSP_svesq(buffer.baseAddress! + highEdge, 1, &part, vDSP_Length(window.count - highEdge))
        noiseEnergy += Double(part)
      }
    }
    let noiseCount = lowEdge + (window.count - highEdge)
    let noiseRms = noiseCount > 0 ? (noiseEnergy / Double(noiseCount)).squareRoot() : 0
    let signalRms = (Double(spanEnergy) / Double(p)).squareRoot()
    return Swift.max(0, zncc - noiseRms / signalRms)
  }

  /// |c| at the peak over the largest |c| further than 1 ms from it. High means a clean, isolated
  /// arrival; near or below 1 means something else correlates about as well.
  private func peakToSidelobeRatio(_ magnitude: [Float], at index: Int) -> Double? {
    var sidelobe: Float = 0
    let lowEnd = index - millisecondFrames
    if lowEnd > 0 {
      var part: Float = 0
      magnitude.withUnsafeBufferPointer {
        vDSP_maxv($0.baseAddress!, 1, &part, vDSP_Length(lowEnd))
      }
      sidelobe = Swift.max(sidelobe, part)
    }
    let highStart = index + millisecondFrames + 1
    if highStart < magnitude.count {
      var part: Float = 0
      magnitude.withUnsafeBufferPointer {
        vDSP_maxv($0.baseAddress! + highStart, 1, &part, vDSP_Length(magnitude.count - highStart))
      }
      sidelobe = Swift.max(sidelobe, part)
    }
    let peak = Double(magnitude[index])
    guard peak > 0 else { return nil }
    return Swift.min(Self.maxPsr, peak / Swift.max(Double(sidelobe), peak / Self.maxPsr))
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
}
