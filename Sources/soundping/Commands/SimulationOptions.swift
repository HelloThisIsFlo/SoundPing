import ArgumentParser
import SoundPingKit

/// Flags for the simulated device (ENG-05). They do nothing without `--simulate`.
struct SimulationOptions: ParsableArguments {
  @Flag(help: "Use the simulated device instead of real hardware.")
  var simulate = false

  @Option(help: "Simulated path latency in frames.")
  var simLatency: Double = 412.37

  @Option(help: "Simulated per-hit jitter (Gaussian sigma) in frames.")
  var simJitter: Double = 0.5

  @Option(help: "Simulated noise floor, RMS (1.0 = full scale).")
  var simNoise: Double = 0.001

  func scenario(seed: UInt64) -> Scenario {
    Scenario(
      latencyFrames: simLatency, jitterFrames: simJitter, noiseRms: simNoise, seed: seed)
  }
}
