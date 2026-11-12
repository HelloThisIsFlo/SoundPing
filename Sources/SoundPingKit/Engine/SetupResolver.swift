import Foundation

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

  private enum Role {
    case input
    case output

    var flag: String { self == .input ? "--input" : "--output" }
    var word: String { self == .input ? "input" : "output" }
  }

  public func resolve(_ selectors: SetupSelectors) throws -> ResolvedSetup {
    var warnings: [String] = []
    let binding = try binding(named: selectors.setup)

    let (outputDevice, outputScope) = try pick(
      .output, selector: selectors.output, stored: binding?.output, setup: selectors.setup,
      warnings: &warnings)
    let (inputDevice, inputScope) = try pick(
      .input, selector: selectors.input, stored: binding?.input, setup: selectors.setup,
      warnings: &warnings)

    let inChannel = try pickInChannel(
      selectors.inChannel, stored: binding?.inChannel, scope: inputScope, device: inputDevice)
    let outChannels = try pickOutChannels(
      selectors.outChannels ?? binding?.outChannels, scope: outputScope, device: outputDevice)

    let midiOut: MIDIRef?
    if let selector = selectors.midiOut {
      midiOut = try resolveMIDI(selector)
    } else if let stored = binding?.midiOut {
      midiOut = try resolveStoredMIDI(stored, setup: selectors.setup, warnings: &warnings)
    } else {
      midiOut = nil
    }

    return ResolvedSetup(
      output: outputDevice.ref,
      input: inputDevice.ref,
      outChannels: outChannels,
      inChannel: inChannel,
      outChannelNames: outChannels.compactMap { name(of: $0, in: outputScope) },
      inChannelName: name(of: inChannel, in: inputScope),
      requestedBufferFrames: nil,
      setupName: selectors.setup,
      midiOut: midiOut,
      warnings: warnings)
  }

  // MARK: Setups

  private func binding(named name: String?) throws -> SetupBinding? {
    guard let name else { return nil }
    if let binding = setups?.setups[name] { return binding }
    let known = (setups?.setups.keys.sorted() ?? []).joined(separator: ", ")
    throw SoundPingError.usage(
      "unknownSetup",
      "no saved setup named '\(name)'; saved setups: \(known.isEmpty ? "none" : known)",
      context: ["setup": name, "available": known])
  }

  // MARK: Audio devices

  private func pick(
    _ role: Role, selector: String?, stored: SetupBinding.StoredDevice?, setup: String?,
    warnings: inout [String]
  ) throws -> (DeviceInfo, ScopeInfo) {
    let device: DeviceInfo
    if let selector {
      device = try resolveSelector(selector, role: role, warnings: &warnings)
    } else if let stored {
      device = try resolveStored(stored, role: role, setup: setup, warnings: &warnings)
    } else if simulated,
      let duplex = listing.audio.first(where: { $0.uid == SimulatedCatalog.duplexUID })
    {
      device = duplex
    } else {
      throw SoundPingError.usage(
        "deviceSelectorRequired",
        "\(role.flag) is required: pick a device by UID or name (`soundping devices` lists them). SoundPing never falls back to the system default; pass `\(role.flag) default` to use it on purpose. Candidates: \(candidateList(listing.audio))",
        context: ["flag": role.flag, "candidates": candidateList(listing.audio)])
    }

    guard let scope = role == .input ? device.input : device.output else {
      throw SoundPingError.usage(
        "deviceHasNoChannels",
        "\(device.name) (\(device.uid)) has no \(role.word) channels, so it cannot be used for \(role.flag)",
        context: ["device": device.uid, "flag": role.flag])
    }
    return (device, scope)
  }

  /// Exact UID, then the `default` keyword, then a unique case-insensitive exact name, then a
  /// unique case-insensitive substring (D-08, D-10).
  private func resolveSelector(
    _ selector: String, role: Role, warnings: inout [String]
  ) throws -> DeviceInfo {
    let trimmed = selector.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      throw notFound("the \(role.word) selector is empty", selector: selector)
    }

    if let byUID = listing.audio.first(where: { $0.uid == trimmed }) { return byUID }

    if trimmed.lowercased() == "default" {
      let uid = role == .input ? listing.defaults.inputUID : listing.defaults.outputUID
      guard let uid, let device = listing.audio.first(where: { $0.uid == uid }) else {
        throw notFound("this machine reports no default \(role.word) device", selector: selector)
      }
      warnings.append("default resolved to \(device.name) (\(device.uid))")
      return device
    }

    let lowered = trimmed.lowercased()
    let exact = listing.audio.filter { $0.name.lowercased() == lowered }
    if exact.count == 1 { return exact[0] }
    if exact.count > 1 { throw ambiguous(selector, exact) }

    let partial = listing.audio.filter { $0.name.lowercased().contains(lowered) }
    if partial.count == 1 { return partial[0] }
    if partial.count > 1 { throw ambiguous(selector, partial) }

    throw notFound("no device matches '\(selector)'", selector: selector)
  }

  /// A saved binding: the UID if it is still there, else the exact stored name, loudly (D-09).
  private func resolveStored(
    _ stored: SetupBinding.StoredDevice, role: Role, setup: String?, warnings: inout [String]
  ) throws -> DeviceInfo {
    if let byUID = listing.audio.first(where: { $0.uid == stored.uid }) { return byUID }

    let lowered = stored.name.lowercased()
    let byName = listing.audio.filter { $0.name.lowercased() == lowered }
    if byName.count > 1 { throw ambiguous(stored.name, byName) }
    guard let match = byName.first else {
      throw notFound(
        "setup '\(setup ?? "?")' expects \(role.word) device '\(stored.name)' (\(stored.uid)), which is not connected",
        selector: stored.name)
    }
    warnings.append(
      "device UID changed; matched by name; calibrations for the old UID may not apply (\(role.word) '\(stored.name)': \(stored.uid) -> \(match.uid))"
    )
    return match
  }

  private func candidateList(_ devices: [DeviceInfo]) -> String {
    devices.map { "\($0.name) (\($0.uid))" }.joined(separator: "; ")
  }

  private func notFound(_ reason: String, selector: String) -> SoundPingError {
    let candidates = candidateList(listing.audio)
    return SoundPingError.usage(
      "deviceNotFound",
      "\(reason). Select by UID or name; candidates: \(candidates.isEmpty ? "none" : candidates)",
      context: ["selector": selector, "candidates": candidates])
  }

  private func ambiguous(_ selector: String, _ matches: [DeviceInfo]) -> SoundPingError {
    let candidates = candidateList(matches)
    return SoundPingError.usage(
      "ambiguousDevice",
      "'\(selector)' matches more than one device; select by UID instead: \(candidates)",
      context: ["selector": selector, "candidates": candidates])
  }

  // MARK: Channels (D-11)

  private func name(of channel: Int, in scope: ScopeInfo) -> String? {
    scope.channels.first(where: { $0.index == channel })?.name
  }

  private func channelList(_ scope: ScopeInfo) -> String {
    scope.channels.map { "\($0.index) = \($0.name)" }.joined(separator: ", ")
  }

  private func pickInChannel(
    _ raw: String?, stored: Int?, scope: ScopeInfo, device: DeviceInfo
  ) throws -> Int {
    let channel: Int
    if let raw {
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      if trimmed.lowercased() == "auto" {
        throw SoundPingError.usage(
          "inChannelAutoUnavailable",
          "--in-channel auto is not available yet; pass a channel number: \(channelList(scope))",
          context: ["device": device.uid])
      }
      guard let number = Int(trimmed) else {
        throw SoundPingError.usage(
          "invalidChannel",
          "'\(raw)' is not a channel number; \(device.name) has input channels \(channelList(scope))",
          context: ["device": device.uid, "value": raw])
      }
      channel = number
    } else if let stored {
      channel = stored
    } else if simulated {
      channel = 1
    } else {
      throw SoundPingError.usage(
        "inChannelRequired",
        "--in-channel is required: SoundPing never guesses the input channel. \(device.name) has input channels \(channelList(scope))",
        context: ["device": device.uid, "channels": channelList(scope)])
    }

    guard scope.channels.contains(where: { $0.index == channel }) else {
      throw SoundPingError.usage(
        "invalidChannel",
        "input channel \(channel) does not exist on \(device.name); it has \(channelList(scope))",
        context: ["device": device.uid, "channel": String(channel)])
    }
    return channel
  }

  private func pickOutChannels(
    _ requested: [Int]?, scope: ScopeInfo, device: DeviceInfo
  ) throws -> [Int] {
    let channels: [Int]
    if let requested {
      channels = requested
    } else if let preferred = scope.preferredStereo, !preferred.isEmpty {
      channels = preferred
    } else {
      channels = Array(scope.channels.prefix(2).map(\.index))
    }

    let known = Set(scope.channels.map(\.index))
    guard !channels.isEmpty, Set(channels).count == channels.count,
      channels.allSatisfy(known.contains)
    else {
      throw SoundPingError.usage(
        "invalidChannel",
        "output channels \(channels) are not a distinct set of channels of \(device.name); it has \(channelList(scope))",
        context: [
          "device": device.uid, "channels": channels.map(String.init).joined(separator: ","),
        ])
    }
    return channels
  }

  // MARK: MIDI (RESEARCH P7)

  private func midiList(_ endpoints: [MIDIEndpointInfo]) -> String {
    endpoints.map { "\($0.name) (\($0.uniqueID))" }.joined(separator: "; ")
  }

  private func resolveMIDI(_ selector: String) throws -> MIDIRef {
    let destinations = listing.midi.destinations
    let trimmed = selector.trimmingCharacters(in: .whitespaces)

    if let id = Int32(trimmed), let match = destinations.first(where: { $0.uniqueID == id }) {
      return match.ref
    }

    let lowered = trimmed.lowercased()
    let exact = destinations.filter {
      $0.name.lowercased() == lowered || $0.displayName.lowercased() == lowered
    }
    if exact.count == 1 { return exact[0].ref }
    if exact.count > 1 { throw ambiguousMIDI(selector, exact) }

    if !lowered.isEmpty {
      let partial = destinations.filter {
        $0.name.lowercased().contains(lowered) || $0.displayName.lowercased().contains(lowered)
      }
      if partial.count == 1 { return partial[0].ref }
      if partial.count > 1 { throw ambiguousMIDI(selector, partial) }
    }

    let candidates = midiList(destinations)
    throw SoundPingError.usage(
      "midiEndpointNotFound",
      "no MIDI destination matches '\(selector)'; select by unique ID or name; candidates: \(candidates.isEmpty ? "none" : candidates)",
      context: ["selector": selector, "candidates": candidates])
  }

  private func ambiguousMIDI(_ selector: String, _ matches: [MIDIEndpointInfo]) -> SoundPingError {
    let candidates = midiList(matches)
    return SoundPingError.usage(
      "ambiguousMIDIEndpoint",
      "'\(selector)' matches more than one MIDI destination; select by unique ID instead: \(candidates)",
      context: ["selector": selector, "candidates": candidates])
  }

  private func resolveStoredMIDI(
    _ stored: MIDIRef, setup: String?, warnings: inout [String]
  ) throws -> MIDIRef {
    let destinations = listing.midi.destinations
    if let byID = destinations.first(where: { $0.uniqueID == stored.uniqueID }) { return byID.ref }

    let lowered = stored.name.lowercased()
    let byName = destinations.filter { $0.name.lowercased() == lowered }
    if byName.count > 1 { throw ambiguousMIDI(stored.name, byName) }
    guard let match = byName.first else {
      let candidates = midiList(destinations)
      throw SoundPingError.usage(
        "midiEndpointNotFound",
        "setup '\(setup ?? "?")' expects MIDI destination '\(stored.name)' (\(stored.uniqueID)), which is not present; candidates: \(candidates.isEmpty ? "none" : candidates)",
        context: ["selector": stored.name, "candidates": candidates])
    }
    warnings.append(
      "MIDI unique ID changed; matched by name (\(stored.name): \(stored.uniqueID) -> \(match.uniqueID))"
    )
    return match.ref
  }
}
