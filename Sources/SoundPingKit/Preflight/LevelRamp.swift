import Foundation

/// The gentle auto-ramp (D-14, RESEARCH Pattern 5): start quiet, step up until the chirp is heard
/// clearly, lock that level for the whole run. SCAFFOLD: signatures only, behaviour follows.
public struct LevelRamp: Sendable {
  public static let firstProbeDbfs = -48.0
  public static let stepUpDb = 6.0
  public static let stepDownDb = 12.0
  public static let floorDbfs = -60.0
  public static let maxClippingRetries = 2
  public static let confidenceTarget = 0.9
  public static let peakTargetDbfs = -6.0
  public static let clippingDbfs = -1.0
  public static let minConfidence = 0.5

  public enum Failure: Sendable, Equatable { case clipping, nothingHeard }

  public enum Step: Sendable, Equatable {
    case probe(Double)
    case lock(Double, warning: String?)
    case fail(Failure)
  }

  public static func classify(setup: ResolvedSetup, output: DeviceInfo?, input: DeviceInfo?)
    -> ListenerKind
  {
    .unknown
  }

  public static func ceilingDbfs(for kind: ListenerKind) -> Double { 0 }

  public static func resolveCeiling(kind: ListenerKind, maxLevelDbfs: Double?) throws -> Double {
    0
  }

  public static func templateId(for kind: ListenerKind) -> String { "chirp-loopback" }

  public static func dbfs(ofAbsolutePeak peak: Float) -> Double { 0 }

  public init(ceilingDbfs: Double, fixedLevelDbfs: Double? = nil) {}

  public var firstLevel: Double { 0 }

  public mutating func record(level: Double, confidence: Double, peakDbfs: Double) -> Step {
    .fail(.nothingHeard)
  }
}
