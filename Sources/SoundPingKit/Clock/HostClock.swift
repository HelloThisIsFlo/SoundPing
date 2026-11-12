import Darwin

/// The `mach_timebase_info` pair as it is stored in a result: nanoseconds = ticks * numer / denom.
/// Apple Silicon reports 125/3, Intel 1/1.
public struct HostTimebase: Codable, Sendable, Equatable {
  public var numer: UInt32
  public var denom: UInt32

  public init(numer: UInt32, denom: UInt32) {
    self.numer = numer
    self.denom = denom
  }
}

/// Converts `mach_absolute_time` ticks, the one clock CoreAudio and CoreMIDI both stamp with, to
/// nanoseconds and back (CAL-03). Wall-clock time types are never used for alignment.
///
/// Everything is computed in Double. The naive `ticks * numer / denom` in UInt64 overflows once
/// `ticks * numer` passes 2^64, which at 125/3 happens near 2^57 ticks; Double keeps the full
/// range and 53 bits of mantissa, which is far finer than the 41.7 ns tick. Callers should still
/// subtract two tick values as integers before converting, so the difference stays exact.
public struct HostClock: Sendable, Equatable {
  public let numer: UInt32
  public let denom: UInt32

  public init(numer: UInt32, denom: UInt32) {
    self.numer = numer
    self.denom = denom
  }

  public init(_ timebase: HostTimebase) {
    self.init(numer: timebase.numer, denom: timebase.denom)
  }

  /// The timebase of the machine this process runs on.
  public static let system: HostClock = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return HostClock(numer: info.numer, denom: info.denom)
  }()

  public var timebase: HostTimebase { HostTimebase(numer: numer, denom: denom) }

  /// Nanoseconds per tick.
  public var nanosPerTick: Double { Double(numer) / Double(denom) }

  public func ticksToNanos(_ ticks: UInt64) -> Double {
    Double(ticks) * nanosPerTick
  }

  public func ticksToNanos(_ ticks: Double) -> Double {
    ticks * nanosPerTick
  }

  public func nanosToTicks(_ nanos: Double) -> Double {
    nanos / nanosPerTick
  }

  /// `nanosToTicks`, rounded to a whole tick. Negative or non-finite input gives 0.
  public func nanosToWholeTicks(_ nanos: Double) -> UInt64 {
    let ticks = nanosToTicks(nanos).rounded()
    guard ticks.isFinite, ticks > 0, ticks < Double(UInt64.max) else { return 0 }
    return UInt64(ticks)
  }

  /// A tick difference expressed as frames at `sampleRate`.
  public func frames(forTicks ticks: Double, sampleRate: Double) -> Double {
    ticksToNanos(ticks) / 1e9 * sampleRate
  }

  /// A frame count expressed as host ticks at `sampleRate`.
  public func ticks(forFrames frames: Double, sampleRate: Double) -> Double {
    nanosToTicks(frames / sampleRate * 1e9)
  }
}
