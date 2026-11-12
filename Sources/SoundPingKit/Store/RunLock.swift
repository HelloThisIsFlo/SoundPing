import Darwin
import Foundation

/// Only one run touches the store and the devices at a time (T-01-06, RESEARCH Pattern 9).
/// An exclusive, non-blocking `flock` on `<root>/.run.lock`, released when this object goes away
/// (or the process exits, however it exits).
public final class RunLock: @unchecked Sendable {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }

  /// Takes the lock or throws `busy` / `runInProgress`.
  public static func acquire(at url: URL) throws -> RunLock {
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else {
      throw SoundPingError.internalFailure(
        "runLockUnavailable",
        "cannot open the run lock '\(url.path)': \(String(cString: strerror(errno)))",
        context: ["path": url.path])
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let reason = errno
      close(descriptor)
      if reason == EWOULDBLOCK {
        throw SoundPingError(
          kind: .busy, code: "runInProgress",
          detail: "another soundping run holds '\(url.path)'; wait for it to finish",
          context: ["path": url.path])
      }
      throw SoundPingError.internalFailure(
        "runLockUnavailable",
        "cannot lock '\(url.path)': \(String(cString: strerror(reason)))",
        context: ["path": url.path])
    }
    return RunLock(descriptor: descriptor)
  }
}
