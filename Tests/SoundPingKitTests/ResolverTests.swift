import Foundation
import Testing

@testable import SoundPingKit

@Suite struct ResolverTests {
  // MARK: Fixtures

  private func simulatedResolver(setups: SetupsFile? = nil) throws -> SetupResolver {
    SetupResolver(listing: try SimulatedCatalog().listing(), setups: setups, simulated: true)
  }

  private func scope(
    _ names: [String], preferredStereo: [Int]? = nil
  ) -> ScopeInfo {
    ScopeInfo(
      channels: names.enumerated().map {
        ChannelInfo(
          index: $0.offset + 1, name: $0.element, streamIndex: 0, channelInStream: $0.offset + 1)
      },
      deviceLatency: 0, streamLatencies: [0], safetyOffset: 0, bufferFrameSize: 128,
      bufferFrameSizeRange: FrameSizeRange(min: 15, max: 4096), preferredStereo: preferredStereo)
  }

  private func device(
    _ uid: String, _ name: String, inputs: [String] = [], outputs: [String] = [],
    preferredStereo: [Int]? = nil
  ) -> DeviceInfo {
    DeviceInfo(
      uid: uid, name: name, transport: "usb", nominalSampleRate: 48_000,
      input: inputs.isEmpty ? nil : scope(inputs),
      output: outputs.isEmpty ? nil : scope(outputs, preferredStereo: preferredStereo))
  }

  /// A hardware-like catalog (resolver built with `simulated: false`).
  private func hardwareResolver(
    devices: [DeviceInfo]? = nil, defaults: DeviceDefaults = DeviceDefaults(),
    midi: MIDIListing = MIDIListing(), setups: SetupsFile? = nil
  ) -> SetupResolver {
    let all =
      devices ?? [
        device(
          "uid-scarlett", "Scarlett 16i16 4th Gen", inputs: ["Input 1", "Loop 1"],
          outputs: ["Output 1", "Output 2", "Output 3", "Output 4"], preferredStereo: [3, 4]),
        device("uid-mic", "MacBook Pro Microphone", inputs: ["Input 1"]),
        device(
          "uid-speakers", "MacBook Pro Speakers", outputs: ["Output 1", "Output 2"],
          preferredStereo: [1, 2]),
      ]
    return SetupResolver(
      listing: DevicesListing(audio: all, midi: midi, defaults: defaults), setups: setups,
      simulated: false)
  }

  private func failure(_ body: () throws -> Void) -> SoundPingError? {
    do {
      try body()
      return nil
    } catch let error as SoundPingError {
      return error
    } catch {
      return nil
    }
  }

  private func midiEndpoint(_ id: Int32, _ name: String) -> MIDIEndpointInfo {
    MIDIEndpointInfo(uniqueID: id, name: name, displayName: name, kind: .destination)
  }

  // MARK: Device selectors (D-08)

  @Test func anExactUIDBeatsAnyName() throws {
    let resolver = hardwareResolver(devices: [
      device("uid-a", "Interface A", inputs: ["Input 1"], outputs: ["Output 1", "Output 2"]),
      device("uid-b", "uid-a", inputs: ["Input 1"], outputs: ["Output 1", "Output 2"]),
    ])
    let setup = try resolver.resolve(
      SetupSelectors(output: "uid-a", input: "uid-a", inChannel: "1"))
    #expect(setup.output.uid == "uid-a")
  }

  @Test func aNameMatchesCaseInsensitively() throws {
    let setup = try simulatedResolver().resolve(
      SetupSelectors(
        output: "SCARLETT 16I16 4TH GEN", input: "scarlett 16i16 4th gen", inChannel: "7"))
    #expect(setup.output.uid == SimulatedCatalog.scarlettUID)
  }

  @Test func aUniqueSubstringResolves() throws {
    let setup = try simulatedResolver().resolve(
      SetupSelectors(output: "scarlett", input: "scarlett", inChannel: "7"))
    #expect(setup.input.uid == SimulatedCatalog.scarlettUID)
    #expect(setup.inChannelName == "Loop 1")
  }

