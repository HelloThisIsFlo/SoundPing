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
        for device in listing.audio { print(device.name) }
      }
    }
  }
}
