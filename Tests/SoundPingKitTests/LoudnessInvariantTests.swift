import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import SoundPingKit

/// Forwards to the simulator and remembers the loudest test sound it was asked to play, so a test
/// can check what really reached the output, not what a function said the ceiling was.
private final class LoudestPlayedBackend: AudioBackend {
  private let inner: SimulatedBackend
  private let loudestGain = Mutex<Float>(0)
  let events: AsyncStream<DeviceEvent>

  init(scenario: Scenario) {
    inner = SimulatedBackend(scenario: scenario)
    events = inner.events
  }

  /// The loudest scheduled level in dBFS, or nil when nothing was played.
  var loudestDbfs: Double? {
    let gain = loudestGain.withLock { $0 }
    return gain > 0 ? 20 * log10(Double(gain)) : nil
  }

  func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws -> BackendInfo {
    try await inner.open(setup, templates: templates)
  }
  func start() async throws -> BackendInfo { try await inner.start() }
  func currentInputFrame() async -> Int64 { await inner.currentInputFrame() }
  func currentOutputFrame() async -> Int64 { await inner.currentOutputFrame() }
  func schedule(_ hits: [ScheduledHit]) async throws {
    let loudest = hits.map(\.gain).max() ?? 0
    loudestGain.withLock { $0 = Swift.max($0, loudest) }
    try await inner.schedule(hits)
  }
  func waitUntilCaptured(throughInputFrame frame: Int64) async throws {
    try await inner.waitUntilCaptured(throughInputFrame: frame)
  }
  func capture(_ range: Range<Int64>) async throws -> [Float] { try await inner.capture(range) }
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    await inner.stamps(covering: range)
  }
  func stampLog() async -> StampLog { await inner.stampLog() }
  func faults(overlappingInput input: Range<Int64>, output: Range<Int64>) async -> [FaultInterval] {
    await inner.faults(overlappingInput: input, output: output)
  }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }
  func stop() async { await inner.stop() }
}

/// The guard against the next hearing-safety regression (CR-02 → CR-03 → CR-04 → CR-05, WR-13).
/// Every one of those came from guessing which setups are a loop to allow them a louder ceiling.
/// This suite encodes the approved rule as it is written, with literal numbers, never read from
/// `LevelRamp`:
///
/// - The ceiling is chosen from the output only: known headphones -30 dBFS (any Bluetooth output,
///   or a built-in output that does not clearly report its speakers), built-in speakers (`ispk`)
///   -12, everything else -18, including every virtual output, every loop and every interface.
/// - There is no loop exception: no input, and no input/output combination, changes the ceiling.
/// - `--listener` can lower the ceiling (headphones -30, speaker -12, unknown -18; loopback lowers
///   nothing), never raise it.
/// - `--max-level` replaces the ceiling and is the only way to a louder probe. `--level` stays
///   clamped to the ceiling.
/// - The `--in-channel auto` probe follows the same rule but never goes above -18.
///
/// It walks every output kind × input kind × `--listener` × `--max-level` on the run and the probe
/// path, then checks what the simulator was really asked to play.
@Suite struct LoudnessInvariantTests {
  // MARK: The approved rule, written out

  /// The output kinds the rule names, each with how the HAL would report it. Each device's
  /// transport goes through `HALDeviceCatalog.transportName`, the mapping production reads the HAL
  /// with, so a change there (BLE mapped apart, `builtIn` renamed) fails here (IN-22). The expected
  /// ceilings stay literal.
  enum OutputKind: String, CaseIterable, CustomTestStringConvertible {
    case builtInSpeakers, builtInHeadphones, builtInNoDataSource, builtInOtherDataSource
    case builtInCatalogMiss, bluetooth, bluetoothLE, bluetoothCatalogMiss, usb, thunderbolt
    case aggregate, airPlay, unknownTransport, virtual, virtualCatalogMiss

    var testDescription: String { rawValue }

