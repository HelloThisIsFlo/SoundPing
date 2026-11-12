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

/// The guard against the next hearing-safety regression (CR-02 → CR-03 → CR-04, WR-13). It walks
/// every output kind × input kind × `--listener` × `--max-level`, on the run path and on the
/// `--in-channel auto` probe path, and checks the ceiling against the model written down at
/// `LevelRamp.classify`, restated here independently as the expected table:
///
/// - Without `--max-level`, an output treated as headphones never gets a ceiling above -30 dBFS.
/// - The detected listener: headphones first; then a loop SoundPing can see (a `Loop` channel or a
///   virtual input on the output's own device, or virtual into virtual) is loopback; then the
///   built-in speakers (`ispk`) are speaker; everything else is unknown. The probe only tells
///   headphones from unknown.
/// - The ceiling is `--max-level` when given, else the lower of the detected and the named listener's.
@Suite struct LoudnessInvariantTests {
  // MARK: The documented model, restated

  /// The ceiling table, written out again rather than read from `LevelRamp`, so a changed number
  /// there fails here.
  private static func documentedCeiling(_ kind: ListenerKind) -> Double {
    switch kind {
    case .headphones: return -30
    case .speaker: return -12
    case .unknown: return -18
    case .loopback: return -6
    }
  }

  private static let headphoneCeiling = -30.0

  enum OutputKind: String, CaseIterable, CustomTestStringConvertible {
    case builtInSpeakers, builtInHeadphones, builtInNoDataSource, builtInOtherDataSource
    case builtInCatalogMiss, bluetooth, bluetoothCatalogMiss, usb, thunderbolt, aggregate, airPlay
    case otherTransport, virtual

    var testDescription: String { rawValue }

    /// Known headphones: the built-in jack, any Bluetooth output, and the WR-12 fail-safe rule (a
    /// built-in output that does not report `ispk`, or whose device info is missing).
    var isKnownHeadphones: Bool {
      switch self {
      case .builtInHeadphones, .builtInNoDataSource, .builtInOtherDataSource, .builtInCatalogMiss,
        .bluetooth, .bluetoothCatalogMiss:
        return true
      case .builtInSpeakers, .usb, .thunderbolt, .aggregate, .airPlay, .otherTransport, .virtual:
        return false
      }
    }

    /// The device the HAL would report (nil for a catalog miss) and the reference the setup keeps.
    var device: (info: DeviceInfo?, ref: DeviceRef) {
      func with(
        _ base: DeviceInfo, uid: String, transport: String, dataSource: String?? = nil
      ) -> DeviceInfo {
        var device = base
        device.uid = uid
        device.transport = transport
        if let dataSource { device.output?.dataSource = dataSource }
        return device
      }
      let speakers = SimulatedCatalog.macSpeakers
      let info: DeviceInfo
      switch self {
      case .builtInSpeakers: info = speakers
      case .builtInHeadphones:
        info = with(speakers, uid: "out-hdpn", transport: "builtIn", dataSource: "hdpn")
      case .builtInNoDataSource:
        info = with(speakers, uid: "out-nil", transport: "builtIn", dataSource: .some(nil))
      case .builtInOtherDataSource:
        info = with(speakers, uid: "out-hdmi", transport: "builtIn", dataSource: "hdmi")
      case .bluetooth:
        info = with(speakers, uid: "out-bt", transport: "bluetooth", dataSource: "ispk")
      case .usb: info = SimulatedCatalog.scarlett
      case .thunderbolt:
        info = with(SimulatedCatalog.scarlett, uid: "out-tb", transport: "thunderbolt")
      case .aggregate:
        info = with(SimulatedCatalog.scarlett, uid: "out-aggregate", transport: "aggregate")
      case .airPlay:
        info = with(speakers, uid: "out-airplay", transport: "airPlay", dataSource: .some(nil))
      case .otherTransport:
        info = with(SimulatedCatalog.scarlett, uid: "out-other", transport: "other")
      case .virtual: info = SimulatedCatalog.duplex
      case .builtInCatalogMiss:
        return (nil, DeviceRef(uid: "out-builtin-miss", name: "Built-in", transport: "builtIn"))
      case .bluetoothCatalogMiss:
        return (nil, DeviceRef(uid: "out-bt-miss", name: "AirPods", transport: "bluetooth"))
      }
      return (info, info.ref)
    }
  }

