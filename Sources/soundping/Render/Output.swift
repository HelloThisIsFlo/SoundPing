import Foundation

/// The only two ways the CLI talks to the terminal (D-03).
///
/// Stdout is for data: whole lines, written and flushed one at a time, so a reader on a pipe sees
/// each line the moment it exists. Stderr is for progress, logs and error messages.
enum Output {
  /// One whole line on stdout, written straight to the file descriptor (no stdio buffering).
  static func writeLine(_ line: String) {
    write(Data((line + "\n").utf8), to: FileHandle.standardOutput)
  }

  /// Raw bytes on stdout, for output that already carries its own newline.
  static func writeData(_ data: Data) {
    write(data, to: FileHandle.standardOutput)
  }

  /// One line on stderr.
  static func logLine(_ line: String) {
    write(Data((line + "\n").utf8), to: FileHandle.standardError)
  }

  /// Per-hit progress in the data modes. Only shown to a person, never to a pipe.
  static func progressLine(_ line: String) {
    guard isatty(STDERR_FILENO) != 0 else { return }
    logLine(line)
  }

  private static func write(_ data: Data, to handle: FileHandle) {
    // A reader that went away (`| head`) must not crash the tool with an exception.
    try? handle.write(contentsOf: data)
  }
}
