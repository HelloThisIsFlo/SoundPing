import CoreAudio
import Foundation

/// Where the list of audio and MIDI devices comes from: the real machine or the simulator
/// (ENG-05). The resolver and the `devices` command work against this, never against CoreAudio.
public protocol DeviceCatalog: Sendable {
  func listing() throws -> DevicesListing
}

/// Reads the HAL. The only reader of HAL properties in the engine, and read only: it never
/// sets a device property (T-01-19). MIDI endpoints come from `MIDIEndpoints`.
public struct HALDeviceCatalog: DeviceCatalog {
  public init() {}

  public func listing() throws -> DevicesListing {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let ids = HALProperty.array(
      system, kAudioHardwarePropertyDevices, of: AudioDeviceID.self, initial: AudioDeviceID(0))
    let audio = ids.compactMap(Self.deviceInfo(for:))

    let defaults = DeviceDefaults(
      inputUID: Self.defaultDeviceUID(selector: kAudioHardwarePropertyDefaultInputDevice),
      outputUID: Self.defaultDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice))

    return DevicesListing(audio: audio, midi: try MIDIEndpoints.listing(), defaults: defaults)
      .sorted()
  }

  private static func defaultDeviceUID(selector: AudioObjectPropertySelector) -> String? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard
      let id = HALProperty.get(system, selector, initial: AudioDeviceID(kAudioObjectUnknown)),
      id != AudioDeviceID(kAudioObjectUnknown)
    else { return nil }
    return HALProperty.string(id, kAudioDevicePropertyDeviceUID)
  }

  private static func deviceInfo(for id: AudioDeviceID) -> DeviceInfo? {
    guard let uid = HALProperty.string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else {
      return nil
    }
    let name = HALProperty.string(id, kAudioObjectPropertyName) ?? uid
    let transport = HALProperty.get(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
    let alive = HALProperty.get(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(1))
    return DeviceInfo(
      uid: uid,
      name: name,
      manufacturer: HALProperty.string(id, kAudioObjectPropertyManufacturer),
      transport: transport.map(transportName(for:)) ?? "other",
      clockDomain: HALProperty.get(id, kAudioDevicePropertyClockDomain, initial: UInt32(0)),
      nominalSampleRate: HALProperty.get(
        id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0,
      isAlive: (alive ?? 1) != 0,
      input: scopeInfo(id, scope: kAudioObjectPropertyScopeInput),
      output: scopeInfo(id, scope: kAudioObjectPropertyScopeOutput))
  }

  /// nil when the device has no channels in that direction.
  private static func scopeInfo(
    _ id: AudioDeviceID, scope: AudioObjectPropertyScope
  ) -> ScopeInfo? {
    // Never assume one stream: channels are numbered across the whole buffer list.
    let counts = HALProperty.streamChannelCounts(id, scope: scope)
    guard counts.reduce(0, +) > 0 else { return nil }

    var channels: [ChannelInfo] = []
    var index = 1
    for (streamIndex, count) in counts.enumerated() {
      for within in 0..<count {
        // Some drivers (Loopback) return an empty name; a channel always needs a label.
        let halName = HALProperty.string(
          id, kAudioObjectPropertyElementName, scope: scope,
          element: AudioObjectPropertyElement(index))
        let name = (halName?.isEmpty ?? true) ? "Channel \(index)" : halName!
        channels.append(
          ChannelInfo(
            index: index, name: name, streamIndex: streamIndex, channelInStream: within + 1))
        index += 1
      }
    }

    // Stream latency is part of the reported path and hides the big numbers (RESEARCH P2).
    let streams = HALProperty.array(
      id, kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self,
      initial: AudioStreamID(0))
    var streamLatencies = [UInt32](repeating: 0, count: counts.count)
    for (position, stream) in streams.prefix(counts.count).enumerated() {
      streamLatencies[position] =
        HALProperty.get(stream, kAudioStreamPropertyLatency, initial: UInt32(0)) ?? 0
    }

    let bufferSize =
      HALProperty.get(id, kAudioDevicePropertyBufferFrameSize, scope: scope, initial: UInt32(0))
      ?? HALProperty.get(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) ?? 0
    let range =
      HALProperty.get(
        id, kAudioDevicePropertyBufferFrameSizeRange, scope: scope,
        initial: AudioValueRange(mMinimum: 0, mMaximum: 0))
      ?? HALProperty.get(
        id, kAudioDevicePropertyBufferFrameSizeRange,
        initial: AudioValueRange(mMinimum: 0, mMaximum: 0))
      ?? AudioValueRange(mMinimum: 0, mMaximum: 0)

    var preferred: [Int]?
    if scope == kAudioObjectPropertyScopeOutput {
      let pair = HALProperty.array(
        id, kAudioDevicePropertyPreferredChannelsForStereo, scope: scope, of: UInt32.self,
        initial: 0)
      if pair.count == 2, pair.allSatisfy({ $0 > 0 }) { preferred = pair.map(Int.init) }
    }

    let dataSource = HALProperty.get(
      id, kAudioDevicePropertyDataSource, scope: scope, initial: UInt32(0))
    let mute = HALProperty.get(id, kAudioDevicePropertyMute, scope: scope, initial: UInt32(0))
    let volume =
      HALProperty.get(id, kAudioDevicePropertyVolumeScalar, scope: scope, initial: Float32(0))
      ?? HALProperty.get(
        id, kAudioDevicePropertyVolumeScalar, scope: scope, element: 1, initial: Float32(0))

    return ScopeInfo(
      channels: channels,
      deviceLatency: HALProperty.get(
        id, kAudioDevicePropertyLatency, scope: scope, initial: UInt32(0)) ?? 0,
      streamLatencies: streamLatencies,
      safetyOffset: HALProperty.get(
        id, kAudioDevicePropertySafetyOffset, scope: scope, initial: UInt32(0)) ?? 0,
      bufferFrameSize: bufferSize,
      bufferFrameSizeRange: FrameSizeRange(
        min: UInt32(max(0, range.mMinimum)), max: UInt32(max(0, range.mMaximum))),
      preferredStereo: preferred,
      dataSource: dataSource.flatMap(HALProperty.fourCharCode),
      mute: mute.map { $0 != 0 },
      volumeScalar: volume)
  }

  private static func transportName(for value: UInt32) -> String {
    switch value {
    case kAudioDeviceTransportTypeBuiltIn: return "builtIn"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      return "bluetooth"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
      return "aggregate"
    case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
    case kAudioDeviceTransportTypeFireWire: return "firewire"
    case kAudioDeviceTransportTypePCI: return "pci"
    case kAudioDeviceTransportTypeHDMI: return "hdmi"
    case kAudioDeviceTransportTypeDisplayPort: return "displayPort"
    case kAudioDeviceTransportTypeAirPlay: return "airPlay"
    case kAudioDeviceTransportTypeAVB: return "avb"
    default: return "other"
    }
  }
}
