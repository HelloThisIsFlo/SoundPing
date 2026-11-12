import CoreAudio
import Foundation
import Testing

@testable import SoundPingKit

/// A real round trip on this Mac's devices (CAL-01). It needs a loop: the output of the chosen
/// device must come back on the chosen input channel, either through the interface's own loopback
/// channel (Scarlett "Loop 1" fed by Focusrite Control) or a patch cable. Runs only with
/// SOUNDPING_HW=1; SOUNDPING_HW_OUTPUT, SOUNDPING_HW_INPUT and SOUNDPING_HW_IN_CHANNEL (a number
/// or a channel name) name another loop. Each run finds its own level with the preflight ramp
/// (first probe -48 dBFS, never above the loopback ceiling of -6), then plays 20 chirps, twice.
/// The first run may make macOS ask the host app for microphone access.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOUNDPING_HW"] == "1"))
struct HardwareRoundTripTests {
  private static let environment = ProcessInfo.processInfo.environment

  private static func resolveSetup() throws -> ResolvedSetup {
    let listing = try HALDeviceCatalog().listing()
    let output = environment["SOUNDPING_HW_OUTPUT"] ?? "Scarlett"
    let input = environment["SOUNDPING_HW_INPUT"] ?? output
    let resolver = SetupResolver(listing: listing, setups: nil, simulated: false)

    // The input channel is a number for the resolver; a name is looked up in the input device first.
    let channelSelector = environment["SOUNDPING_HW_IN_CHANNEL"] ?? "Loop 1"
    var inChannel = channelSelector
    if Int(channelSelector) == nil {
      let probe = try resolver.resolve(
        SetupSelectors(output: output, input: input, inChannel: "1"))
      let device = try #require(listing.audio.first { $0.uid == probe.input.uid })
      let match = try #require(
        device.input?.channels.first {
          $0.name.localizedCaseInsensitiveCompare(channelSelector) == .orderedSame
        },
        "\(device.name) has no input channel named '\(channelSelector)'")
      inChannel = String(match.index)
    }
    var setup = try resolver.resolve(
      SetupSelectors(output: output, input: input, inChannel: inChannel))
    setup.requestedBufferFrames = 128
    return setup
  }

  private static func runOnce(setup: ResolvedSetup, store: RunStore) async throws -> RunResult {
    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: 20_261_112)
    parameters.hits = 20
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: setup,
      label: "hardware-smoke")
    var result: RunResult?
    for try await event in RunCoordinator(backend: HALBackend(), store: store).run(request) {
      if case .finished(let finished) = event { result = finished }
    }
    return try #require(result)
  }

  @Test func twoRunsOnTheSameLoopAgreeWithinTwoFrames() async throws {
    let setup = try Self.resolveSetup()
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-hw-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))

    var medians: [Double] = []
    for pass in 1...2 {
      let result = try await Self.runOnce(setup: setup, store: store)
      let path = try #require(result.measured.path)
      let median = try #require(path.median).frames
      medians.append(median)

      #expect(path.valid >= 18, "pass \(pass): only \(path.valid) of \(path.n) hits were valid")
      #expect(
        (0...4_800).contains(median), "pass \(pass): path median \(median) frames is not plausible")
      #expect(
        result.selfTest != nil, "pass \(pass): a same-device run must carry a clock self-test")
      // SoundPing's own buffer, as applied, not as requested.
      #expect(result.setup.bufferFrames == 128, "pass \(pass): buffer \(result.setup.bufferFrames)")
      #expect(result.simulation == nil)
    }
    #expect(
      abs(medians[0] - medians[1]) <= 2,
      "medians \(medians) differ by more than 2 frames")
  }

  /// Every listener registers on a real device and is gone again afterwards, and watching a device
  /// that nobody touches says nothing.
  @Test func deviceListenersRegisterOnARealDeviceAndComeOffAgain() async throws {
    let listing = try HALDeviceCatalog().listing()
    let setup = try Self.resolveSetup()
    let device = try #require(listing.audio.first { $0.uid == setup.output.uid })
    let ids = HALProperty.array(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices,
      of: AudioDeviceID.self, initial: AudioDeviceID(0))
    let id = try #require(
      ids.first { HALProperty.string($0, kAudioDevicePropertyDeviceUID) == device.uid })
    let buffer = Int(
      HALProperty.get(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) ?? 0)

    let rt = RTState(
      RTState.Configuration(
        sampleRate: device.nominalSampleRate, inputSlot: nil, outputSlots: [], templates: [],
        scheduleCapacity: 1, stampCapacity: 1))
    let (stream, sink) = AsyncStream<DeviceEvent>.makeStream()
    let listeners = DeviceListeners(
      watching: [.init(id: id, uid: device.uid, bufferFrames: buffer)],
      rate: device.nominalSampleRate, rt: rt, sink: sink)
    // Six per-device selectors (stream configuration once per direction) plus the system list.
    #expect(listeners.refused.load(ordering: .relaxed) == 0)
    listeners.remove()
    listeners.remove()
    sink.finish()
    var seen: [DeviceEvent] = []
    for await event in stream { seen.append(event) }
    #expect(seen.isEmpty, "unexpected events: \(seen)")
  }
}
