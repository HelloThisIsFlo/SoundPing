import Foundation
import Testing

@testable import SoundPingKit

/// CAL-02: each good round trip is stored as a round-trip calibration keyed by its whole path,
/// and nothing in the store can be mistaken for a mic delay (ENG-06, PROJECT accuracy constraint).
@Suite struct CalibrationStoreTests {
  private static let key = CalibrationKey(
    outputUID: "out-uid", outChannels: [1, 2], inputUID: "in-uid", inChannel: 7,
    sampleRate: 48_000, outputBufferFrames: 128, inputBufferFrames: 128)

  private static func record(
    key: CalibrationKey = key, runId: String = "run-1", valueFrames: Double = 696.37
  ) -> CalibrationRecord {
    CalibrationRecord(
      key: key, headline: .appRoundTrip, valueFrames: valueFrames,
      valueMs: valueFrames / 48, pathFrames: 412.37, appRoundTripFrames: valueFrames,
      jitterFrames: 1.25, valid: 98, n: 100, domain: .sample, runId: runId,
      measuredAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private static func tempFile() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("calibrations.json")
  }

  // MARK: kind

  @Test func thereIsOnlyARoundTripKindAndItIsLabelledThat() {
    #expect(CalibrationKind.allCases == [.roundTrip])
    #expect(CalibrationKind.roundTrip.label == "round trip")
    #expect(CalibrationKind.roundTrip.rawValue == "roundTrip")
  }

  @Test func aMicDelayKindCannotBeDecodedOrConstructed() {
    for raw in ["micDelay", "mic_delay", "mic delay", "microphoneDelay"] {
      #expect(CalibrationKind(rawValue: raw) == nil, "\(raw)")
    }
    #expect(
      CalibrationKind.allCases.allSatisfy { !$0.rawValue.lowercased().contains("mic") },
      "no kind speaks of a microphone")
  }

  @Test func aRecordAlwaysCarriesTheKindsLabel() {
    let record = Self.record()
    #expect(record.kind == .roundTrip)
    #expect(record.label == "round trip")
  }

  // MARK: key

  @Test func aKeyMatchesOnlyOnExactEqualityOfEveryField() {
    let key = Self.key
    #expect(
      key
        == CalibrationKey(
          outputUID: "out-uid", outChannels: [1, 2], inputUID: "in-uid", inChannel: 7,
          sampleRate: 48_000, outputBufferFrames: 128, inputBufferFrames: 128))

    var different: [(String, CalibrationKey)] = []
    var changed = key
    changed.outputUID = "other-out"
    different.append(("outputUID", changed))
    changed = key
    changed.outChannels = [1, 3]
    different.append(("outChannels", changed))
    changed = key
    changed.outChannels = [2, 1]
    different.append(("outChannels order", changed))
    changed = key
    changed.inputUID = "other-in"
    different.append(("inputUID", changed))
    changed = key
    changed.inChannel = 8
    different.append(("inChannel 7 -> 8", changed))
    changed = key
    changed.sampleRate = 44_100
    different.append(("sampleRate 48000 -> 44100", changed))
    changed = key
    changed.sampleRate = 48_000.000_001
    different.append(("sampleRate off by a millionth", changed))
    changed = key
    changed.outputBufferFrames = 129
    different.append(("outputBufferFrames 128 -> 129", changed))
    changed = key
    changed.inputBufferFrames = 129
    different.append(("inputBufferFrames 128 -> 129", changed))
    changed = key
    changed.outputBufferFrames = 256
    different.append(("256 out + 128 in", changed))
    changed = key
    changed.inputBufferFrames = 256
    different.append(("128 out + 256 in", changed))

