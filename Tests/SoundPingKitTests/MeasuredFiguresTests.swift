import Foundation
import Testing

@testable import SoundPingKit

/// RES-02 and ENG-06: every result says what macOS reports and what was measured, side by side,
/// and a two-device setup gets an honest host-clock number instead of an invented one.
@Suite struct MeasuredFiguresTests {
  private static let injected = 412.37

  private static func ref(_ device: DeviceInfo) -> DeviceRef { device.ref }

  private static var scarlettSetup: ResolvedSetup {
    ResolvedSetup(
      output: ref(SimulatedCatalog.scarlett), input: ref(SimulatedCatalog.scarlett),
      outChannels: [1, 2], inChannel: 1)
  }

  private static var speakersToMicSetup: ResolvedSetup {
    ResolvedSetup(
      output: ref(SimulatedCatalog.macSpeakers), input: ref(SimulatedCatalog.macMicrophone),
      outChannels: [1, 2], inChannel: 1)
  }

  private static func run(
    _ scenario: Scenario, setup: ResolvedSetup, hits: Int = 20
  ) async throws -> RunResult {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = RunStore(paths: try StorePaths.resolve(flag: folder.path, environment: [:]))

    var parameters = RecipeRegistry.roundTrip.defaultParameters(seed: scenario.seed)
    parameters.hits = hits
    let request = RunRequest(recipe: RecipeRegistry.roundTrip, parameters: parameters, setup: setup)
    var finished: RunResult?
    for try await event in RunCoordinator(
      backend: SimulatedBackend(scenario: scenario), store: store
    )
    .run(request) {
      if case .finished(let result) = event { finished = result }
    }
    return try #require(finished)
  }

  // MARK: same device

  @Test func aSameDeviceRunMeasuresPathIoOffsetAndAppRoundTrip() async throws {
    let result = try await Self.run(
      Scenario(latencyFrames: Self.injected, jitterFrames: 0, seed: 1), setup: Self.scarlettSetup)
    let measured = result.measured

    #expect(measured.domain == .sample)
    // The stored marker the calibration record keys its value on (unchanged since plan 01-06).
    // Nothing user-facing leads with it; see PrettyRendererTests and RunStoreTests.
    #expect(measured.headline == .appRoundTrip)
    let path = try #require(measured.path?.median)
    let ioOffset = try #require(measured.ioOffset?.median)
    let appRoundTrip = try #require(measured.appRoundTrip?.median)
    #expect(abs(path.frames - Self.injected) <= 0.1)
    #expect(abs(ioOffset.frames - 284) <= 0.001, "2 x 128 buffer + 28 safety frames")
    #expect(abs(appRoundTrip.frames - (Self.injected + 284)) <= 0.1)
    #expect(abs(appRoundTrip.ms - appRoundTrip.frames / 48) < 1e-9, "ms is frames at 48 kHz")
    #expect(measured.appRoundTrip?.valid == measured.path?.valid)
  }

  @Test func theIoOffsetIsReadFromTheStampsNotAssumed() async throws {
    let result = try await Self.run(
      Scenario(latencyFrames: Self.injected, jitterFrames: 0, ioOffsetFrames: 300, seed: 1),
      setup: Self.scarlettSetup)
    let measured = result.measured
    #expect(abs(try #require(measured.ioOffset?.median).frames - 300) <= 0.001)
    #expect(abs(try #require(measured.appRoundTrip?.median).frames - (Self.injected + 300)) <= 0.1)
  }

  // MARK: two devices

