import CoreMIDI
import Foundation

/// Lists CoreMIDI sources and destinations with their signed unique IDs (D-08, RESEARCH P7).
/// Read only; the only file in the engine that imports CoreMIDI at this stage.
enum MIDIEndpoints {
  static func listing() throws -> MIDIListing {
    var sources: [MIDIEndpointInfo] = []
    for position in 0..<MIDIGetNumberOfSources() {
      if let info = info(for: MIDIGetSource(position), kind: .source) { sources.append(info) }
    }
    var destinations: [MIDIEndpointInfo] = []
    for position in 0..<MIDIGetNumberOfDestinations() {
      if let info = info(for: MIDIGetDestination(position), kind: .destination) {
        destinations.append(info)
      }
    }
    return MIDIListing(sources: sources, destinations: destinations)
  }

  private static func info(for endpoint: MIDIEndpointRef, kind: MIDIEndpointKind)
    -> MIDIEndpointInfo?
  {
    guard endpoint != 0 else { return nil }
    var uniqueID: Int32 = 0
    guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID) == noErr else {
      return nil
    }
    let name = string(endpoint, kMIDIPropertyName) ?? ""
    var offline: Int32 = 0
    _ = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
    return MIDIEndpointInfo(
      uniqueID: uniqueID,
      name: name,
      displayName: string(endpoint, kMIDIPropertyDisplayName) ?? name,
      manufacturer: string(endpoint, kMIDIPropertyManufacturer),
      model: string(endpoint, kMIDIPropertyModel),
      isOffline: offline != 0,
      kind: kind)
  }

  private static func string(_ object: MIDIObjectRef, _ property: CFString) -> String? {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let value else {
      return nil
    }
    return value.takeRetainedValue() as String
  }
}
