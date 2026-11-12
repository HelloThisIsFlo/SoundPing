import Foundation

/// RED-phase stub: acquires nothing yet.
public final class RunLock: @unchecked Sendable {
  public static func acquire(at url: URL) throws -> RunLock { RunLock() }
}
