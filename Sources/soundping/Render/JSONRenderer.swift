import Foundation
import SoundPingKit

/// `--json`: the final result as one JSON object on stdout, exactly the bytes run.json holds.
enum JSONRenderer {
  static func write(_ result: RunResult) throws {
    FileHandle.standardOutput.write(try RunStore.encodedBytes(for: result))
  }
}