  @Test func anAmbiguousSubstringListsBothCandidatesWithUIDs() throws {
    let error = failure {
      _ = try simulatedResolver().resolve(
        SetupSelectors(output: "MacBook Pro", input: "scarlett", inChannel: "1"))
    }
    #expect(error?.code == "ambiguousDevice")
    #expect(error?.kind == .usage)
    let candidates = error?.context["candidates"] ?? ""
    #expect(candidates.contains("MacBook Pro Microphone (\(SimulatedCatalog.macMicrophoneUID))"))
    #expect(candidates.contains("MacBook Pro Speakers (\(SimulatedCatalog.macSpeakersUID))"))
  }

  @Test func anExactNameBeatsADeviceThatMerelyContainsIt() throws {
    let resolver = hardwareResolver(devices: [
      device(
        "uid-plain", "Scarlett 16i16 4th Gen", inputs: ["Input 1"],
        outputs: ["Output 1", "Output 2"]),
      device(
        "uid-extra", "Scarlett 16i16 4th Gen Extra", inputs: ["Input 1"],
        outputs: ["Output 1", "Output 2"]),
    ])
    let setup = try resolver.resolve(
      SetupSelectors(
        output: "scarlett 16i16 4th gen", input: "Scarlett 16i16 4th Gen", inChannel: "1"))
    #expect(setup.output.uid == "uid-plain")
  }

  @Test func twoDevicesWithTheSameExactNameAreAmbiguous() throws {
    let resolver = hardwareResolver(devices: [
      device("uid-1", "Twin", inputs: ["Input 1"], outputs: ["Output 1", "Output 2"]),
      device("uid-2", "Twin", inputs: ["Input 1"], outputs: ["Output 1", "Output 2"]),
    ])
    let error = failure {
      _ = try resolver.resolve(SetupSelectors(output: "Twin", input: "Twin", inChannel: "1"))
    }
    #expect(error?.code == "ambiguousDevice")
    let candidates = error?.context["candidates"] ?? ""
    #expect(candidates.contains("uid-1") && candidates.contains("uid-2"))
  }

  @Test func anEmptySelectorIsNotFoundAndListsEveryCandidate() throws {
    let error = failure {
      _ = try simulatedResolver().resolve(
        SetupSelectors(output: "", input: "scarlett", inChannel: "1"))
    }
    #expect(error?.code == "deviceNotFound")
    let candidates = error?.context["candidates"] ?? ""
    for uid in [
      SimulatedCatalog.duplexUID, SimulatedCatalog.scarlettUID, SimulatedCatalog.macMicrophoneUID,
      SimulatedCatalog.macSpeakersUID,
    ] {
      #expect(candidates.contains(uid))
    }
  }

  @Test func anUnknownNameIsNotFoundAndListsCandidates() throws {
    let error = failure {
      _ = try simulatedResolver().resolve(
        SetupSelectors(output: "zoom", input: "scarlett", inChannel: "1"))
    }
    #expect(error?.code == "deviceNotFound")
    #expect((error?.context["candidates"] ?? "").contains(SimulatedCatalog.scarlettUID))
  }

  @Test func aRowNumberIsNeverASelector() throws {
    let error = failure {
      _ = try simulatedResolver().resolve(SetupSelectors(output: "2", input: "3", inChannel: "1"))
    }
    #expect(error?.code == "deviceNotFound")
  }

  @Test func aDeviceWithoutTheRightDirectionIsRefused() throws {
    let error = failure {
      _ = try simulatedResolver().resolve(
        SetupSelectors(output: "MacBook Pro Microphone", input: "scarlett", inChannel: "1"))
    }
    #expect(error?.code == "deviceHasNoChannels")
  }

  // MARK: Defaults (D-10)

