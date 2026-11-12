import Foundation

/// What the terminal on the other end of stdout can take (D-03).
enum Terminal {
  /// Color only for a person at a terminal, and never when `NO_COLOR` is set to a non-empty
  /// value (https://no-color.org) or the terminal says it is `dumb`.
  static func useColor(environment: [String: String], stdoutIsTTY: Bool) -> Bool {
    guard stdoutIsTTY else { return false }
    if let noColor = environment["NO_COLOR"], !noColor.isEmpty { return false }
    return environment["TERM"] != "dumb"
  }

  static var stdoutIsTTY: Bool { isatty(STDOUT_FILENO) != 0 }

  static func useColor() -> Bool {
    useColor(environment: ProcessInfo.processInfo.environment, stdoutIsTTY: stdoutIsTTY)
  }
}
