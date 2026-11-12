import ArgumentParser
import Foundation
import SoundPingKit

/// A comma-separated list of hit indices, e.g. `8,15`. Indices use the numbering of
/// `HitRecord.index`: warm-ups come first.
struct HitIndexList: ExpressibleByArgument, Sendable {
  var values: [Int]

  init(_ values: [Int]) {
    self.values = values
  }

  init?(argument: String) {
    var values: [Int] = []
    for piece in argument.split(separator: ",", omittingEmptySubsequences: false) {
      guard let value = Int(piece.trimmingCharacters(in: .whitespaces)), value >= 0 else {
        return nil
      }
      values.append(value)
    }
    self.values = values
  }

  var defaultValueDescription: String {
    values.isEmpty ? "none" : values.map(String.init).joined(separator: ",")
  }
}

/// Flags for the simulated device (ENG-05). They do nothing without `--simulate`.
/// Fault injection: `--sim-miss`, `--sim-xrun` and `--sim-gain-db` fill the matching `Scenario` fields.
/// Clock faults: `--sim-drift-ppm` and `--sim-stamp-bias` exercise the host-clock self-test.
/// Device changes: `--sim-fault <kind>@<hit>` exercises the mid-run abort (ENG-07).
struct SimulationOptions: ParsableArguments {
  @Flag(help: "Use the simulated device instead of real hardware.")
  var simulate = false

  @Option(help: "Simulated path latency in frames.")
  var simLatency: Double = 412.37

  @Option(help: "Simulated per-hit jitter (Gaussian sigma) in frames.")
  var simJitter: Double = 0.5

  @Option(help: "Simulated noise floor, RMS (1.0 = full scale).")
  var simNoise: Double = 0.001

  @Option(
    parsing: .unconditional,
    help:
      "Simulated path gain in dB (may be negative). The converter clamps at full scale, so a large value clips."
  )
  var simGainDb: Double = 0

  @Option(
    help:
      "Comma-separated hit indices that never arrive (warm-ups count first), e.g. 8,15."
  )
  var simMiss = HitIndexList([])

  @Option(
    help:
      "Comma-separated hit indices that suffer an input xrun (64 frames lost), e.g. 25."
  )
  var simXrun = HitIndexList([])

  @Option(
    parsing: .unconditional,
    help:
      "Simulated drift of the device's sample clock against the host clock, in parts per million."
  )
  var simDriftPpm: Double = 0

  @Option(
    parsing: .unconditional,
    help:
      "Simulated skew of every input host stamp, in frames. Above 2 the clock self-test must fail."
  )
  var simStampBias: Double = 0

  @Option(
    help:
      "A device change part way through the run, as <kind>@<hit>; repeat the flag for several. Kinds: deviceGone, sampleRateChange, bufferChange, streamConfigChange (each aborts the run with exit 75) and overload (rejects that one hit). Example: sampleRateChange@30."
  )
  var simFault: [String] = []

  @Option(
    help:
      "The microphone permission the simulated process holds: authorized, denied or restricted. Denied and restricted make the capture all zeros, as macOS does."
  )
  var simPermission = "authorized"

  @Flag(help: "The simulated input delivers exact zeros whatever is played, like a dead source.")
  var simInputZeros = false

  @Flag(help: "The simulated output reports itself muted.")
  var simMuted = false

  @Option(
    help:
      "The 1-based input channel the simulated stimulus comes back on; every other channel hears only noise. Without it every channel hears the stimulus."
  )
  var simLoopChannel: Int?

  func scenario(seed: UInt64, bufferFrames: Int = 128) throws -> Scenario {
    guard let permission = PermissionStatus(rawValue: simPermission),
      permission != .notDetermined
    else {
      throw SoundPingError.usage(
        "invalidParameters",
        "--sim-permission takes authorized, denied or restricted; got '\(simPermission)'",
        context: ["parameter": "sim-permission", "value": simPermission])
    }
    // These are developer and CI flags, but the CLI contract is a named usage error, never a
    // crash: a huge or non-finite value would trap in the simulator's frame arithmetic.
    try Self.require(simLatency, "sim-latency", in: -48_000...480_000, unit: "frames")
    try Self.require(simJitter, "sim-jitter", in: 0...48_000, unit: "frames")
    try Self.require(simNoise, "sim-noise", in: 0...1, unit: "RMS")
    try Self.require(simGainDb, "sim-gain-db", in: -300...300, unit: "dB")
    try Self.require(simDriftPpm, "sim-drift-ppm", in: -10_000...10_000, unit: "ppm")
    try Self.require(simStampBias, "sim-stamp-bias", in: -10_000...10_000, unit: "frames")
    return Scenario(
      latencyFrames: simLatency, jitterFrames: simJitter, noiseRms: simNoise,
      pathGainDb: simGainDb, bufferFrames: bufferFrames, missedHits: simMiss.values,
      xrunHits: simXrun.values,
      driftPPM: simDriftPpm, stampBiasFrames: simStampBias,
      faults: try simFault.map(Fault.parse), permission: permission, inputZeros: simInputZeros,
      outputMuted: simMuted, loopChannel: simLoopChannel, seed: seed)
  }

  private static func require(
    _ value: Double, _ flag: String, in range: ClosedRange<Double>, unit: String
  ) throws {
    guard value.isFinite, range.contains(value) else {
      throw SoundPingError.usage(
        "invalidParameters",
        "--\(flag) must be a finite number from \(range.lowerBound) to \(range.upperBound) \(unit), got \(value)",
        context: ["parameter": flag, "value": String(value)])
    }
  }
}
