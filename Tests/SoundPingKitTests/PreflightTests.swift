import Foundation
import Testing

@testable import SoundPingKit

/// Forwards to the simulator but reports a warning from `open`, as the HAL backend does when it
/// could not register for some device notifications.
private actor WarningBackend: AudioBackend {
  private let inner: SimulatedBackend
  private let warning: String
  nonisolated let events: AsyncStream<DeviceEvent>

  init(scenario: Scenario, warning: String) {
    inner = SimulatedBackend(scenario: scenario)
    self.warning = warning
    events = inner.events
  }

  func open(_ setup: ResolvedSetup, templates: [StimulusTemplate]) async throws -> BackendInfo {
    var info = try await inner.open(setup, templates: templates)
    info.warnings = [warning]
    return info
  }
  func start() async throws -> BackendInfo { try await inner.start() }
  func currentInputFrame() async -> Int64 { await inner.currentInputFrame() }
  func currentOutputFrame() async -> Int64 { await inner.currentOutputFrame() }
  func schedule(_ hits: [ScheduledHit]) async throws { try await inner.schedule(hits) }
  func waitUntilCaptured(throughInputFrame frame: Int64) async throws {
    try await inner.waitUntilCaptured(throughInputFrame: frame)
  }
  func capture(_ range: Range<Int64>) async throws -> [Float] { try await inner.capture(range) }
  func stamps(covering range: Range<Int64>) async -> [CallbackStamp] {
    await inner.stamps(covering: range)
  }
  func stampLog() async -> StampLog { await inner.stampLog() }
  func halHostTime(forInputSample sample: Double) async -> UInt64? { nil }
  func stop() async { await inner.stop() }
}

/// The checks before any sound plays (ENG-03): a denied microphone is silence on macOS, so the run
/// must stop first and name the app that owns the permission.
@Suite struct PreflightTests {
  private struct FakeResolver: ResponsibleAppResolving {
    func resolve() -> ResponsibleApp {
      ResponsibleApp(name: "Ghostty", bundleId: "com.mitchellh.ghostty", detectedVia: "processTree")
    }
  }

  /// A process table written out by hand: pid -> (parent, executable path).
  private struct FakeProcesses: ProcessInspecting {
    var table: [Int32: (parent: Int32, path: String)]
    func parent(of pid: Int32) -> Int32? { table[pid]?.parent }
    func executablePath(of pid: Int32) -> String? { table[pid]?.path }
  }

  private struct Collected {
    var events: [RunEvent]
    var error: SoundPingError?
  }

