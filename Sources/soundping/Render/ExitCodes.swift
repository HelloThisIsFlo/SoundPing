import ArgumentParser
import SoundPingKit

/// One exit code per failure class (D-03). An agent branches on these, never on prose.
/// The numbers follow sysexits where one fits and are now part of the CLI contract.
enum ExitCodes {
  /// Bad flags, an unknown recipe, a bad store path.
  static let usage: Int32 = 64
  /// A check before the run failed: microphone permission, silence, clipping.
  static let preflight: Int32 = 65
  /// The device changed under the run: it vanished or changed rate or buffer size.
  static let deviceChanged: Int32 = 75
  /// The run finished and saved, but did not pass a quality gate (too few valid hits).
  static let gate: Int32 = 3
  /// Another run holds the store.
  static let busy: Int32 = 73
  /// A bug, or an error nothing else describes.
  static let internalError: Int32 = 70

  static func code(for kind: SoundPingError.Kind) -> Int32 {
    0
  }

  static func exitCode(for kind: SoundPingError.Kind) -> ExitCode {
    ExitCode(code(for: kind))
  }
}