  @Test(arguments: [-50.0, 0.0, 20.0, 50.0])
  func aTwoDeviceRunIsMeasuredOnlyThroughTheHostPath(ppm: Double) async throws {
    let result = try await Self.run(
      Scenario(latencyFrames: Self.injected, jitterFrames: 0, driftPPM: ppm, seed: 2),
      setup: Self.speakersToMicSetup)
    let measured = result.measured

    #expect(measured.domain == .host)
    #expect(measured.headline == .path)
    #expect(measured.appRoundTrip == nil, "defined only for one device")
    #expect(measured.ioOffset == nil, "defined only for one device")
    let path = try #require(measured.path)
    #expect(path.valid == path.n, "every hit found its stimulus through the host-mapped window")
    #expect(abs(try #require(path.median).frames - Self.injected) <= 0.5, "drift \(ppm) ppm")
    #expect(result.selfTest == nil, "the self-test is a same-device check")
    #expect(result.hostTimebase == HostTimebase(numer: 125, denom: 3))
  }

  @Test func aTwoDeviceRunKeepsItsJitter() async throws {
    let result = try await Self.run(
      Scenario(latencyFrames: Self.injected, jitterFrames: 0.5, driftPPM: 20, seed: 4),
      setup: Self.speakersToMicSetup, hits: 40)
    let path = try #require(result.measured.path)
    let jitter = try #require(path.jitter).frames
    // p95 - p5 of a 0.5 frame sigma is about 1.6 frames; the host path must not add to it.
    #expect(jitter > 0.8 && jitter < 2.6, "jitter \(jitter)")
  }

  // MARK: reported next to measured

  @Test func theReportedFiguresAreTheCatalogSumsAtTheBufferUsed() async throws {
    let result = try await Self.run(
      Scenario(latencyFrames: Self.injected, jitterFrames: 0, seed: 1), setup: Self.scarlettSetup)
    let reported = try #require(result.reported)
    let expected = ReportedLatency.compute(
      output: SimulatedCatalog.scarlett, outChannels: [1, 2], input: SimulatedCatalog.scarlett,
      inChannel: 1, outputBufferFrames: 128, inputBufferFrames: 128, sampleRate: 48_000)
    #expect(reported == expected)
    #expect(reported.pathFrames == 57)
    #expect(reported.appRoundTripFrames == 341)
    #expect(reported.expectedIoOffsetFrames == 284)
    #expect(reported.source == "halReported")
  }

  @Test func aTwoDeviceRunReportsTheFixtureSumOfBothDevices() async throws {
    let result = try await Self.run(
      Scenario(latencyFrames: Self.injected, jitterFrames: 0, seed: 2),
      setup: Self.speakersToMicSetup)
    #expect(try #require(result.reported).pathFrames == 2203)
  }

  @Test func aDeviceTheCatalogDoesNotKnowLeavesTheReportOut() async throws {
    var setup = Self.scarlettSetup
    setup.output = DeviceRef(uid: "not-in-the-catalog", name: "Mystery")
    setup.input = setup.output
    let result = try await Self.run(
      Scenario(latencyFrames: Self.injected, jitterFrames: 0, seed: 1), setup: setup, hits: 10)
    #expect(result.reported == nil)
    #expect(result.corrections == [])
  }

  // MARK: ENG-06: reported values are shown, never applied

  @Test func correctionsStayEmptyAndReportedValuesNeverMoveAMeasuredNumber() async throws {
    let scenario = Scenario(latencyFrames: Self.injected, jitterFrames: 0.5, seed: 6)
    let scarlett = try await Self.run(scenario, setup: Self.scarlettSetup)
    // Same simulated signal path, a device whose reported latencies are all zero.
    let duplex = try await Self.run(scenario, setup: .simulatedDuplex)

    #expect(scarlett.corrections == [])
    #expect(duplex.corrections == [])
    #expect(scarlett.reported != duplex.reported)
    #expect(scarlett.measured == duplex.measured, "what macOS claims never changes what was heard")
    #expect(scarlett.hits.map(\.latencyFrames) == duplex.hits.map(\.latencyFrames))
  }

  @Test func aTwoDeviceRunHasNoCorrectionsEither() async throws {
    let result = try await Self.run(
      Scenario(latencyFrames: Self.injected, jitterFrames: 0, seed: 2),
      setup: Self.speakersToMicSetup, hits: 10)
    #expect(result.corrections == [])
  }
}