  @Test func theDefaultKeywordResolvesAndWarns() throws {
    let resolver = hardwareResolver(
      defaults: DeviceDefaults(inputUID: "uid-mic", outputUID: "uid-speakers"))
    let setup = try resolver.resolve(
      SetupSelectors(output: "default", input: "default", inChannel: "1"))
    #expect(setup.output.uid == "uid-speakers")
    #expect(setup.input.uid == "uid-mic")
    #expect(setup.warnings.contains("default resolved to MacBook Pro Speakers (uid-speakers)"))
    #expect(setup.warnings.contains("default resolved to MacBook Pro Microphone (uid-mic)"))
  }

  @Test func theDefaultKeywordWithoutADefaultIsNotFound() throws {
    let error = failure {
      _ = try hardwareResolver().resolve(
        SetupSelectors(output: "default", input: "uid-mic", inChannel: "1"))
    }
    #expect(error?.code == "deviceNotFound")
  }

  @Test func hardwareWithoutSelectorsRequiresThem() throws {
    let noOutput = failure { _ = try hardwareResolver().resolve(SetupSelectors()) }
    #expect(noOutput?.code == "deviceSelectorRequired")
    let noInput = failure {
      _ = try hardwareResolver().resolve(SetupSelectors(output: "uid-speakers"))
    }
    #expect(noInput?.code == "deviceSelectorRequired")
  }

  @Test func theSimulatorWithoutSelectorsUsesTheDuplexDevice() throws {
    let setup = try simulatedResolver().resolve(SetupSelectors())
    #expect(setup.output.uid == SimulatedCatalog.duplexUID)
    #expect(setup.input.uid == SimulatedCatalog.duplexUID)
    #expect(setup.inChannel == 1)
    #expect(setup.outChannels == [1, 2])
  }

  // MARK: Channels (D-11)

  @Test func aHardwareRunWithoutAnInChannelNamesTheChoices() throws {
    let error = failure {
      _ = try hardwareResolver().resolve(
        SetupSelectors(output: "uid-speakers", input: "uid-scarlett"))
    }
    #expect(error?.code == "inChannelRequired")
    #expect(error?.detail.contains("Loop 1") == true)
  }

  @Test func outputChannelsDefaultToThePreferredStereoPair() throws {
    let setup = try hardwareResolver().resolve(
      SetupSelectors(output: "uid-scarlett", input: "uid-scarlett", inChannel: "2"))
    #expect(setup.outChannels == [3, 4])
    #expect(setup.outChannelNames == ["Output 3", "Output 4"])
    #expect(setup.inChannelName == "Loop 1")
  }

  @Test func explicitOutputChannelsOverrideThePreferredPair() throws {
    let setup = try hardwareResolver().resolve(
      SetupSelectors(
        output: "uid-scarlett", input: "uid-scarlett", inChannel: "1", outChannels: [1, 2]))
    #expect(setup.outChannels == [1, 2])
  }

  @Test func aChannelOutsideTheDeviceIsInvalid() throws {
    let inError = failure {
      _ = try hardwareResolver().resolve(
        SetupSelectors(output: "uid-scarlett", input: "uid-scarlett", inChannel: "99"))
    }
    #expect(inError?.code == "invalidChannel")
    let outError = failure {
      _ = try hardwareResolver().resolve(
        SetupSelectors(
          output: "uid-scarlett", input: "uid-scarlett", inChannel: "1", outChannels: [1, 9]))
    }
    #expect(outError?.code == "invalidChannel")
  }

  @Test func aChannelThatIsNotANumberIsInvalid() throws {
    let error = failure {
      _ = try hardwareResolver().resolve(
        SetupSelectors(output: "uid-scarlett", input: "uid-scarlett", inChannel: "loop"))
    }
    #expect(error?.code == "invalidChannel")
  }

