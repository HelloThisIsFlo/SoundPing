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
    help:
      "Simulated path gain in dB. The converter clamps at full scale, so a large value clips."
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

  func scenario(seed: UInt64) -> Scenario {
    Scenario(
      latencyFrames: simLatency, jitterFrames: simJitter, noiseRms: simNoise,
      pathGainDb: simGainDb, missedHits: simMiss.values, xrunHits: simXrun.values,
      driftPPM: simDriftPpm, stampBiasFrames: simStampBias, seed: seed)
  }
}