    /// The run ceiling the approved rule gives this output, without `--listener` or `--max-level`.
    var ruleCeiling: Double {
      switch self {
      // Known headphones: Bluetooth (classic or LE), or a built-in output that does not clearly
      // report `ispk` (WR-12 fail-safe: no data source, another one, or no device info at all).
      case .builtInHeadphones, .builtInNoDataSource, .builtInOtherDataSource, .builtInCatalogMiss,
        .bluetooth, .bluetoothLE, .bluetoothCatalogMiss:
        return -30
      case .builtInSpeakers:
        return -12
      // Everything else, every virtual output and every interface included.
      case .usb, .thunderbolt, .aggregate, .airPlay, .unknownTransport, .virtual,
        .virtualCatalogMiss:
        return -18
      }
    }

    /// The `--in-channel auto` probe: the same rule, never above -18.
    var probeRuleCeiling: Double { Swift.min(ruleCeiling, -18) }

    var isKnownHeadphones: Bool { ruleCeiling == -30 }

    /// The HAL transport type (`kAudioDevicePropertyTransportType`) of this output.
    var transportType: UInt32 {
      switch self {
      case .builtInSpeakers, .builtInHeadphones, .builtInNoDataSource, .builtInOtherDataSource,
        .builtInCatalogMiss:
        return kAudioDeviceTransportTypeBuiltIn
      case .bluetooth, .bluetoothCatalogMiss: return kAudioDeviceTransportTypeBluetooth
      case .bluetoothLE: return kAudioDeviceTransportTypeBluetoothLE
      case .usb: return kAudioDeviceTransportTypeUSB
      case .thunderbolt: return kAudioDeviceTransportTypeThunderbolt
      case .aggregate: return kAudioDeviceTransportTypeAggregate
      case .airPlay: return kAudioDeviceTransportTypeAirPlay
      case .unknownTransport: return kAudioDeviceTransportTypeUnknown
      case .virtual, .virtualCatalogMiss: return kAudioDeviceTransportTypeVirtual
      }
    }

    /// The transport string a listing (and so a saved setup) carries for this output.
    var transport: String { HALDeviceCatalog.transportName(for: transportType) }

    /// The device the HAL would report (nil for a catalog miss) and the reference the setup keeps.
    var device: (info: DeviceInfo?, ref: DeviceRef) {
      func with(_ base: DeviceInfo, uid: String? = nil, dataSource: String?? = nil) -> DeviceInfo {
        var device = base
        if let uid { device.uid = uid }
        device.transport = transport
        if let dataSource { device.output?.dataSource = dataSource }
        return device
      }
      let speakers = SimulatedCatalog.macSpeakers
      let scarlett = SimulatedCatalog.scarlett
      let info: DeviceInfo
      switch self {
      case .builtInSpeakers: info = with(speakers)
      case .builtInHeadphones: info = with(speakers, uid: "out-hdpn", dataSource: "hdpn")
      case .builtInNoDataSource: info = with(speakers, uid: "out-nil", dataSource: .some(nil))
      case .builtInOtherDataSource: info = with(speakers, uid: "out-hdmi", dataSource: "hdmi")
      case .bluetooth: info = with(speakers, uid: "out-bt", dataSource: "ispk")
      case .bluetoothLE: info = with(speakers, uid: "out-ble", dataSource: "ispk")
      case .usb: info = with(scarlett)
      case .thunderbolt: info = with(scarlett, uid: "out-tb")
      case .aggregate: info = with(scarlett, uid: "out-aggregate")
      case .airPlay: info = with(speakers, uid: "out-airplay", dataSource: .some(nil))
      case .unknownTransport: info = with(scarlett, uid: "out-unknown")
      case .virtual: info = with(SimulatedCatalog.duplex)
      case .builtInCatalogMiss:
        return (nil, DeviceRef(uid: "out-builtin-miss", name: "Built-in", transport: transport))
      case .bluetoothCatalogMiss:
        return (nil, DeviceRef(uid: "out-bt-miss", name: "AirPods", transport: transport))
      case .virtualCatalogMiss:
        return (nil, DeviceRef(uid: "out-virtual-miss", name: "Loopback", transport: transport))
      }
      return (info, info.ref)
    }
  }

  // MARK: Every transport the HAL can report