  enum InputKind: String, CaseIterable, CustomTestStringConvertible {
    /// The MacBook microphone, a separate device.
    case builtInMic
    /// A plain channel of a separate interface.
    case interface
    /// A plain channel of the output's own device (on a virtual output, a virtual input).
    case sameDevicePlainChannel
    /// A channel named "Loop 1" on the output's own device.
    case loopChannelSameDevice
    /// A channel named "Loop 1" on another device.
    case loopChannelOtherDevice
    /// A virtual device other than the output.
    case virtualOtherDevice

    var testDescription: String { rawValue }
  }

  /// The listener the model says SoundPing detects for a run.
  private static func documentedRunListener(_ output: OutputKind, _ input: InputKind)
    -> ListenerKind
  {
    if output.isKnownHeadphones { return .headphones }
    switch input {
    case .loopChannelSameDevice: return .loopback
    case .sameDevicePlainChannel where output == .virtual: return .loopback
    case .virtualOtherDevice where output == .virtual: return .loopback
    default: break
    }
    return output == .builtInSpeakers ? .speaker : .unknown
  }

  private static func documentedProbeListener(_ output: OutputKind) -> ListenerKind {
    output.isKnownHeadphones ? .headphones : .unknown
  }

  private static func documentedCeiling(
    detected: ListenerKind, listener: ListenerKind?, maxLevel: Double?
  ) -> Double {
    if let maxLevel { return maxLevel }
    return Swift.min(documentedCeiling(detected), documentedCeiling(listener ?? detected))
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
    case .virtualOtherDevice:
      var device = SimulatedCatalog.duplex
      device.uid = "in-other-virtual"
      inputInfo = device
      inputRef = device.ref
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

  @Test func everyCombinationGetsTheDocumentedCeilingAndHeadphonesNeverExceedMinusThirty()
    throws
  {
    var checked = 0
    for output in OutputKind.allCases {
      for input in InputKind.allCases {
        let (setup, outputInfo, inputInfo) = Self.combination(output, input)
        for listener in Self.listeners {
          for maxLevel in Self.maxLevels {
            let options = PreflightOptions(maxLevelDbfs: maxLevel, listener: listener)
            let label =
              "\(output) + \(input), --listener \(listener?.rawValue ?? "-"), --max-level \(maxLevel.map { String($0) } ?? "-")"

            let run = try LevelRamp.runLoudness(
              setup: setup, output: outputInfo, input: inputInfo, options: options)
            let probe = try LevelRamp.probeLoudness(
              setup: setup, output: outputInfo, options: options)
            let runDetected = Self.documentedRunListener(output, input)
            let probeDetected = Self.documentedProbeListener(output)

            #expect(run.detected == runDetected, "run: \(label)")
            #expect(probe.detected == probeDetected, "probe: \(label)")
            #expect(run.kind == listener ?? runDetected, "run: \(label)")
            #expect(probe.kind == listener ?? probeDetected, "probe: \(label)")

            let runExpected = Self.documentedCeiling(
              detected: runDetected, listener: listener, maxLevel: maxLevel)
            let probeExpected = Self.documentedCeiling(
              detected: probeDetected, listener: listener, maxLevel: maxLevel)
            #expect(run.ceilingDbfs == runExpected, "run: \(label)")
            #expect(probe.ceilingDbfs == probeExpected, "probe: \(label)")

            if maxLevel == nil {
              // --listener never raises the ceiling: only --max-level does.
              #expect(run.ceilingDbfs <= Self.documentedCeiling(runDetected), "run: \(label)")
              #expect(probe.ceilingDbfs <= Self.documentedCeiling(probeDetected), "probe: \(label)")
              if output.isKnownHeadphones {
                #expect(run.ceilingDbfs <= Self.headphoneCeiling, "run: \(label)")
                #expect(probe.ceilingDbfs <= Self.headphoneCeiling, "probe: \(label)")
              }
              // The probe never takes a louder kind than unknown, and never more than the run.
              #expect(probe.ceilingDbfs <= -18, "probe: \(label)")
            }
            checked += 1
          }
        }
      }
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

    var ref: DeviceRef {
      switch self {
      case .builtInSpeakers: return SimulatedCatalog.macSpeakers.ref
      case .builtInCatalogMiss:
        return DeviceRef(uid: "out-builtin-miss", name: "Built-in", transport: "builtIn")
      case .bluetoothCatalogMiss:
        return DeviceRef(uid: "out-bt-miss", name: "AirPods", transport: "bluetooth")
      case .usb: return SimulatedCatalog.scarlett.ref
      case .virtual: return SimulatedCatalog.duplex.ref
      }
    }

    var kind: OutputKind {
      switch self {
      case .builtInSpeakers: return .builtInSpeakers
      case .builtInCatalogMiss: return .builtInCatalogMiss
      case .bluetoothCatalogMiss: return .bluetoothCatalogMiss
      case .usb: return .usb
      case .virtual: return .virtual
      }
    }
  }

  private static let everyListener: [ListenerKind?] = [nil] + ListenerKind.allCases.map { $0 }

  /// A deaf path makes the ramp climb all the way, so the loudest sound played is the ceiling.
  @Test(arguments: SimulatedOutput.allCases, everyListener)
  func aRunNeverPlaysAboveTheDocumentedCeiling(output: SimulatedOutput, listener: ListenerKind?)
    async throws
  {
    let setup = ResolvedSetup(
      output: output.ref, input: SimulatedCatalog.macMicrophone.ref, outChannels: [1, 2],
      inChannel: 1, inChannelName: "Input 1")
    let backend = LoudestPlayedBackend(scenario: Scenario(jitterFrames: 0, pathGainDb: -80, seed: 3))
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))
    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: 3)
    parameters.hits = 5
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: setup,
      preflight: PreflightOptions(listener: listener, templateFollowsListener: true))

    var thrown: SoundPingError?
    do {
      for try await _ in RunCoordinator(backend: backend, store: store).run(request) {}
    } catch {
      thrown = error as? SoundPingError
    }

    let expected = Self.documentedCeiling(
      detected: Self.documentedRunListener(output.kind, .builtInMic), listener: listener,
      maxLevel: nil)
    #expect(thrown?.code == "nothingHeardAtCeiling")
    #expect(thrown?.context["ceilingDbfs"] == String(expected))
    let loudest = try #require(backend.loudestDbfs)
    #expect(loudest <= expected + 1e-3, "played \(loudest) dBFS, ceiling \(expected)")
    if output.kind.isKnownHeadphones { #expect(loudest <= Self.headphoneCeiling + 1e-3) }
  }

  @Test(arguments: SimulatedOutput.allCases, everyListener)
  func aChannelProbeNeverPlaysAboveTheDocumentedCeiling(
    output: SimulatedOutput, listener: ListenerKind?
  ) async throws {
    let scarlett = SimulatedCatalog.scarlett
    let setup = ResolvedSetup(
      output: output.ref, input: scarlett.ref, outChannels: [1, 2], inChannel: 0,
      autoInChannel: true)
    let backend = LoudestPlayedBackend(
      scenario: Scenario(jitterFrames: 0, pathGainDb: -80, loopChannel: 7, seed: 3))
    var thrown: SoundPingError?
    do {
      _ = try await ChannelProbe().run(
        backend: backend, setup: setup, channels: Array((scarlett.input?.channels ?? []).prefix(2)),
        options: PreflightOptions(listener: listener))
    } catch {
      thrown = error as? SoundPingError
    }

    let expected = Self.documentedCeiling(
      detected: Self.documentedProbeListener(output.kind), listener: listener, maxLevel: nil)
    #expect(thrown?.code == "nothingHeardAtCeiling")
    #expect(thrown?.context["ceilingDbfs"] == String(expected))
    let loudest = try #require(backend.loudestDbfs)
    #expect(loudest <= expected + 1e-3, "played \(loudest) dBFS, ceiling \(expected)")
    if output.kind.isKnownHeadphones { #expect(loudest <= Self.headphoneCeiling + 1e-3) }
  }
}
