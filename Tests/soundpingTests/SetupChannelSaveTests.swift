import Foundation
import SoundPingKit
import Testing

@testable import soundping

/// A probed channel is only written into a saved setup that binds the devices it was found on
/// (a channel index means nothing on another device).
@Suite struct SetupChannelSaveTests {
  private static func options(store: URL, setup: String) throws -> RunOptions {
    try RunOptions.parse(["--store", store.path, "--setup", setup])
  }

  private static let interface = DeviceRef(uid: "interface-uid", name: "Interface")
  private static let microphone = DeviceRef(uid: "microphone-uid", name: "Microphone")

  private static func resolved(input: DeviceRef) -> ResolvedSetup {
    ResolvedSetup(output: interface, input: input, outChannels: [1, 2], inChannel: 7)
  }

  @Test func theChannelOnlyGoesIntoASetupThatBindsTheProbedDevices() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let options = try Self.options(store: folder, setup: "foo")

    let scarlett = Self.resolved(input: Self.interface)
    try options.persistSetup(scarlett, as: "foo")
    #expect(try options.setupBindsSameDevices("foo", as: scarlett))
    try options.updateSetupChannel(9, in: "foo", probedOn: scarlett)

    let other = Self.resolved(input: Self.microphone)
    #expect(try !options.setupBindsSameDevices("foo", as: other))
    #expect(try !options.setupBindsSameDevices("missing", as: scarlett))
    do {
      try options.updateSetupChannel(2, in: "foo", probedOn: other)
      Issue.record("the channel was written into a setup with a different input device")
    } catch let error as SoundPingError {
      #expect(error.code == "setupDeviceMismatch")
    }
    let kept = try Setups.load(from: StorePaths.resolve(flag: folder.path, environment: [:]).setups)
    #expect(kept.setups["foo"]?.inChannel == 9, "the refused update left the setup untouched")
  }
}
