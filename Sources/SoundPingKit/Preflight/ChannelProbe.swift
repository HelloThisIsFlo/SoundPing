import Foundation

/// What `--in-channel auto` heard on one input channel.
public struct ChannelScore: Codable, Sendable, Equatable {
  public var index: Int
  public var name: String
  /// The best confidence any probe on this channel reached.
  public var confidence: Double
  /// The level of the probe that reached it.
  public var levelDbfs: Double

  public init(index: Int, name: String, confidence: Double, levelDbfs: Double) {
    self.index = index
    self.name = name
    self.confidence = confidence
    self.levelDbfs = levelDbfs
  }
}

/// The channel that heard the chirp, how sure SoundPing is, and by how much it beat the runner-up.
public struct ChannelChoice: Codable, Sendable, Equatable {
  public var index: Int
  public var name: String
  public var confidence: Double
  public var margin: Double

  public init(index: Int, name: String, confidence: Double, margin: Double) {
    self.index = index
    self.name = name
    self.confidence = confidence
    self.margin = margin
  }
}

/// The result of `soundping run … --in-channel auto`: a probe, never a measurement. `--json` prints
/// exactly this object.
public struct ChannelProbeResult: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var type: String
  /// Every input channel, best first.
  public var channels: [ChannelScore]
  public var chosen: ChannelChoice
  /// Whether the choice was written into a saved setup.
  public var saved: Bool
  /// How to keep the choice when it was not saved.
  public var saveHint: String?

  public init(
    channels: [ChannelScore], chosen: ChannelChoice, saved: Bool = false, saveHint: String? = nil
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.type = "channelProbe"
    self.channels = channels
    self.chosen = chosen
    self.saved = saved
    self.saveHint = saveHint
  }
}

/// Finds the input channel that hears the chirp (D-11). SCAFFOLD: behaviour follows.
public struct ChannelProbe: Sendable {
  /// The winner must beat the runner-up by this much confidence, or the answer is ambiguous.
  public static let minMargin = 0.2
  /// A channel that never reaches this heard nothing at all.
  public static let minConfidence = 0.5
  /// Probe levels climb in these steps from -48 dBFS up to the ceiling.
  public static let stepUpDb = 12.0

  public let resolver: any ResponsibleAppResolving

  public init(resolver: any ResponsibleAppResolving = ProcessTreeResolver()) {
    self.resolver = resolver
  }

  public func run(
    backend: any AudioBackend, setup: ResolvedSetup, channels: [ChannelInfo],
    options: PreflightOptions = PreflightOptions(), templateId: String = "chirp-loopback"
  ) async throws -> ChannelProbeResult {
    ChannelProbeResult(
      channels: [], chosen: ChannelChoice(index: 0, name: "", confidence: 0, margin: 0))
  }
}
