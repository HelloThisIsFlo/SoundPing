import CoreAudio
import Foundation

/// Typed readers for HAL properties. Read only: nothing in this plan ever calls
/// `AudioObjectSetPropertyData` (T-01-19). Every address uses `kAudioObjectPropertyElementMain`
/// unless a per-channel element is meant (RESEARCH L685).
enum HALProperty {
  static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }

  static func has(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> Bool {
    var addr = address(selector, scope: scope, element: element)
    return AudioObjectHasProperty(object, &addr)
  }

  /// A fixed-size value, or nil when the object lacks the property or the read fails.
  static func get<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
    initial: T
  ) -> T? {
    var addr = address(selector, scope: scope, element: element)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutableBytes(of: &value) { buffer in
      AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer.baseAddress!)
    }
    return status == noErr ? value : nil
  }

  /// A CFString property (name, UID, manufacturer). The HAL hands back a +1 reference.
  static func string(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> String? {
    var addr = address(selector, scope: scope, element: element)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }

  /// A variable-length array of fixed-size elements; empty when absent or unreadable.
  static func array<T>(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
    of _: T.Type,
    initial: T
  ) -> [T] {
    var addr = address(selector, scope: scope, element: element)
    guard AudioObjectHasProperty(object, &addr) else { return [] }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<T>.stride
    var values = [T](repeating: initial, count: count)
    var readSize = size
    let status = values.withUnsafeMutableBytes { buffer in
      AudioObjectGetPropertyData(object, &addr, 0, nil, &readSize, buffer.baseAddress!)
    }
    guard status == noErr else { return [] }
    return Array(values.prefix(Int(readSize) / MemoryLayout<T>.stride))
  }

  /// The channel count of each buffer (stream) of a scope, in buffer-list order.
  static func streamChannelCounts(
    _ object: AudioObjectID, scope: AudioObjectPropertyScope
  ) -> [Int] {
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
    guard AudioObjectHasProperty(object, &addr) else { return [] }
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    var readSize = size
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &readSize, raw) == noErr else {
      return []
    }
    let list = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.map { Int($0.mNumberChannels) }
  }

  /// A four-character code as text ("hdpn"), or nil when it is not printable ASCII.
  static func fourCharCode(_ value: UInt32) -> String? {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
    return String(decoding: bytes, as: UTF8.self)
  }
}
