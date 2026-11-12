import Foundation
import Testing

@testable import SoundPingKit

/// RES-01: the numbers SoundPing prints agree with numpy and never hide an outlier.
@Suite struct StatsTests {
  static let sampleRate = 48_000.0

  /// 25 latencies in frames, deliberately unsorted.
  static let fixture: [Double] = [
    412.31, 412.87, 411.95, 413.4, 412.02, 412.66, 411.58, 412.49, 414.1, 412.12, 411.77, 412.93,
    412.38, 413.05, 411.4, 412.71, 412.2, 412.55, 413.62, 411.88, 412.44, 412.09, 413.27, 412.8,
    411.69,
  ]

  static func summary(_ values: [Double], n: Int? = nil) -> SummaryStats {
    Stats.summarize(latencies: values, n: n ?? values.count, sampleRate: sampleRate)
  }

  @Test func percentilesMatchNumpyToANanoframe() throws {
    // Expected values come from numpy's default (linear) method:
    //   uv run --with numpy python -c "import numpy as np; v=[412.31,412.87,411.95,413.4,412.02,
    //   412.66,411.58,412.49,414.1,412.12,411.77,412.93,412.38,413.05,411.4,412.71,412.2,412.55,
    //   413.62,411.88,412.44,412.09,413.27,412.8,411.69]; print([repr(float(np.percentile(v,p)))
    //   for p in (5,50,95)])"
    let expected: [(p: Double, value: Double)] = [(0.05, 411.602), (0.5, 412.44), (0.95, 413.576)]
    let sorted = Self.fixture.sorted()
    for (p, value) in expected {
      #expect(abs(Stats.percentile(sorted, p) - value) <= 1e-9, "p\(p * 100)")
    }

    let stats = Self.summary(Self.fixture)
    #expect(abs(try #require(stats.median).frames - 412.44) <= 1e-9)
    #expect(abs(try #require(stats.p5).frames - 411.602) <= 1e-9)
    #expect(abs(try #require(stats.p95).frames - 413.576) <= 1e-9)
    #expect(abs(try #require(stats.jitter).frames - (413.576 - 411.602)) <= 1e-9)
    #expect(try #require(stats.min).frames == 411.4)
    #expect(try #require(stats.max).frames == 414.1)
  }

  @Test func theOrderOfTheInputDoesNotChangeTheStatistics() {
    #expect(Self.summary(Self.fixture) == Self.summary(Self.fixture.sorted()))
    #expect(Self.summary(Self.fixture) == Self.summary(Self.fixture.reversed()))
  }

  @Test func oneHitIsItsOwnEveryStatistic() throws {
    let stats = Self.summary([412.37])
    #expect(stats.n == 1 && stats.valid == 1)
    for value in [stats.median, stats.p5, stats.p95, stats.min, stats.max] {
      #expect(try #require(value).frames == 412.37)
    }
    #expect(try #require(stats.jitter).frames == 0)

    let histogram = try #require(Stats.histogram(latencies: [412.37]))
    #expect(histogram.counts == [1])
  }

  @Test func noValidHitMeansNoNumbersNotZeros() {
    let stats = Self.summary([], n: 30)
    #expect(stats.n == 30 && stats.valid == 0)
    #expect(stats.median == nil && stats.p5 == nil && stats.p95 == nil)
    #expect(stats.jitter == nil && stats.min == nil && stats.max == nil)
    #expect(Stats.histogram(latencies: []) == nil)
  }

  @Test func identicalLatenciesShareOneBin() throws {
    let histogram = try #require(Stats.histogram(latencies: Array(repeating: 412.5, count: 10)))
    #expect(histogram.counts == [10])
  }

  @Test func aValueOnABinEdgeGoesToTheUpperBin() throws {
    // Dyadic width (0.25 frame): 100.25 is the edge between bin 0 and bin 1.
    let small = try #require(Stats.histogram(latencies: [100, 100.25, 100.5, 100.75]))
    #expect(small.binWidthFrames == 0.25)
    #expect(small.counts == [1, 1, 1, 1])

    // A width that is not exactly representable (spread 7 gives 0.35): the edge value computed the
    // way a reader computes it, first + k * width, must still sit in bin k, for every k.
    let reference = try #require(Stats.histogram(latencies: [0, 7]))
    for k in 1..<20 {
      let edge = reference.firstBinStartFrames + Double(k) * reference.binWidthFrames
      let histogram = try #require(Stats.histogram(latencies: [0, 7, edge]))
      #expect(histogram.counts[k] == 1, "edge \(k) = \(edge) fell into the lower bin")
    }
  }

  @Test func histogramCountsAddUpToTheValidHits() throws {
    let histogram = try #require(Stats.histogram(latencies: Self.fixture))
    #expect(histogram.counts.reduce(0, +) == Self.fixture.count)
  }

  @Test func anOutlierStaysAndMovesTheMedianByAtMostOneRank() throws {
    var values = (0..<99).map { 412 + Double($0 % 7) * 0.05 }
    let withoutOutlier = Self.summary(values)
    values.append(912)
    let stats = Self.summary(values)

    #expect(try #require(stats.max).frames == 912)
    #expect(stats.valid == 100)
    let sorted = values.sorted()
    let median = try #require(stats.median).frames
    #expect(median >= sorted[48] && median <= sorted[50])
    #expect(abs(median - (try #require(withoutOutlier.median).frames)) <= 0.05 + 1e-12)

    let histogram = try #require(Stats.histogram(latencies: values))
    #expect(histogram.counts.last == 1)
    #expect(histogram.counts.reduce(0, +) == 100)
  }

  @Test func millisecondsAreFramesOverSampleRateTimesAThousand() throws {
    let stats = Self.summary([480])
    #expect(try #require(stats.median).ms == 10.0)
    #expect(try #require(stats.median).ms == 480 / 48_000.0 * 1000)
  }
}