  @Test func autoLeavesTheChannelUnresolvedAndFlagsItForTheProbe() throws {
    let resolved = try hardwareResolver().resolve(
      SetupSelectors(output: "uid-scarlett", input: "uid-scarlett", inChannel: "auto"))
    #expect(resolved.autoInChannel)
    #expect(resolved.inChannel == 0, "unresolved until the probe has heard the chirp")
    #expect(resolved.inChannelName == nil)
    #expect(resolved.input.uid == "uid-scarlett")

    let numbered = try hardwareResolver().resolve(
      SetupSelectors(output: "uid-scarlett", input: "uid-scarlett", inChannel: "1"))
    #expect(!numbered.autoInChannel)
    #expect(numbered.inChannel == 1)
  }

  @Test func autoBeatsAChannelStoredInASavedSetup() throws {
    let resolved = try hardwareResolver(
      midi: MIDIListing(destinations: [midiEndpoint(77, "Piano")]), setups: benchSetups()
    ).resolve(SetupSelectors(setup: "bench", inChannel: "auto"))
    #expect(resolved.autoInChannel)
    #expect(resolved.inChannel == 0)
  }

  // MARK: Named setups (D-09)

  private func benchSetups(
    outputUID: String = "uid-scarlett", outputName: String = "Scarlett 16i16 4th Gen"
  ) -> SetupsFile {
    SetupsFile(setups: [
      "bench": SetupBinding(
        output: .init(uid: outputUID, name: outputName),
        input: .init(uid: "uid-scarlett", name: "Scarlett 16i16 4th Gen"),
        inChannel: 2, outChannels: [1, 2], midiOut: MIDIRef(uniqueID: 77, name: "Piano"))
    ])
  }

  @Test func anUnknownSetupNameIsRefused() throws {
    let error = failure {
      _ = try hardwareResolver(setups: benchSetups()).resolve(SetupSelectors(setup: "nope"))
    }
    #expect(error?.code == "unknownSetup")
  }

  @Test func aSetupSuppliesEveryBinding() throws {
    let resolver = hardwareResolver(
      midi: MIDIListing(destinations: [midiEndpoint(77, "Piano")]), setups: benchSetups())
    let setup = try resolver.resolve(SetupSelectors(setup: "bench"))
    #expect(setup.setupName == "bench")
    #expect(setup.output.uid == "uid-scarlett")
    #expect(setup.input.uid == "uid-scarlett")
    #expect(setup.inChannel == 2)
    #expect(setup.outChannels == [1, 2])
    #expect(setup.midiOut == MIDIRef(uniqueID: 77, name: "Piano"))
    #expect(setup.warnings.isEmpty)
  }

  @Test func flagsOverrideSetupFieldsOneByOne() throws {
    let resolver = hardwareResolver(
      midi: MIDIListing(destinations: [midiEndpoint(77, "Piano")]), setups: benchSetups())
    let setup = try resolver.resolve(
      SetupSelectors(setup: "bench", output: "uid-speakers", inChannel: "1"))
    #expect(setup.output.uid == "uid-speakers")
    #expect(setup.inChannel == 1)
    #expect(setup.input.uid == "uid-scarlett")
    #expect(setup.midiOut?.uniqueID == 77)
  }