  /// Every transport type CoreAudio defines, with the run ceiling the rule gives it, written out.
  /// A built-in output is listed twice: on its speakers (`ispk`) and on any other data source.
  /// `RemoteScreen` and `RemoteStreaming` are spelled as their four-char codes so an older SDK
  /// still builds this.
  private static let everyTransport:
    [(name: String, type: UInt32, dataSource: String?, ceiling: Double)] = [
      ("builtIn on ispk", kAudioDeviceTransportTypeBuiltIn, "ispk", -12),
      ("builtIn on hdpn", kAudioDeviceTransportTypeBuiltIn, "hdpn", -30),
      ("builtIn, no data source", kAudioDeviceTransportTypeBuiltIn, nil, -30),
      ("bluetooth", kAudioDeviceTransportTypeBluetooth, "ispk", -30),
      ("bluetoothLE", kAudioDeviceTransportTypeBluetoothLE, "ispk", -30),
      ("unknown", kAudioDeviceTransportTypeUnknown, nil, -18),
      ("aggregate", kAudioDeviceTransportTypeAggregate, nil, -18),
      ("autoAggregate", kAudioDeviceTransportTypeAutoAggregate, nil, -18),
      ("virtual", kAudioDeviceTransportTypeVirtual, nil, -18),
      ("pci", kAudioDeviceTransportTypePCI, nil, -18),
      ("usb", kAudioDeviceTransportTypeUSB, nil, -18),
      ("fireWire", kAudioDeviceTransportTypeFireWire, nil, -18),
      ("hdmi", kAudioDeviceTransportTypeHDMI, nil, -18),
      ("displayPort", kAudioDeviceTransportTypeDisplayPort, nil, -18),
      ("airPlay", kAudioDeviceTransportTypeAirPlay, nil, -18),
      ("avb", kAudioDeviceTransportTypeAVB, nil, -18),
      ("thunderbolt", kAudioDeviceTransportTypeThunderbolt, nil, -18),
      ("continuityCaptureWired", kAudioDeviceTransportTypeContinuityCaptureWired, nil, -18),
      ("continuityCaptureWireless", kAudioDeviceTransportTypeContinuityCaptureWireless, nil, -18),
      ("remoteScreen", 0x7273_6372 /* 'rscr' */, nil, -18),
      ("remoteStreaming", 0x7273_7472 /* 'rstr' */, nil, -18),
    ]

  @Test func everyHALTransportGetsTheRuleCeilingThroughTheProductionMapping() throws {
    for entry in Self.everyTransport {
      var device = SimulatedCatalog.macSpeakers
      device.uid = "out-\(entry.name)"
      device.transport = HALDeviceCatalog.transportName(for: entry.type)
      device.output?.dataSource = entry.dataSource
      let setup = ResolvedSetup(
        output: device.ref, input: SimulatedCatalog.macMicrophone.ref, outChannels: [1, 2],
        inChannel: 1)
      let run = try LevelRamp.runLoudness(
        setup: setup, output: device, input: SimulatedCatalog.macMicrophone,
        options: PreflightOptions())
      #expect(run.ceilingDbfs == entry.ceiling, "\(entry.name) (\(device.transport))")
      // A catalog miss keeps only the recorded transport, which the same mapping produced.
      if entry.ceiling != -12 {
        let missed = try LevelRamp.runLoudness(
          setup: setup, output: nil, input: nil, options: PreflightOptions())
        #expect(missed.ceilingDbfs == entry.ceiling, "catalog miss: \(entry.name)")
      }
    }
  }

