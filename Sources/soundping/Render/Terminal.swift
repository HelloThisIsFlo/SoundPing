import Foundation

/// What the terminal on the other end of stdout can take (D-03).
enum Terminal {
  /// Color only for a person at a terminal, and never when `NO_COLOR` is set to a non-empty
  /// value (https://no-color.org).
  static func useColor(environment: [String: String], stdoutIsTTY: Bool) -> Bool {
    false
  }

  static var stdoutIsTTY: Bool { isatty(STDOUT_FILENO) != 0 }

  static func useColor() -> Bool {
    useColor(environment: ProcessInfo.processInfo.environment, stdoutIsTTY: stdoutIsTTY)
  }
}
