import Foundation
import Testing

@testable import SoundPingKit
@testable import soundping

/// The simulation flags are developer and CI flags, but a bad value is a named usage error, never a
/// trap in the simulator's frame arithmetic (IN-12).
@Suite struct SimulationOptionsTests {
  private static func scenario(_ arguments: [String]) throws -> Scenario {
    try SimulationOptions.parse(["--simulate"] + arguments).scenario(seed: 1)
  }

  @Test func outOfRangeAndNonFiniteValuesAreUsageErrorsNamingTheFlag() {
    let bad: [(flag: String, value: String)] = [
      ("--sim-stamp-bias", "1e300"), ("--sim-stamp-bias", "nan"),
      ("--sim-latency", "1e300"), ("--sim-latency", "inf"), ("--sim-latency", "nan"),
      ("--sim-jitter", "1e300"), ("--sim-jitter", "-1"), ("--sim-jitter", "nan"),
      ("--sim-noise", "-0.1"), ("--sim-noise", "inf"), ("--sim-noise", "nan"),
      ("--sim-drift-ppm", "1e300"), ("--sim-drift-ppm", "-inf"),
      ("--sim-gain-db", "nan"), ("--sim-gain-db", "1e300"),
    ]
    for (flag, value) in bad {
      do {
        _ = try Self.scenario(["\(flag)=\(value)"])
        Issue.record("\(flag) \(value) must be refused")
      } catch let error as SoundPingError {
        #expect(error.kind == .usage, "\(flag) \(value)")
        #expect(error.code == "invalidParameters", "\(flag) \(value)")
        #expect(error.context["parameter"] == String(flag.dropFirst(2)), "\(flag) \(value)")
      } catch {
        Issue.record("\(flag) \(value): unexpected error \(error)")
      }
    }
  }

  @Test func sensibleValuesPassIncludingNegativesWhereTheyMakeSense() throws {
    let scenario = try Self.scenario([
      "--sim-latency=-24", "--sim-jitter=0", "--sim-noise=0", "--sim-gain-db=-80",
      "--sim-drift-ppm=-50", "--sim-stamp-bias=3",
    ])
    #expect(scenario.latencyFrames == -24)
    #expect(scenario.pathGainDb == -80)
    #expect(scenario.driftPPM == -50)
    #expect(scenario.stampBiasFrames == 3)
  }
}
