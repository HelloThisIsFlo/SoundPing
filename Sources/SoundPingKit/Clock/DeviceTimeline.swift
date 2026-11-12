/// One audio callback's timestamp for one direction of one device: where the callback's first
/// frame sits on the device's sample clock, and on the host clock (ticks of `mach_absolute_time`).
public struct TimelinePoint: Codable, Sendable, Equatable {
  public var sampleTime: Double
  public var hostTime: UInt64
  /// Apple's `mRateScalar`: actual host ticks per sample over the nominal ticks per sample.
  public var rateScalar: Double
  public var frames: Int

  public init(sampleTime: Double, hostTime: UInt64, rateScalar: Double, frames: Int) {
    self.sampleTime = sampleTime
    self.hostTime = hostTime
    self.rateScalar = rateScalar
    self.frames = frames
  }
}

/// Every callback's timestamps of a run. `input` and `output` are per direction: a callback whose
/// side was skipped or untimestamped is missing from its list, so the two lists can differ in
/// length and must never be paired by index (WR-03). The only per-callback pairing is
/// `ioOffsetFrames`, which comes from single log entries that carry both sides of one callback.
public struct StampLog: Sendable, Equatable {
  public var input: [TimelinePoint]
  public var output: [TimelinePoint]
  /// On a single duplex device, per callback that has both sides, how far its output sample label
  /// runs ahead of its input label. Empty on two devices, whose labels are unrelated.
  public var ioOffsetFrames: [Double]

  public init(
    input: [TimelinePoint] = [], output: [TimelinePoint] = [], ioOffsetFrames: [Double] = []
  ) {
    self.input = input
    self.output = output
    self.ioOffsetFrames = ioOffsetFrames
  }

  public var isEmpty: Bool { input.isEmpty || output.isEmpty }
}

/// The mapping between one device's sample clock and the host clock, for one direction (CAL-03).
///
/// Never one global fit: a query is answered by a least-squares line through the 33 callbacks
/// nearest to it (the one next to the query and 16 either side), so a drifting or stepping clock
/// only pollutes the neighbourhood it happened in. A query outside the logged range extrapolates
/// from the 33 callbacks at the edge.
///
/// The `rateScalar` each callback carries is the HAL's own estimate of the slope. The fit does not
/// trust it over the data; it is the slope when a neighbourhood holds fewer than two distinct
/// sample times, and `rateScalarSlope(nearSample:)` exposes it so a caller can cross-check the fit.
///
/// All arithmetic is Double on values taken relative to a nearby reference, so a sample time of
/// 10^10 or a host time above 2^50 ticks costs no precision.
public struct DeviceTimeline: Sendable {
  /// Callbacks used on each side of the query.
  public static let halfWindow = 16

  private let sampleTimes: [Double]
  /// Host ticks relative to `hostBase`, so the fit never subtracts two huge Doubles.
  private let hostOffsets: [Double]
  private let rateScalars: [Double]
  private let lastFrames: Int
  private let hostBase: UInt64
  private let sampleRate: Double
  private let clock: HostClock

  /// Nil when `points` is empty.
  public init?(points: [TimelinePoint], sampleRate: Double, clock: HostClock) {
    guard !points.isEmpty, sampleRate > 0 else { return nil }
    var ordered = points
    if !points.indices.dropFirst().allSatisfy({ points[$0 - 1].sampleTime <= points[$0].sampleTime }
    ) {
      ordered.sort { $0.sampleTime < $1.sampleTime }
    }
    let base = ordered[0].hostTime
    self.hostBase = base
    self.sampleTimes = ordered.map(\.sampleTime)
    self.hostOffsets = ordered.map { Double(Int64(bitPattern: $0.hostTime &- base)) }
    self.rateScalars = ordered.map(\.rateScalar)
    self.lastFrames = ordered[ordered.count - 1].frames
    self.sampleRate = sampleRate
    self.clock = clock
  }

  public var count: Int { sampleTimes.count }

  /// The sample times this timeline has callbacks for: from the first callback's first frame to the
  /// last callback's end. Outside it a query would extrapolate, which a judgement must not do.
  public var coveredSamples: ClosedRange<Double> {
    sampleTimes[0]...(sampleTimes[sampleTimes.count - 1] + Double(lastFrames))
  }

