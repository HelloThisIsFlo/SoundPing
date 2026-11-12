/// Parameters of one run. The defaults are the recipe defaults (D-04) and satisfy the
/// arm-time spacing guard on purpose: 450 >= 350 + 30 ms chirp + 50 (RESEARCH P6).
public struct RunParameters: Codable, Sendable, Equatable {
  public var hits: Int
  public var warmup: Int
  public var spacingMinMs: Double
  public var spacingMaxMs: Double
  public var maxLatencyMs: Double
  public var seed: UInt64
  public var templateId: String
  /// nil = find the level with the preflight ramp (D-14); a value is confirmed with one probe.
  public var levelDbfs: Double?
  public var minValidFraction: Double

  public init(
    hits: Int = 100,
    warmup: Int = 5,
    spacingMinMs: Double = 450,
    spacingMaxMs: Double = 750,
    maxLatencyMs: Double = 350,
    seed: UInt64,
    templateId: String = "chirp-loopback",
    levelDbfs: Double? = nil,
    minValidFraction: Double = 0.5
  ) {
    self.hits = hits
    self.warmup = warmup
    self.spacingMinMs = spacingMinMs
    self.spacingMaxMs = spacingMaxMs
    self.maxLatencyMs = maxLatencyMs
    self.seed = seed
    self.templateId = templateId
    self.levelDbfs = levelDbfs
    self.minValidFraction = minValidFraction
  }

  /// `ceil(minValidFraction * hits)`: how many measured hits must give a number for the run to
  /// count (the valid-hit gate). The small offset keeps `0.3 * 10`, which floating point makes
  /// 3.0000000000000004, from demanding a fourth hit.
  public static func requiredValidHits(hits: Int, minValidFraction: Double) -> Int {
    Int((minValidFraction * Double(hits) - 1e-9).rounded(.up))
  }

  public var requiredValidHits: Int {
    Self.requiredValidHits(hits: hits, minValidFraction: minValidFraction)
  }
}

public struct DeviceRef: Codable, Sendable, Equatable {
  public var uid: String
  public var name: String
  public var transport: String?
  public var clockDomain: UInt32?

  public init(uid: String, name: String, transport: String? = nil, clockDomain: UInt32? = nil) {
    self.uid = uid
    self.name = name
    self.transport = transport
    self.clockDomain = clockDomain
  }
}

public struct MIDIRef: Codable, Sendable, Equatable {
  public var uniqueID: Int32
  public var name: String

  public init(uniqueID: Int32, name: String) {
    self.uniqueID = uniqueID
    self.name = name
  }
}

/// Everything the user pinned for a run (D-08..D-11). Channels are 1-based (D-11).
public struct ResolvedSetup: Codable, Sendable, Equatable {
  public var output: DeviceRef
  public var input: DeviceRef
  public var outChannels: [Int]
  public var inChannel: Int
  public var outChannelNames: [String]
  public var inChannelName: String?
  public var requestedBufferFrames: Int?
  public var setupName: String?
  public var midiOut: MIDIRef?
  public var warnings: [String]

  public init(
    output: DeviceRef,
    input: DeviceRef,
    outChannels: [Int],
    inChannel: Int,
    outChannelNames: [String] = [],
    inChannelName: String? = nil,
    requestedBufferFrames: Int? = nil,
    setupName: String? = nil,
    midiOut: MIDIRef? = nil,
    warnings: [String] = []
  ) {
    self.output = output
    self.input = input
    self.outChannels = outChannels
    self.inChannel = inChannel
    self.outChannelNames = outChannelNames
    self.inChannelName = inChannelName
    self.requestedBufferFrames = requestedBufferFrames
    self.setupName = setupName
    self.midiOut = midiOut
    self.warnings = warnings
  }
}

public struct RunRequest: Sendable {
  public var recipe: Recipe
  public var parameters: RunParameters
  public var setup: ResolvedSetup
  public var label: String?
  public var tags: [String]
  public var preflight: PreflightOptions

  public init(
    recipe: Recipe,
    parameters: RunParameters,
    setup: ResolvedSetup,
    label: String? = nil,
    tags: [String] = [],
    preflight: PreflightOptions = PreflightOptions()
  ) {
    self.recipe = recipe
    self.parameters = parameters
    self.setup = setup
    self.label = label
    self.tags = tags
    self.preflight = preflight
  }
}