    for (field, other) in different {
      #expect(other != key, "\(field) makes a different key")
    }
    #expect(
      Set(different.map(\.1)).count == different.count, "and all of them differ from each other")
  }

  // MARK: file

  @Test func aRecordRoundTripsThroughTheFileUnchanged() throws {
    let url = Self.tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var key = Self.key
    key.sampleRate = 44_099.999_999_9
    let written = Self.record(key: key)
    try CalibrationStore.record(written, in: url)

    let file = try CalibrationStore.load(from: url)
    #expect(file.schemaVersion == 2)
    #expect(file.calibrations == [written])
    #expect(file.calibrations.first?.key.sampleRate == 44_099.999_999_9, "an exact Double")
    #expect(try CalibrationStore.calibration(for: key, in: url) == written)
  }

  @Test func aSecondRecordForTheSameKeyReplacesTheFirstAndOthersStay() throws {
    let url = Self.tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var other = Self.key
    other.inputBufferFrames = 256
    try CalibrationStore.record(Self.record(runId: "first"), in: url)
    try CalibrationStore.record(Self.record(key: other, runId: "other-buffer"), in: url)
    try CalibrationStore.record(Self.record(runId: "second", valueFrames: 700), in: url)

    let file = try CalibrationStore.load(from: url)
    #expect(file.calibrations.count == 2)
    #expect(file.calibrations.first { $0.key == Self.key }?.runId == "second")
    #expect(file.calibrations.first { $0.key == Self.key }?.valueFrames == 700)
    #expect(file.calibrations.first { $0.key == other }?.runId == "other-buffer")
  }

  @Test func aMissingFileIsEmpty() throws {
    let url = Self.tempFile()
    #expect(try CalibrationStore.load(from: url).calibrations.isEmpty)
    #expect(try CalibrationStore.calibration(for: Self.key, in: url) == nil)
  }

  @Test(arguments: [
    "not json", #"{"schemaVersion": 3, "calibrations": []}"#, #"{"schemaVersion": 1}"#,
  ])
  func anotherSchemaVersionOrMalformedJSONIsAUsageErrorNamingThePath(body: String) throws {
    let url = Self.tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(body.utf8).write(to: url)

    do {
      _ = try CalibrationStore.load(from: url)
      Issue.record("expected calibrationsUnreadable for \(body)")
    } catch let error as SoundPingError {
      #expect(error.kind == .usage)
      #expect(error.code == "calibrationsUnreadable")
      #expect(error.detail.contains(url.path))
    }
    do {
      try CalibrationStore.record(Self.record(), in: url)
      Issue.record("a record must not overwrite a file it cannot read")
    } catch let error as SoundPingError {
      #expect(error.code == "calibrationsUnreadable")
    }
    #expect(try Data(contentsOf: url) == Data(body.utf8), "the unreadable file is left alone")
  }

  // MARK: files written before the two buffers were keyed separately

  /// A schema 1 calibrations.json: one `bufferFrames` in the key.
  private static let legacyFile = """
    {
      "schemaVersion": 1,
      "calibrations": [
        {
          "key": {"outputUID": "out-uid", "outChannels": [1, 2], "inputUID": "in-uid",
                  "inChannel": 7, "sampleRate": 48000, "bufferFrames": 128},
          "kind": "roundTrip", "label": "round trip", "headline": "appRoundTrip",
          "valueFrames": 696.37, "valueMs": 14.5, "pathFrames": 412.37,
          "appRoundTripFrames": 696.37, "jitterFrames": 1.25, "valid": 98, "n": 100,
          "domain": "sample", "runId": "old-run", "measuredAt": "2023-11-14T22:13:20Z"
        }
      ]
    }
    """

  @Test func aSchemaOneFileStillLoadsButItsKeysNeverMatchANewRun() throws {
    let url = Self.tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(Self.legacyFile.utf8).write(to: url)

    let file = try CalibrationStore.load(from: url)
    let old = try #require(file.calibrations.first)
    #expect(old.runId == "old-run")
    #expect(old.key.inputBufferFrames == 128)
    #expect(old.key.outputBufferFrames == 0, "the old key never knew the output's buffer")
    // The setup the old record was made on, buffer 128 on both sides, finds no calibration.
    #expect(old.key != Self.key)
    #expect(try CalibrationStore.calibration(for: Self.key, in: url) == nil)
  }

  @Test func recordingIntoASchemaOneFileKeepsTheOldRecordAndMovesTheFileToSchemaTwo() throws {
    let url = Self.tempFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(Self.legacyFile.utf8).write(to: url)

    try CalibrationStore.record(Self.record(runId: "new-run"), in: url)

    let file = try CalibrationStore.load(from: url)
    #expect(file.schemaVersion == 2)
    #expect(file.calibrations.count == 2)
    #expect(file.calibrations.first?.runId == "old-run")
    #expect(try CalibrationStore.calibration(for: Self.key, in: url)?.runId == "new-run")
    // And the rewritten file is a plain schema 2 file: the old key keeps its "unknown" output.
    let again = try CalibrationStore.load(from: url)
    #expect(again == file)
  }

  @Test func aSchemaOneRunJSONSetupReadsBackWithItsBufferInBothDirections() throws {
    let current = SetupSnapshot(
      setup: .simulatedDuplex, sampleRate: 48_000, outputBufferFrames: 256, inputBufferFrames: 256,
      simulated: true)
    var object = try #require(
      try JSONSerialization.jsonObject(with: RunJSON.fileEncoder().encode(current))
        as? [String: Any])
    object["outputBufferFrames"] = nil
    object["inputBufferFrames"] = nil
    object["bufferFrames"] = 256
    let legacy = try RunJSON.decoder().decode(
      SetupSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy == current)
  }

  // MARK: through a run

  private static func makeStore() throws -> (store: RunStore, cleanup: @Sendable () -> Void) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-test-\(UUID().uuidString)", isDirectory: true)
    let paths = try StorePaths.resolve(flag: folder.path, environment: [:])
    return (RunStore(paths: paths), { try? FileManager.default.removeItem(at: folder) })
  }

  private static var scarlett: ResolvedSetup {
    ResolvedSetup(
      output: SimulatedCatalog.scarlett.ref, input: SimulatedCatalog.scarlett.ref,
      outChannels: [1, 2], inChannel: 7)
  }

  private static func run(
    _ scenario: Scenario, setup: ResolvedSetup = scarlett, hits: Int = 20, store: RunStore
  ) async throws -> RunResult {
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

  @Test func aPassingRunStoresOneRoundTripCalibrationKeyedByItsSetup() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let result = try await Self.run(
      Scenario(latencyFrames: 412.37, jitterFrames: 0, seed: 4), store: store)

    let key = CalibrationKey(
      outputUID: SimulatedCatalog.scarlettUID, outChannels: [1, 2],
      inputUID: SimulatedCatalog.scarlettUID, inChannel: 7, sampleRate: 48_000,
      outputBufferFrames: 128, inputBufferFrames: 128)
    #expect(result.calibration == CalibrationRef(key: key, stored: true))
    #expect(result.calibration?.label == "round trip")

    let file = try CalibrationStore.load(from: store.paths.calibrations)
    let stored = try #require(file.calibrations.first)
    #expect(file.calibrations.count == 1)
    #expect(stored.key == key)
    #expect(stored.kind == .roundTrip)
    #expect(stored.label == "round trip")
    #expect(stored.headline == .appRoundTrip)
    #expect(abs(stored.valueFrames - (412.37 + 284)) <= 0.1)
    #expect(abs(stored.valueMs - stored.valueFrames / 48) < 1e-9)
    #expect(abs(stored.pathFrames - 412.37) <= 0.1)
    #expect(abs(try #require(stored.appRoundTripFrames) - stored.valueFrames) < 1e-9)
    #expect(stored.valid == 20 && stored.n == 20)
    #expect(stored.domain == .sample)
    #expect(stored.runId == result.runId)
  }

  @Test func aRunThatFailsTheValidHitGateStoresNothing() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    // 20 measured hits need 10 valid. Warm-ups are hits 0-4; missing hits 5-15 leaves 9.
    let result = try await Self.run(
      Scenario(jitterFrames: 0, missedHits: Array(5...15), seed: 4), store: store)

    #expect(try #require(result.measured.path).valid == 9)
    let reference = try #require(result.calibration)
    #expect(!reference.stored)
    #expect(reference.kind == .roundTrip)
    #expect(try CalibrationStore.load(from: store.paths.calibrations).calibrations.isEmpty)
  }

  @Test func exactlyTheRequiredNumberOfValidHitsStillStores() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let result = try await Self.run(
      Scenario(jitterFrames: 0, missedHits: Array(5...14), seed: 4), store: store)
    #expect(try #require(result.measured.path).valid == 10)
    #expect(try #require(result.calibration).stored)
    #expect(try CalibrationStore.load(from: store.paths.calibrations).calibrations.count == 1)
  }

  @Test func theSameSetupRunTwiceKeepsOneRecordAndADifferentSetupAddsAnother() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let first = try await Self.run(Scenario(jitterFrames: 0, seed: 1), hits: 10, store: store)
    let second = try await Self.run(Scenario(jitterFrames: 0, seed: 2), hits: 10, store: store)
    var file = try CalibrationStore.load(from: store.paths.calibrations)
    #expect(file.calibrations.count == 1)
    #expect(file.calibrations.first?.runId == second.runId)
    #expect(first.runId != second.runId)

    var otherChannel = Self.scarlett
    otherChannel.inChannel = 8
    _ = try await Self.run(
      Scenario(jitterFrames: 0, seed: 3), setup: otherChannel, hits: 10, store: store)
    file = try CalibrationStore.load(from: store.paths.calibrations)
    #expect(file.calibrations.count == 2, "input channel 7 and 8 are different keys")
  }

  @Test func aTwoDeviceRunStoresItsHostPathAsTheHeadline() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let setup = ResolvedSetup(
      output: SimulatedCatalog.macSpeakers.ref, input: SimulatedCatalog.macMicrophone.ref,
      outChannels: [1, 2], inChannel: 1)
    _ = try await Self.run(
      Scenario(latencyFrames: 412.37, jitterFrames: 0, driftPPM: 20, seed: 5), setup: setup,
      store: store)

    let stored = try #require(
      try CalibrationStore.load(from: store.paths.calibrations).calibrations.first)
    #expect(stored.headline == .path)
    #expect(stored.domain == .host)
    #expect(stored.appRoundTripFrames == nil)
    #expect(abs(stored.valueFrames - 412.37) <= 0.5)
    #expect(stored.key.outputUID == SimulatedCatalog.macSpeakersUID)
    #expect(stored.key.inputUID == SimulatedCatalog.macMicrophoneUID)
  }

  @Test func nothingCorrectsAMeasurementWithAStoredCalibration() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let first = try await Self.run(
      Scenario(latencyFrames: 400, jitterFrames: 0, seed: 7), store: store)
    // The stored calibration is there for the next run to be compared with; it is never subtracted.
    let second = try await Self.run(
      Scenario(latencyFrames: 400, jitterFrames: 0, seed: 7), store: store)
    #expect(first.corrections == [] && second.corrections == [])
    #expect(first.measured.path == second.measured.path)
  }

  @Test func anUnreadableCalibrationFileFailsTheRunBeforeAnyAudio() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    try Data("{".utf8).write(to: store.paths.calibrations)
    do {
      _ = try await Self.run(Scenario(seed: 1), hits: 5, store: store)
      Issue.record("expected the run to fail")
    } catch let error as SoundPingError {
      #expect(error.code == "calibrationsUnreadable")
      #expect(error.detail.contains(store.paths.calibrations.path))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.paths.runs.path).isEmpty)
  }

  @Test func aTwoDeviceRunKeysAndRecordsBothBuffers() async throws {
    let (store, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let setup = ResolvedSetup(
      output: SimulatedCatalog.macSpeakers.ref, input: SimulatedCatalog.macMicrophone.ref,
      outChannels: [1, 2], inChannel: 1)
    let result = try await Self.run(
      Scenario(
        latencyFrames: 2_203, jitterFrames: 0, bufferFrames: 128, outputBufferFrames: 512,
        seed: 4),
      setup: setup, store: store)

    #expect(result.setup.outputBufferFrames == 512)
    #expect(result.setup.inputBufferFrames == 128)
    #expect(result.setup.bufferSummary == "512 out + 128 in")
    let key = try #require(result.calibration?.key)
    #expect(key.outputBufferFrames == 512 && key.inputBufferFrames == 128)
    let reported = try #require(result.reported)
    #expect(reported.output.bufferFrames == 512 && reported.input.bufferFrames == 128)
    #expect(reported.expectedIoOffsetFrames == 512 + 128 + 48 + 36)
  }
}