  /// The host time, in ticks, at which the device's sample clock reads `sample`.
  public func hostTicks(forSample sample: Double) -> Double {
    let fit = fit(near: sample, in: sampleTimes)
    return Double(hostBase) + fit.hostOffset(forSample: sample)
  }

  /// The device sample time at host time `ticks`.
  public func sample(forHostTicks ticks: Double) -> Double {
    let offset = ticks - Double(hostBase)
    let fit = fit(near: offset, in: hostOffsets)
    return fit.sample(forHostOffset: offset)
  }

  /// Host ticks per sample frame of the fitted line around `sample`.
  public func fittedSlope(nearSample sample: Double) -> Double {
    fit(near: sample, in: sampleTimes).slope
  }

  /// The slope the HAL's `rateScalar` implies around `sample`: nominal ticks per frame times the
  /// scalar of the nearest callback.
  public func rateScalarSlope(nearSample sample: Double) -> Double {
    let index = nearestIndex(to: sample, in: sampleTimes)
    return nominalTicksPerFrame * usableScalar(rateScalars[index])
  }

  // MARK: - Local least squares

  private struct Fit {
    var sampleRef: Double
    var hostRef: Double
    var sampleMean: Double
    var hostMean: Double
    var slope: Double

    func hostOffset(forSample sample: Double) -> Double {
      hostRef + hostMean + slope * ((sample - sampleRef) - sampleMean)
    }

    func sample(forHostOffset offset: Double) -> Double {
      sampleRef + sampleMean + ((offset - hostRef) - hostMean) / slope
    }
  }

  private var nominalTicksPerFrame: Double {
    clock.ticks(forFrames: 1, sampleRate: sampleRate)
  }

  private func usableScalar(_ scalar: Double) -> Double {
    scalar.isFinite && scalar > 0 ? scalar : 1
  }

  private func nearestIndex(to key: Double, in keys: [Double]) -> Int {
    var low = 0
    var high = keys.count
    while low < high {
      let middle = (low + high) / 2
      if keys[middle] < key { low = middle + 1 } else { high = middle }
    }
    if low == 0 { return 0 }
    if low == keys.count { return keys.count - 1 }
    return key - keys[low - 1] <= keys[low] - key ? low - 1 : low
  }

  /// The least-squares line of host offset on sample time through the callbacks nearest `key`
  /// (`keys` is `sampleTimes` or `hostOffsets`, whichever the query is expressed in).
  private func fit(near key: Double, in keys: [Double]) -> Fit {
    let centre = nearestIndex(to: key, in: keys)
    let width = 2 * Self.halfWindow + 1
    var low = Swift.max(0, centre - Self.halfWindow)
    var high = Swift.min(count - 1, centre + Self.halfWindow)
    // At either end of the log, take the nearest `width` callbacks rather than a lopsided few.
    if high - low + 1 < width {
      if low == 0 {
        high = Swift.min(count - 1, width - 1)
      } else {
        low = Swift.max(0, count - width)
      }
    }

    let reference = Swift.min(Swift.max(centre, low), high)
    let sampleRef = sampleTimes[reference]
    let hostRef = hostOffsets[reference]
    let n = Double(high - low + 1)

    var sampleSum = 0.0
    var hostSum = 0.0
    for index in low...high {
      sampleSum += sampleTimes[index] - sampleRef
      hostSum += hostOffsets[index] - hostRef
    }
    let sampleMean = sampleSum / n
    let hostMean = hostSum / n

    var sxx = 0.0
    var sxy = 0.0
    for index in low...high {
      let dx = (sampleTimes[index] - sampleRef) - sampleMean
      let dy = (hostOffsets[index] - hostRef) - hostMean
      sxx += dx * dx
      sxy += dx * dy
    }

    let slope: Double
    if high > low, sxx > 0 {
      slope = sxy / sxx
    } else {
      slope = nominalTicksPerFrame * usableScalar(rateScalars[reference])
    }
    return Fit(
      sampleRef: sampleRef, hostRef: hostRef, sampleMean: sampleMean, hostMean: hostMean,
      slope: slope > 0 ? slope : nominalTicksPerFrame)
  }
}
