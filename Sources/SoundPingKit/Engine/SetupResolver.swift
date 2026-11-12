/// What the user asked for on the command line (D-08..D-11). Everything is optional; the
/// resolver decides what is missing.
public struct SetupSelectors: Sendable, Equatable {
  public var setup: String?
  public var output: String?
  public var input: String?
  /// A 1-based channel number, or `auto` (not available until the level/auto-channel plan).
  public var inChannel: String?
  public var outChannels: [Int]?
  public var midiOut: String?
  /// Carried for the caller, which writes the setup after a successful resolve.
  public var saveSetup: String?

  public init(
    setup: String? = nil, output: String? = nil, input: String? = nil, inChannel: String? = nil,
    outChannels: [Int]? = nil, midiOut: String? = nil, saveSetup: String? = nil
  ) {
    self.setup = setup
    self.output = output
    self.input = input
    self.inChannel = inChannel
    self.outChannels = outChannels
    self.midiOut = midiOut
    self.saveSetup = saveSetup
  }
}

/// The one place audio selectors, MIDI selectors and named setups become a `ResolvedSetup`.
/// Nothing falls back to a system default except through the explicit `default` keyword (D-10).
public struct SetupResolver: Sendable {
  public let listing: DevicesListing
  public let setups: SetupsFile?
  public let simulated: Bool

  public init(listing: DevicesListing, setups: SetupsFile?, simulated: Bool) {
    self.listing = listing
    self.setups = setups
    self.simulated = simulated
  }

  public func resolve(_ selectors: SetupSelectors) throws -> ResolvedSetup {
    throw SoundPingError.internalFailure("notImplemented", "SetupResolver.resolve")
  }
}