  @Test func aChangedUIDFallsBackToTheStoredNameWithAWarning() throws {
    let resolver = hardwareResolver(
      midi: MIDIListing(destinations: [midiEndpoint(77, "Piano")]),
      setups: benchSetups(outputUID: "uid-old", outputName: "Scarlett 16i16 4th Gen"))
    let setup = try resolver.resolve(SetupSelectors(setup: "bench"))
    #expect(setup.output.uid == "uid-scarlett")
    #expect(
      setup.warnings.contains {
        $0.hasPrefix(
          "device UID changed; matched by name; calibrations for the old UID may not apply")
      })
  }

  @Test func aSetupDeviceThatIsGoneIsNotFound() throws {
    let resolver = hardwareResolver(
      setups: benchSetups(outputUID: "uid-old", outputName: "Gone Interface"))
    let error = failure { _ = try resolver.resolve(SetupSelectors(setup: "bench")) }
    #expect(error?.code == "deviceNotFound")
  }

  // MARK: setups.json (D-07, T-01-17)

  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-setups-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("setups.json")
  }

  @Test func aMissingSetupsFileIsEmpty() throws {
    let file = try Setups.load(from: temporaryFile())
    #expect(file.setups.isEmpty)
    #expect(file.schemaVersion == 1)
  }

  @Test func savedSetupsRoundTripThroughLoad() throws {
    let url = temporaryFile()
    let resolved = ResolvedSetup(
      output: DeviceRef(uid: "uid-o", name: "Out"), input: DeviceRef(uid: "uid-i", name: "In"),
      outChannels: [3, 4], inChannel: 7, midiOut: MIDIRef(uniqueID: -823_739_469, name: "Sim"))
    try Setups.save(SetupsFile(setups: ["bench": SetupBinding(resolved: resolved)]), to: url)
    let loaded = try Setups.load(from: url)
    #expect(loaded.setups["bench"] == SetupBinding(resolved: resolved))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"schemaVersion\" : 1"))
    #expect(text.contains("\"uid-o\"") && text.contains("\"Out\""))
    #expect(text.contains("\"uid-i\"") && text.contains("\"In\""))
  }

  @Test func anotherSchemaVersionIsUnreadableAndNamesTheFile() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"schemaVersion": 2, "setups": {}}"#.utf8).write(to: url)
    let error = failure { _ = try Setups.load(from: url) }
    #expect(error?.code == "setupsUnreadable")
    #expect(error?.kind == .usage)
    #expect(error?.detail.contains(url.path) == true)
  }

  @Test func malformedJSONIsUnreadableAndNamesTheFile() throws {
    let url = temporaryFile()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: url)
    let error = failure { _ = try Setups.load(from: url) }
    #expect(error?.code == "setupsUnreadable")
    #expect(error?.detail.contains(url.path) == true)
  }

  // MARK: MIDI selectors (RESEARCH P7)

  private var midiListing: MIDIListing {
    MIDIListing(destinations: [
      midiEndpoint(-823_739_469, "SoundPing Sim MIDI"),
      midiEndpoint(55, "Piano Bus 1"),
      midiEndpoint(56, "Piano Bus 2"),
    ])
  }

  @Test func aNegativeMIDIUniqueIDResolves() throws {
    let setup = try hardwareResolver(midi: midiListing).resolve(
      SetupSelectors(
        output: "uid-speakers", input: "uid-mic", inChannel: "1", midiOut: "-823739469"))
    #expect(setup.midiOut == MIDIRef(uniqueID: -823_739_469, name: "SoundPing Sim MIDI"))
  }

  @Test func aMIDINameResolves() throws {
    let setup = try hardwareResolver(midi: midiListing).resolve(
      SetupSelectors(output: "uid-speakers", input: "uid-mic", inChannel: "1", midiOut: "sim midi"))
    #expect(setup.midiOut?.uniqueID == -823_739_469)
  }

  @Test func anUnknownMIDIEndpointIsNotFound() throws {
    let error = failure {
      _ = try hardwareResolver(midi: midiListing).resolve(
        SetupSelectors(output: "uid-speakers", input: "uid-mic", inChannel: "1", midiOut: "nothing")
      )
    }
    #expect(error?.code == "midiEndpointNotFound")
  }

  @Test func anAmbiguousMIDINameListsTheCandidates() throws {
    let error = failure {
      _ = try hardwareResolver(midi: midiListing).resolve(
        SetupSelectors(output: "uid-speakers", input: "uid-mic", inChannel: "1", midiOut: "piano"))
    }
    #expect(error?.code == "ambiguousMIDIEndpoint")
    let candidates = error?.context["candidates"] ?? ""
    #expect(candidates.contains("55") && candidates.contains("56"))
  }
}
