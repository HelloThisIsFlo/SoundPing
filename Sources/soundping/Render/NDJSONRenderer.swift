import Foundation
import SoundPingKit

/// `--ndjson`: every `RunEvent` as one JSON object on its own line, the moment it happens.
/// The `finished` line carries the same `RunResult` that run.json holds.
struct NDJSONRenderer {
  private let encoder = RunJSON.lineEncoder()

  /// The event as one line, without the trailing newline.
  func line(for event: RunEvent) throws -> String {
    String(decoding: try encoder.encode(event), as: UTF8.self)
  }

  /// Writes the event to stdout as one flushed line.
  func write(_ event: RunEvent) throws {
    Output.writeLine(try line(for: event))
  }
}
