import Foundation
import SoundPingKit

/// `--json`: the final result as one JSON object on stdout, exactly the bytes run.json holds.
enum JSONRenderer {
  static func write(_ result: RunResult) throws {
    Output.writeData(try RunStore.encodedBytes(for: result))
  }
}
