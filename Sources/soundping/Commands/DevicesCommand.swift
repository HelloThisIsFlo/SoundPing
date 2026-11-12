import ArgumentParser
import Foundation
import SoundPingKit

/// Writes one value as pretty, key-sorted JSON plus a newline: the same encoder `run.json` uses.
func writeJSONLine<T: Encodable>(_ value: T) throws {
  var data = try RunJSON.fileEncoder().encode(value)
  data.append(0x0A)
  FileHandle.standardOutput.write(data)
}

/// `soundping devices` (ENG-01, D-08): every audio and MIDI device, by the IDs selectors accept.
struct DevicesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "devices",
    abstract: "List audio and MIDI devices with their stable IDs, channels and reported latencies."
  )

  @Flag(help: "Print the listing as one JSON object.")
  var json = false

  @Flag(help: "List the simulated devices instead of this machine's (no CoreAudio, no CoreMIDI).")
  var simulate = false

  @Option(
    help:
      "Accepted so one flag set works on every command; listing devices never touches the store."
  )
  var store: String?

  func run() async throws {
    try await withErrorReporting(jsonMode: json) {
      let catalog: any DeviceCatalog = simulate ? SimulatedCatalog() : HALDeviceCatalog()
      let listing = try catalog.listing()
      if json {
        try writeJSONLine(listing)
      } else {
        Self.writeTable(listing)
      }
    }
  }

  /// Row numbers are display-only (D-08): the header says so and the resolver rejects them.
  private static func writeTable(_ listing: DevicesListing) {
    print("Audio devices (select by UID or name; the # column is display-only and never accepted)")
    guard !listing.audio.isEmpty else {
      print("  none")
      writeMIDI(listing.midi)
      return
    }
    let nameWidth = max(4, listing.audio.map(\.name.count).max() ?? 0)
    let uidWidth = max(3, listing.audio.map(\.uid.count).max() ?? 0)
    print(
      "  #  " + "Name".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  "
        + "UID".padding(toLength: uidWidth, withPad: " ", startingAt: 0)
        + "  Transport     Rate  In Out")
    for (offset, device) in listing.audio.enumerated() {
      var marks: [String] = []
      if device.uid == listing.defaults.inputUID { marks.append("default input") }
      if device.uid == listing.defaults.outputUID { marks.append("default output") }
      let counts = String(
        format: " %3d %3d", device.input?.channels.count ?? 0, device.output?.channels.count ?? 0)
      let row =
        String(format: "%3d", offset + 1) + "  "
        + device.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  "
        + device.uid.padding(toLength: uidWidth, withPad: " ", startingAt: 0) + "  "
        + device.transport.padding(toLength: 10, withPad: " ", startingAt: 0)
        + String(format: " %6.0f", device.nominalSampleRate) + counts
        + (marks.isEmpty ? "" : "  [" + marks.joined(separator: ", ") + "]")
      print(row)
      writeScope("in ", device.input)
      writeScope("out", device.output)
    }
    writeMIDI(listing.midi)
  }

  private static func writeScope(_ label: String, _ scope: ScopeInfo?) {
    guard let scope else { return }
    let channels = scope.channels.map { "\($0.index) \($0.name)" }.joined(separator: ", ")
    print("       \(label): \(channels)")
    let stream = scope.streamLatencies.map(String.init).joined(separator: "+")
    print(
      "            latency device \(scope.deviceLatency) + stream \(stream) frames, safety \(scope.safetyOffset), buffer \(scope.bufferFrameSize)"
    )
  }

  private static func writeMIDI(_ midi: MIDIListing) {
    print("")
    print("MIDI sources (select by unique ID or name)")
    writeEndpoints(midi.sources)
    print("MIDI destinations (select by unique ID or name)")
    writeEndpoints(midi.destinations)
  }

  private static func writeEndpoints(_ endpoints: [MIDIEndpointInfo]) {
    guard !endpoints.isEmpty else {
      print("  none")
      return
    }
    for endpoint in endpoints {
      let offline = endpoint.isOffline ? "  [offline]" : ""
      print("  \(endpoint.uniqueID)  \(endpoint.displayName)\(offline)")
    }
  }
}
