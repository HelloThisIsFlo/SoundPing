/// The device list `--simulate` uses: no CoreAudio, no CoreMIDI, so CI runners with no audio
/// hardware still exercise selection. Latency figures are the real ones read from Flo's machine
/// at 48 kHz (RESEARCH Pattern 3), kept as fixtures so the reported-latency math has known answers.
public struct SimulatedCatalog: DeviceCatalog {
  public static let duplexUID = "soundping-sim-duplex"
  public static let scarlettUID = "soundping-sim-scarlett-16i16"
  public static let macMicrophoneUID = "soundping-sim-macbook-pro-microphone"
  public static let macSpeakersUID = "soundping-sim-macbook-pro-speakers"
  public static let midiUniqueID: Int32 = -823_739_469

  public init() {}

  public func listing() throws -> DevicesListing {
    DevicesListing(
      audio: [Self.duplex, Self.scarlett, Self.macMicrophone, Self.macSpeakers],
      midi: MIDIListing(
        sources: [],
        destinations: [
          MIDIEndpointInfo(
            uniqueID: Self.midiUniqueID,
            name: "SoundPing Sim MIDI",
            displayName: "SoundPing Sim MIDI",
            manufacturer: "SoundPing",
            model: "Simulated",
            kind: .destination)
        ]),
      defaults: DeviceDefaults(inputUID: Self.duplexUID, outputUID: Self.duplexUID)
    ).sorted()
  }

  private static func channels(_ names: [String]) -> [ChannelInfo] {
    names.enumerated().map {
      ChannelInfo(
        index: $0.offset + 1, name: $0.element, streamIndex: 0, channelInStream: $0.offset + 1)
    }
  }

  private static func scope(
    names: [String], deviceLatency: UInt32, streamLatency: UInt32, safety: UInt32,
    buffer: UInt32 = 128, preferredStereo: [Int]? = nil, dataSource: String? = nil
  ) -> ScopeInfo {
    ScopeInfo(
      channels: channels(names),
      deviceLatency: deviceLatency,
      streamLatencies: [streamLatency],
      safetyOffset: safety,
      bufferFrameSize: buffer,
      bufferFrameSizeRange: FrameSizeRange(min: 15, max: 4096),
      preferredStereo: preferredStereo,
      dataSource: dataSource)
  }

  static let duplex = DeviceInfo(
    uid: duplexUID,
    name: "SoundPing Simulated Duplex",
    manufacturer: "SoundPing",
    transport: "virtual",
    clockDomain: 0,
    nominalSampleRate: 48_000,
    input: scope(names: ["Input 1"], deviceLatency: 0, streamLatency: 0, safety: 0),
    output: scope(
      names: ["Output 1", "Output 2"], deviceLatency: 0, streamLatency: 0, safety: 0,
      preferredStereo: [1, 2]))

  static let scarlett = DeviceInfo(
    uid: scarlettUID,
    name: "Scarlett 16i16 4th Gen",
    manufacturer: "Focusrite",
    transport: "usb",
    clockDomain: 0,
    nominalSampleRate: 48_000,
    input: scope(
      names: [
        "Input 1", "Input 2", "Input 3", "Input 4", "Input 5", "Input 6", "Loop 1", "Loop 2",
        "S/PDIF 1", "S/PDIF 2",
      ], deviceLatency: 25, streamLatency: 0, safety: 14),
    output: scope(
      names: ["Output 1", "Output 2", "Output 3", "Output 4", "Output 5", "Output 6"],
      deviceLatency: 32, streamLatency: 0, safety: 14, preferredStereo: [1, 2]))

  static let macMicrophone = DeviceInfo(
    uid: macMicrophoneUID,
    name: "MacBook Pro Microphone",
    manufacturer: "Apple Inc.",
    transport: "builtIn",
    clockDomain: 1_835_100_526,
    nominalSampleRate: 48_000,
    input: scope(
      names: ["Input 1"], deviceLatency: 14, streamLatency: 1439, safety: 36, buffer: 512,
      dataSource: "imic"))

  static let macSpeakers = DeviceInfo(
    uid: macSpeakersUID,
    name: "MacBook Pro Speakers",
    manufacturer: "Apple Inc.",
    transport: "builtIn",
    clockDomain: 1_835_100_526,
    nominalSampleRate: 48_000,
    output: scope(
      names: ["Output 1", "Output 2"], deviceLatency: 60, streamLatency: 690, safety: 48,
      buffer: 512, preferredStereo: [1, 2], dataSource: "ispk"))
}
