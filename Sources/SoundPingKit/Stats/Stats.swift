import Foundation

public enum Stats {
  /// Type-7 percentile (linear interpolation) on ascending values; matches numpy's default.
  public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
    precondition(!sorted.isEmpty, "percentile of an empty sample")
    let h = (Double(sorted.count) - 1) * p
    let lo = Int(h.rounded(.down))
    let hi = Swift.min(lo + 1, sorted.count - 1)
    return sorted[lo] + (h - Double(lo)) * (sorted[hi] - sorted[lo])
  }

  /// `latencies` are the found measure-phase hits in frames; `n` is how many measure-phase hits fired.
  /// Every statistic is nil when nothing was found.
  public static func summarize(latencies: [Double], n: Int, sampleRate: Double) -> SummaryStats {
    guard !latencies.isEmpty else { return SummaryStats(n: n, valid: 0) }
    let sorted = latencies.sorted()
    func value(_ frames: Double) -> StatValue {
      StatValue(frames: frames, ms: frames / sampleRate * 1000)
    }
    let p5 = percentile(sorted, 0.05)
    let p95 = percentile(sorted, 0.95)
    return SummaryStats(
      n: n,
      valid: sorted.count,
      median: value(percentile(sorted, 0.5)),
      p5: value(p5),
      p95: value(p95),
      jitter: value(p95 - p5),
      min: value(sorted[0]),
      max: value(sorted[sorted.count - 1]))
  }

  /// Half-open bins [a, b). Bin width is 0.25 frame when the spread is at most 5 frames, else a
  /// twentieth of the spread. Nil when there is nothing to bin.
  public static func histogram(latencies: [Double]) -> Histogram? {
    guard let lo = latencies.min(), let hi = latencies.max() else { return nil }
    let spread = hi - lo
    let width = spread <= 5 ? 0.25 : spread / 20
    let first = (lo / width).rounded(.down) * width
    var counts = [Int](repeating: 0, count: Int(((hi - first) / width).rounded(.down)) + 1)
    for value in latencies {
      let bin = Swift.min(counts.count - 1, Swift.max(0, Int(((value - first) / width).rounded(.down))))
      counts[bin] += 1
    }
    return Histogram(binWidthFrames: width, firstBinStartFrames: first, counts: counts)
  }
}