  @Test func theSimulatorReportsTransportsAsTheHALMappingDoes() {
    // The played-level tests below open the simulator, whose fixtures stand in for the HAL.
    #expect(
      SimulatedCatalog.macSpeakers.transport
        == HALDeviceCatalog.transportName(for: kAudioDeviceTransportTypeBuiltIn))
    #expect(
      SimulatedCatalog.macMicrophone.transport
        == HALDeviceCatalog.transportName(for: kAudioDeviceTransportTypeBuiltIn))
    #expect(
      SimulatedCatalog.scarlett.transport
        == HALDeviceCatalog.transportName(for: kAudioDeviceTransportTypeUSB))
    #expect(
      SimulatedCatalog.duplex.transport
        == HALDeviceCatalog.transportName(for: kAudioDeviceTransportTypeVirtual))
  }

  /// What naming a listener lowers the ceiling to. A loop has no ears, so it lowers nothing.
  private static func listenerLowersTo(_ kind: ListenerKind) -> Double? {
    switch kind {
    case .headphones: return -30
    case .speaker: return -12
    case .unknown: return -18
    case .loopback: return nil
    }
  }

  /// The rule: `--max-level` replaces the ceiling; otherwise `--listener` can only lower it.
  private static func expected(_ ceiling: Double, listener: ListenerKind?, maxLevel: Double?)
    -> Double
  {
    if let maxLevel { return maxLevel }
    guard let lowered = listener.flatMap(listenerLowersTo) else { return ceiling }
    return Swift.min(ceiling, lowered)
  }

  private static let headphoneCeiling = -30.0
  /// The loudest ceiling the rule ever gives without `--max-level` (the built-in speakers).
  private static let loudestRuleCeiling = -12.0

  enum InputKind: String, CaseIterable, CustomTestStringConvertible {
    /// The MacBook microphone, a separate device.
    case builtInMic
    /// A plain channel of a separate interface.
    case interface
    /// A plain channel of the output's own device (on a virtual output, a virtual duplex).
    case sameDevicePlainChannel
    /// A channel named "Loop 1" on the output's own device.
    case loopChannelSameDevice
    /// A channel named "Loop 1" on another device.
    case loopChannelOtherDevice
    /// A virtual device other than the output.
    case virtualOtherDevice
    /// A channel named "Loop 1" on a virtual device other than the output.
    case virtualLoopChannelOtherDevice

    var testDescription: String { rawValue }
  }

  // MARK: Building the combination

  private static func combination(_ output: OutputKind, _ input: InputKind) -> (
    setup: ResolvedSetup, output: DeviceInfo?, input: DeviceInfo?
  ) {
    let (outputInfo, outputRef) = output.device
    var inputInfo: DeviceInfo?
    var inputRef: DeviceRef
    var channelName = "Input 1"
    switch input {
    case .builtInMic:
      inputInfo = SimulatedCatalog.macMicrophone
      inputRef = SimulatedCatalog.macMicrophone.ref
    case .interface, .loopChannelOtherDevice:
      var device = SimulatedCatalog.scarlett
      device.uid = "in-interface"
      inputInfo = device
      inputRef = device.ref
      if input == .loopChannelOtherDevice { channelName = "Loop 1" }
    case .sameDevicePlainChannel, .loopChannelSameDevice:
      inputInfo = outputInfo
      inputRef = outputRef
      if input == .loopChannelSameDevice { channelName = "Loop 1" }
    case .virtualOtherDevice, .virtualLoopChannelOtherDevice:
      var device = SimulatedCatalog.duplex
      device.uid = "in-other-virtual"
      inputInfo = device
      inputRef = device.ref
      if input == .virtualLoopChannelOtherDevice { channelName = "Loop 1" }
    }
    let setup = ResolvedSetup(
      output: outputRef, input: inputRef, outChannels: [1, 2], inChannel: 1,
      inChannelName: channelName)
    return (setup, outputInfo, inputInfo)
  }

  private static let listeners: [ListenerKind?] = [nil] + ListenerKind.allCases.map { $0 }
  /// Absent, quieter than every ceiling, and louder than every ceiling.
  private static let maxLevels: [Double?] = [nil, -40, -3]

  // MARK: Every combination, both paths

  @Test func everyCombinationGetsTheOutputCeilingAndNothingButMaxLevelRaisesIt() throws {
    var checked = 0
    /// Run ceilings per output, flags and all, across every input: the input must never matter.
    var byOutput: [String: Set<Double>] = [:]
    for output in OutputKind.allCases {
      for input in InputKind.allCases {
        let (setup, outputInfo, inputInfo) = Self.combination(output, input)
        for listener in Self.listeners {
          for maxLevel in Self.maxLevels {
            let options = PreflightOptions(maxLevelDbfs: maxLevel, listener: listener)
            let flags =
              "--listener \(listener?.rawValue ?? "-"), --max-level \(maxLevel.map { String($0) } ?? "-")"
            let label = "\(output) + \(input), \(flags)"

            let run = try LevelRamp.runLoudness(
              setup: setup, output: outputInfo, input: inputInfo, options: options)
            let probe = try LevelRamp.probeLoudness(
              setup: setup, output: outputInfo, options: options)

            #expect(
              run.ceilingDbfs
                == Self.expected(output.ruleCeiling, listener: listener, maxLevel: maxLevel),
              "run: \(label)")
            #expect(
              probe.ceilingDbfs
                == Self.expected(output.probeRuleCeiling, listener: listener, maxLevel: maxLevel),
              "probe: \(label)")
            // The flag names the reported listener (and so the band), whatever it does to the ceiling.
            if let listener {
              #expect(run.kind == listener, "run: \(label)")
              #expect(probe.kind == listener, "probe: \(label)")
            }
            byOutput["\(output), \(flags)", default: []].insert(run.ceilingDbfs)

            if maxLevel == nil {
              #expect(run.ceilingDbfs <= output.ruleCeiling, "never raised: run: \(label)")
              #expect(probe.ceilingDbfs <= output.probeRuleCeiling, "never raised: probe: \(label)")
              #expect(run.ceilingDbfs <= Self.loudestRuleCeiling, "no loop exception: \(label)")
              #expect(probe.ceilingDbfs <= -18, "probe: \(label)")
              if output.isKnownHeadphones {
                #expect(run.ceilingDbfs <= Self.headphoneCeiling, "run: \(label)")
                #expect(probe.ceilingDbfs <= Self.headphoneCeiling, "probe: \(label)")
              }
            }
            checked += 1
          }
        }
      }
    }
    for (key, ceilings) in byOutput {
      #expect(
        ceilings.count == 1, "the input changed the ceiling: \(key) gives \(ceilings.sorted())")
    }
    #expect(
      checked
        == OutputKind.allCases.count * InputKind.allCases.count * Self.listeners.count
        * Self.maxLevels.count)
  }

  // MARK: What really reaches the output

  /// Outputs the simulator can open, with how the HAL would report them.
  enum SimulatedOutput: String, CaseIterable, CustomTestStringConvertible {
    case builtInSpeakers, builtInCatalogMiss, bluetoothCatalogMiss, usb, virtual

    var testDescription: String { rawValue }

    var kind: OutputKind {
      switch self {
      case .builtInSpeakers: return .builtInSpeakers
      case .builtInCatalogMiss: return .builtInCatalogMiss
      case .bluetoothCatalogMiss: return .bluetoothCatalogMiss
      case .usb: return .usb
      case .virtual: return .virtual
      }
    }

    var ref: DeviceRef { kind.device.ref }
  }

  /// Inputs for a run: the microphone, the output's own device (a virtual duplex on a virtual
  /// output, the old -6 dBFS loop), a `Loop 1` channel on it, and another virtual device.
  enum SimulatedRunInput: String, CaseIterable, CustomTestStringConvertible {
    case macMicrophone, sameDevice, sameDeviceLoopChannel, otherVirtual

    var testDescription: String { rawValue }

    func setup(output: DeviceRef) -> ResolvedSetup {
      switch self {
      case .macMicrophone:
        return ResolvedSetup(
          output: output, input: SimulatedCatalog.macMicrophone.ref, outChannels: [1, 2],
          inChannel: 1, inChannelName: "Input 1")
      case .sameDevice, .sameDeviceLoopChannel:
        return ResolvedSetup(
          output: output, input: output, outChannels: [1, 2], inChannel: 1,
          inChannelName: self == .sameDevice ? "Input 1" : "Loop 1")
      case .otherVirtual:
        var other = SimulatedCatalog.duplex.ref
        other.uid = "in-other-virtual"
        return ResolvedSetup(
          output: output, input: other, outChannels: [1, 2], inChannel: 1, inChannelName: "Loop 1")
      }
    }
  }

  /// `--max-level` and `--level` as a run can pass them.
  struct LevelFlags: CustomTestStringConvertible, Sendable {
    var maxLevel: Double?
    var level: Double?
    var testDescription: String {
      "--max-level \(maxLevel.map { String($0) } ?? "-"), --level \(level.map { String($0) } ?? "-")"
    }
  }

  /// None, a `--level` above every ceiling (clamped), and a `--max-level` above every ceiling.
  private static let levelFlags = [
    LevelFlags(), LevelFlags(level: -3), LevelFlags(maxLevel: -3),
  ]

  private static func store() throws -> (RunStore, URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    return (RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:])), folder)
  }

  /// A deaf path makes the ramp climb all the way, so the loudest sound played is the ceiling; a
  /// `--level` plays one probe at the level after the clamp.
  @Test(arguments: SimulatedOutput.allCases, SimulatedRunInput.allCases)
  func aRunNeverPlaysAboveTheRuleCeiling(output: SimulatedOutput, input: SimulatedRunInput)
    async throws
  {
    for listener in Self.listeners {
      for flags in Self.levelFlags {
        let label = "--listener \(listener?.rawValue ?? "-"), \(flags.testDescription)"
        let backend = LoudestPlayedBackend(
          scenario: Scenario(jitterFrames: 0, pathGainDb: -80, seed: 3))
        let (store, folder) = try Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: 3)
        parameters.hits = 5
        parameters.levelDbfs = flags.level
        let request = RunRequest(
          recipe: RecipeRegistry.roundTrip, parameters: parameters,
          setup: input.setup(output: output.ref),
          preflight: PreflightOptions(
            maxLevelDbfs: flags.maxLevel, listener: listener, templateFollowsListener: true))

        var thrown: SoundPingError?
        do {
          for try await _ in RunCoordinator(backend: backend, store: store).run(request) {}
        } catch {
          thrown = error as? SoundPingError
        }

        let ceiling = Self.expected(
          output.kind.ruleCeiling, listener: listener, maxLevel: flags.maxLevel)
        #expect(thrown?.code == "nothingHeardAtCeiling", "\(label)")
        #expect(thrown?.context["ceilingDbfs"] == String(ceiling), "\(label)")
        let loudest = try #require(backend.loudestDbfs, "\(label)")
        #expect(loudest <= ceiling + 1e-3, "played \(loudest) dBFS, ceiling \(ceiling): \(label)")
        #expect(loudest >= ceiling - 1e-3, "the deaf ramp reaches the ceiling: \(label)")
        if flags.maxLevel == nil {
          #expect(loudest <= Self.loudestRuleCeiling + 1e-3, "no loop exception: \(label)")
          if output.kind.isKnownHeadphones {
            #expect(loudest <= Self.headphoneCeiling + 1e-3, "\(label)")
          }
        }
      }
    }
  }

  /// The probe's input devices: an interface, and a virtual device (the output's own on a
  /// virtual output).
  enum SimulatedProbeInput: String, CaseIterable, CustomTestStringConvertible {
    case scarlett, duplex

    var testDescription: String { rawValue }
    var device: DeviceInfo {
      self == .scarlett ? SimulatedCatalog.scarlett : SimulatedCatalog.duplex
    }
  }

  @Test(arguments: SimulatedOutput.allCases, SimulatedProbeInput.allCases)
  func aChannelProbeNeverPlaysAboveTheRuleCeiling(
    output: SimulatedOutput, input: SimulatedProbeInput
  ) async throws {
    let device = input.device
    let setup = ResolvedSetup(
      output: output.ref, input: device.ref, outChannels: [1, 2], inChannel: 0,
      autoInChannel: true)
    for listener in Self.listeners {
      for maxLevel in [nil, -3.0] {
        let label =
          "--listener \(listener?.rawValue ?? "-"), --max-level \(maxLevel.map { String($0) } ?? "-")"
        let backend = LoudestPlayedBackend(
          scenario: Scenario(jitterFrames: 0, pathGainDb: -80, loopChannel: 1, seed: 3))
        var thrown: SoundPingError?
        do {
          _ = try await ChannelProbe().run(
            backend: backend, setup: setup,
            channels: Array((device.input?.channels ?? []).prefix(2)),
            options: PreflightOptions(maxLevelDbfs: maxLevel, listener: listener))
        } catch {
          thrown = error as? SoundPingError
        }

        let ceiling = Self.expected(
          output.kind.probeRuleCeiling, listener: listener, maxLevel: maxLevel)
        #expect(thrown?.code == "nothingHeardAtCeiling", "\(label)")
        #expect(thrown?.context["ceilingDbfs"] == String(ceiling), "\(label)")
        let loudest = try #require(backend.loudestDbfs, "\(label)")
        #expect(loudest <= ceiling + 1e-3, "played \(loudest) dBFS, ceiling \(ceiling): \(label)")
        if maxLevel == nil {
          #expect(loudest <= -18 + 1e-3, "\(label)")
          if output.kind.isKnownHeadphones {
            #expect(loudest <= Self.headphoneCeiling + 1e-3, "\(label)")
          }
        }
      }
    }
  }
}
