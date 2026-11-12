import Foundation
import Testing

@testable import SoundPingKit

/// Reads this Mac's real CoreAudio and CoreMIDI state, so it only runs with SOUNDPING_HW=1
/// (CI runners may have no audio devices at all).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOUNDPING_HW"] == "1"))
struct HardwareDevicesTests {
  private func listing() throws -> DevicesListing {
    try HALDeviceCatalog().listing()
  }

  @Test func atLeastOneAudioDeviceIsListed() throws {
    #expect(!(try listing().audio.isEmpty))
  }

  @Test func everyDeviceHasAUIDAndAName() throws {
    for device in try listing().audio {
      #expect(!device.uid.isEmpty)
      #expect(!device.name.isEmpty)
    }
  }

  @Test func channelIndicesAreOneThroughCount() throws {
    for device in try listing().audio {
      for scope in [device.input, device.output].compactMap({ $0 }) {
        #expect(scope.channels.map(\.index) == Array(1...scope.channels.count))
        #expect(scope.streamLatencies.count >= (scope.channels.map(\.streamIndex).max() ?? 0) + 1)
      }
    }
  }

  @Test func aScarlettExposesItsLoopbackChannel() throws {
    guard
      let scarlett = try listing().audio.first(where: {
        $0.name.localizedCaseInsensitiveContains("Scarlett")
      }),
      let input = scarlett.input
    else { return }
    #expect(input.channels.map(\.name).contains("Loop 1"))
  }

  @Test func theBuiltInMicrophoneKeepsItsLatencyInTheStream() throws {
    guard
      let mic = try listing().audio.first(where: { $0.name == "MacBook Pro Microphone" }),
      let input = mic.input
    else { return }
    #expect(input.streamLatencies.reduce(0, +) > 0)
  }

  @Test func theListingIsSortedAndStable() throws {
    let first = try listing()
    #expect(first == first.sorted())
  }

  @Test func midiListingReturnsWithoutThrowing() throws {
    _ = try listing().midi
  }
}
