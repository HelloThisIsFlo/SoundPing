/// One channel of a device scope. `index` is 1-based and is what `--in-channel` and
/// `--out-channels` take (D-11); `name` is what the HAL calls it ("Loop 1", "Input 3").
public struct ChannelInfo: Codable, Sendable, Equatable {
  public var index: Int
  public var name: String
  /// Position of the stream (buffer) that carries this channel, 0-based. Indexes `ScopeInfo.streamLatencies`.
  public var streamIndex: Int
  /// 1-based position inside that stream.
  public var channelInStream: Int

  public init(index: Int, name: String, streamIndex: Int, channelInStream: Int) {
    self.index = index
    self.name = name
    self.streamIndex = streamIndex
    self.channelInStream = channelInStream
  }
}

public struct FrameSizeRange: Codable, Sendable, Equatable {
  public var min: UInt32
  public var max: UInt32

  public init(min: UInt32, max: UInt32) {
    self.min = min
    self.max = max
  }
}

/// What a device reports for one direction. All latencies are in frames at the device's nominal rate.
public struct ScopeInfo: Codable, Sendable, Equatable {
  public var channels: [ChannelInfo]
  public var deviceLatency: UInt32
  /// One entry per stream, in the order of the device's buffer list. Always read: the built-in
  /// mic keeps ~1439 frames here and almost none in `deviceLatency` (RESEARCH P2).
  public var streamLatencies: [UInt32]
  public var safetyOffset: UInt32
  /// This process's I/O buffer size for the device (RESEARCH P1), not the buffer another app set.
  public var bufferFrameSize: UInt32
  public var bufferFrameSizeRange: FrameSizeRange
  /// Output only: the channel pair the HAL prefers for stereo, 1-based.
  public var preferredStereo: [Int]?
  /// Four-character code of the active data source, e.g. "hdpn" or "ispk".
  public var dataSource: String?
  public var mute: Bool?
  public var volumeScalar: Float?

  public init(
    channels: [ChannelInfo],
    deviceLatency: UInt32,
    streamLatencies: [UInt32],
    safetyOffset: UInt32,
    bufferFrameSize: UInt32,
    bufferFrameSizeRange: FrameSizeRange,
    preferredStereo: [Int]? = nil,
    dataSource: String? = nil,
    mute: Bool? = nil,
    volumeScalar: Float? = nil
  ) {
    self.channels = channels
    self.deviceLatency = deviceLatency
    self.streamLatencies = streamLatencies
    self.safetyOffset = safetyOffset
    self.bufferFrameSize = bufferFrameSize
    self.bufferFrameSizeRange = bufferFrameSizeRange
    self.preferredStereo = preferredStereo
    self.dataSource = dataSource
    self.mute = mute
    self.volumeScalar = volumeScalar
  }

  /// The latency of the stream that carries `channel`, 0 when the stream is unknown.
  public func streamLatency(forChannel channel: Int) -> UInt32 {
    guard let info = channels.first(where: { $0.index == channel }),
      streamLatencies.indices.contains(info.streamIndex)
    else { return 0 }
    return streamLatencies[info.streamIndex]
  }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
  public var uid: String
  public var name: String
  public var manufacturer: String?
  /// builtIn, usb, bluetooth, virtual, aggregate, thunderbolt, firewire, pci, hdmi, displayPort,
  /// airPlay, avb or other.
  public var transport: String
  public var clockDomain: UInt32?
  public var nominalSampleRate: Double
  public var isAlive: Bool
  public var input: ScopeInfo?
  public var output: ScopeInfo?

  public init(
    uid: String,
    name: String,
    manufacturer: String? = nil,
    transport: String,
    clockDomain: UInt32? = nil,
    nominalSampleRate: Double,
    isAlive: Bool = true,
    input: ScopeInfo? = nil,
    output: ScopeInfo? = nil
  ) {
    self.uid = uid
    self.name = name
    self.manufacturer = manufacturer
    self.transport = transport
    self.clockDomain = clockDomain
    self.nominalSampleRate = nominalSampleRate
    self.isAlive = isAlive
    self.input = input
    self.output = output
  }

  public var ref: DeviceRef {
    DeviceRef(uid: uid, name: name, transport: transport, clockDomain: clockDomain)
  }
}

public enum MIDIEndpointKind: String, Codable, Sendable {
  case source
  case destination
}

public struct MIDIEndpointInfo: Codable, Sendable, Equatable {
  /// `kMIDIPropertyUniqueID`: signed, so it may be negative.
  public var uniqueID: Int32
  public var name: String
  public var displayName: String
  public var manufacturer: String?
  public var model: String?
  public var isOffline: Bool
  public var kind: MIDIEndpointKind

  public init(
    uniqueID: Int32,
    name: String,
    displayName: String,
    manufacturer: String? = nil,
    model: String? = nil,
    isOffline: Bool = false,
    kind: MIDIEndpointKind
  ) {
    self.uniqueID = uniqueID
    self.name = name
    self.displayName = displayName
    self.manufacturer = manufacturer
    self.model = model
    self.isOffline = isOffline
    self.kind = kind
  }

  public var ref: MIDIRef { MIDIRef(uniqueID: uniqueID, name: name) }
}

public struct MIDIListing: Codable, Sendable, Equatable {
  public var sources: [MIDIEndpointInfo]
  public var destinations: [MIDIEndpointInfo]

  public init(sources: [MIDIEndpointInfo] = [], destinations: [MIDIEndpointInfo] = []) {
    self.sources = sources
    self.destinations = destinations
  }
}

public struct DeviceDefaults: Codable, Sendable, Equatable {
  public var inputUID: String?
  public var outputUID: String?

  public init(inputUID: String? = nil, outputUID: String? = nil) {
    self.inputUID = inputUID
    self.outputUID = outputUID
  }
}

/// Everything `soundping devices --json` prints.
public struct DevicesListing: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var audio: [DeviceInfo]
  public var midi: MIDIListing
  public var defaults: DeviceDefaults

  public init(
    audio: [DeviceInfo], midi: MIDIListing = MIDIListing(),
    defaults: DeviceDefaults = DeviceDefaults()
  ) {
    self.schemaVersion = 1
    self.audio = audio
    self.midi = midi
    self.defaults = defaults
  }

  /// Audio devices by name then UID, MIDI endpoints by name then unique ID, so repeated listings
  /// are byte-identical (ENG-01). Case is ignored first so "iPhone" does not sort after "Zoom".
  public func sorted() -> DevicesListing {
    var copy = self
    copy.audio.sort { lhs, rhs in
      Self.lessThan((lhs.name, lhs.uid), (rhs.name, rhs.uid))
    }
    copy.midi.sources = Self.sortedEndpoints(midi.sources)
    copy.midi.destinations = Self.sortedEndpoints(midi.destinations)
    return copy
  }

  private static func sortedEndpoints(_ endpoints: [MIDIEndpointInfo]) -> [MIDIEndpointInfo] {
    endpoints.sorted { lhs, rhs in
      let l = lhs.name.lowercased()
      let r = rhs.name.lowercased()
      if l != r { return l < r }
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.uniqueID < rhs.uniqueID
    }
  }

  private static func lessThan(_ lhs: (String, String), _ rhs: (String, String)) -> Bool {
    let l = lhs.0.lowercased()
    let r = rhs.0.lowercased()
    if l != r { return l < r }
    if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
    return lhs.1 < rhs.1
  }
}