  private static func run(_ scenario: Scenario) async throws -> Collected {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))

    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: scenario.seed)
    parameters.hits = 10
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: .simulatedDuplex)
    let coordinator = RunCoordinator(
      backend: SimulatedBackend(scenario: scenario), store: store, resolver: FakeResolver())

    var events: [RunEvent] = []
    var thrown: SoundPingError?
    do {
      for try await event in coordinator.run(request) { events.append(event) }
    } catch {
      thrown = error as? SoundPingError
    }
    return Collected(events: events, error: thrown)
  }

  private static func hitEvents(_ events: [RunEvent]) -> [RunEvent] {
    events.filter {
      switch $0 {
      case .hit, .rejected: return true
      default: return false
      }
    }
  }

  // MARK: backend warnings

  @Test func aWarningFromTheBackendReachesThePreflightReport() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))
    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: 3)
    parameters.hits = 5
    let request = RunRequest(
      recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: .simulatedDuplex)
    let backend = WarningBackend(
      scenario: Scenario(jitterFrames: 0, seed: 3), warning: "the HAL refused 2 notifications")

    var result: RunResult?
    for try await event in RunCoordinator(backend: backend, store: store, resolver: FakeResolver())
      .run(request)
    {
      if case .finished(let finished) = event { result = finished }
    }
    let warnings = try #require(result?.preflight?.warnings)
    #expect(warnings.contains("the HAL refused 2 notifications"))
  }

  // MARK: permission

  @Test func aDeniedMicrophoneStopsTheRunBeforeAnyHitAndNamesTheApp() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, permission: .denied, seed: 7))

    let error = try #require(collected.error)
    #expect(error.kind == .preflight)
    #expect(error.code == "micPermissionDenied")
    #expect(error.detail == "Microphone access is denied for Ghostty")
    #expect(error.context["terminalApp"] == "Ghostty")
    #expect(error.context["terminalAppBundleId"] == "com.mitchellh.ghostty")
    #expect(error.context["detectedVia"] == "processTree")
    #expect(
      error.context["fix"]
        == "System Settings → Privacy & Security → Microphone → enable Ghostty, then rerun")

    #expect(Self.hitEvents(collected.events).isEmpty, "no hit before the permission check")
    #expect(collected.events.last == .aborted(error), "the stream ends with the named cause")
    #expect(
      !collected.events.contains {
        if case .armed = $0 { return true }
        return false
      }, "a refused run is never armed")
  }

  @Test func aRestrictedMicrophoneStopsTheRunTheSameWay() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, permission: .restricted, seed: 7))

    let error = try #require(collected.error)
    #expect(error.code == "micPermissionDenied")
    #expect(error.context["status"] == "restricted")
    #expect(error.context["terminalApp"] == "Ghostty")
    #expect(Self.hitEvents(collected.events).isEmpty)
  }

  @Test func anAuthorizedMicrophoneLetsTheRunProceed() async throws {
    let collected = try await Self.run(Scenario(jitterFrames: 0, seed: 7))

    #expect(collected.error == nil)
    #expect(Self.hitEvents(collected.events).count == 15)
    if case .finished = collected.events.last {} else { Issue.record("the run did not finish") }
  }

  @Test func theErrorEnvelopeContextCarriesTheAppNameUnchanged() {
    let app = ResponsibleApp(
      name: "Ünïcödé 録音", bundleId: "dev.example.unicode", detectedVia: "processTree")
    let error = Preflight.permissionError(status: .denied, app: app)
    #expect(error?.context["terminalApp"] == "Ünïcödé 録音")
    #expect(error?.context["fix"]?.contains("enable Ünïcödé 録音") == true)
  }

  // MARK: responsible app

  @Test func theRealResolverNamesSomethingUnderSwiftTest() {
    let app = ProcessTreeResolver().resolve()
    #expect(!app.name.isEmpty)
    #expect(["processTree", "env (likely)", "unknown"].contains(app.detectedVia))
  }

  @Test func theWalkStopsAtTheFirstAppBundleAmongTheAncestors() throws {
    let processes = FakeProcesses(table: [
      500: (parent: 400, path: "/usr/bin/swift-test"),
      400: (parent: 300, path: "/bin/zsh"),
      300: (parent: 200, path: "/Applications/Missing Host.app/Contents/MacOS/host"),
      200: (parent: 1, path: "/Applications/Outer.app/Contents/MacOS/outer"),
    ])
    let app = ProcessTreeResolver(inspector: processes, environment: [:], startPid: 500).resolve()
    // Neither bundle exists on disk: the folder name stands in for the display name.
    #expect(app.name == "Missing Host")
    #expect(app.detectedVia == "processTree")
  }

  @Test func theWalkReadsTheDisplayNameThenTheBundleNameOfARealBundle() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func makeApp(_ folder: String, plist: [String: Any]) throws -> String {
      let contents = root.appendingPathComponent("\(folder).app/Contents", isDirectory: true)
      try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
      try data.write(to: contents.appendingPathComponent("Info.plist"))
      return contents.appendingPathComponent("MacOS/tool").path
    }

    let both = try makeApp(
      "Folder One",
      plist: [
        "CFBundleIdentifier": "dev.example.one", "CFBundleDisplayName": "Display 録音",
        "CFBundleName": "Short",
      ])
    let nameOnly = try makeApp(
      "Folder Two", plist: ["CFBundleIdentifier": "dev.example.two", "CFBundleName": "Short Two"])
    let neither = try makeApp("Folder Three", plist: ["CFBundleIdentifier": "dev.example.three"])

    let first = try #require(ProcessTreeResolver.identity(forExecutable: both))
    #expect(first.name == "Display 録音", "non-ASCII names pass through as UTF-8")
    #expect(first.bundleId == "dev.example.one")
    #expect(try #require(ProcessTreeResolver.identity(forExecutable: nameOnly)).name == "Short Two")
    #expect(
      try #require(ProcessTreeResolver.identity(forExecutable: neither)).name == "Folder Three")
    #expect(ProcessTreeResolver.identity(forExecutable: "/usr/bin/true") == nil)
  }

  @Test func aWalkThatEndsAtLaunchdFallsBackToTheEnvironmentAndSaysLikely() {
    let processes = FakeProcesses(table: [
      500: (parent: 1, path: "/usr/bin/swift-test")
    ])
    let byId = ProcessTreeResolver(
      inspector: processes,
      environment: [
        "__CFBundleIdentifier": "dev.example.not-installed", "TERM_PROGRAM": "ghostty",
      ],
      startPid: 500
    ).resolve()
    #expect(byId.detectedVia == "env (likely)")
    #expect(byId.bundleId == "dev.example.not-installed")
    #expect(!byId.name.isEmpty)

    let byProgram = ProcessTreeResolver(
      inspector: processes, environment: ["TERM_PROGRAM": "ghostty"], startPid: 500
    ).resolve()
    #expect(byProgram.name == "ghostty")
    #expect(byProgram.detectedVia == "env (likely)")
    #expect(byProgram.bundleId == nil)

    let nothing = ProcessTreeResolver(inspector: processes, environment: [:], startPid: 500)
      .resolve()
    #expect(nothing.name == "your terminal app")
    #expect(nothing.detectedVia == "unknown")
  }

  @Test func theProcessTreeWinsOverAnEnvironmentThatSaysOtherwise() {
    let processes = FakeProcesses(table: [
      500: (parent: 400, path: "/usr/bin/swift-test"),
      400: (parent: 1, path: "/Applications/Real Host.app/Contents/MacOS/host"),
    ])
    let app = ProcessTreeResolver(
      inspector: processes, environment: ["__CFBundleIdentifier": "com.evil.spoof"], startPid: 500
    ).resolve()
    #expect(app.name == "Real Host")
    #expect(app.detectedVia == "processTree")
  }
}
