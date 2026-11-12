import Foundation
import Testing

@testable import SoundPingKit

@Suite struct RunStoreTests {
  private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

  private static func makeStore() throws -> (store: RunStore, root: URL, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-store-\(UUID().uuidString)", isDirectory: true)
    let paths = try StorePaths.resolve(flag: root.path, environment: [:])
    return (RunStore(paths: paths), paths.root, { try? FileManager.default.removeItem(at: root) })
  }

  private static func result(label: String? = nil, tags: [String] = [], createdAt: Date = baseDate)
    -> RunResult
  {
    RunResult(
      runId: "placeholder",
      runPath: "",
      createdAt: createdAt,
      toolVersion: "test",
      os: "macOS test",
      recipe: RecipeRegistry.roundTrip.ref,
      label: label,
      tags: tags,
      parameters: RecipeRegistry.roundTrip.defaultParameters(seed: 1),
      setup: SetupSnapshot(
        setup: .simulatedDuplex, sampleRate: 48_000, bufferFrames: 128, simulated: true),
      measured: Measured(
        headline: .path, domain: .sample,
        path: SummaryStats(n: 10, valid: 10, median: StatValue(frames: 100, ms: 2.08))),
      histogram: nil,
      hits: [],
      rejectedCounts: [:],
      segments: RecipeRegistry.roundTrip.segments,
      corrections: [],
      simulation: nil)
  }

  /// Creates a folder for `result` and writes it, returning the folder.
  @discardableResult
  private static func save(_ result: RunResult, in store: RunStore) throws -> URL {
    let folder = try store.createRunFolder(
      recipeId: result.recipe.id, label: result.label, createdAt: result.createdAt)
    var stored = result
    stored.runId = folder.lastPathComponent
    stored.runPath = folder.path
    try store.write(stored, to: folder)
    return folder
  }

  private static func code(of body: () throws -> Void) -> String? {
    do {
      try body()
      return nil
    } catch let error as SoundPingError {
      return error.code
    } catch {
      return "other: \(error)"
    }
  }

  // MARK: slug

  @Test func slugKeepsWordsAndDropsPunctuation() {
    #expect(
      RunStore.slug(recipeId: "round-trip", label: "BT MIDI, buffer 128")
        == "round-trip-bt-midi-buffer-128")
  }

  @Test func slugNeutralisesTraversalAndStaysInsideRuns() throws {
    #expect(RunStore.slug(recipeId: "round-trip", label: "../../x") == "round-trip-x")
    let (store, _, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let folder = try store.createRunFolder(
      recipeId: "round-trip", label: "../../x", createdAt: Self.baseDate)
    #expect(folder.deletingLastPathComponent().standardizedFileURL == store.paths.runs.standardizedFileURL)
    #expect(folder.lastPathComponent.hasSuffix("-round-trip-x"))
  }

  @Test func slugMapsNonAsciiToDashes() {
    #expect(RunStore.slug(recipeId: "round-trip", label: "Café Ñ") == "round-trip-caf")
  }

  @Test func missingOrEmptyLabelGivesTheRecipeId() {
    #expect(RunStore.slug(recipeId: "round-trip", label: nil) == "round-trip")
    #expect(RunStore.slug(recipeId: "round-trip", label: "") == "round-trip")
  }

  @Test func slugIsCappedAtFortyEightCharacters() {
    // "round-trip-" is 11 characters.
    let whole = RunStore.slug(recipeId: "round-trip", label: String(repeating: "a", count: 37))
    #expect(whole.count == 48)
    #expect(whole == "round-trip-" + String(repeating: "a", count: 37))

    let cut = RunStore.slug(recipeId: "round-trip", label: String(repeating: "a", count: 38))
    #expect(cut.count == 48)

    // A dash that lands on the cut is trimmed away.
    let trimmed = RunStore.slug(
      recipeId: "round-trip", label: String(repeating: "a", count: 36) + "-b")
    #expect(trimmed == "round-trip-" + String(repeating: "a", count: 36))
  }

  // MARK: folders

  @Test func folderNameStartsWithTheUtcTimestamp() {
    // 1_700_000_000 = 2023-11-14T22:13:20Z
    #expect(
      RunStore.folderName(recipeId: "round-trip", label: nil, createdAt: Self.baseDate)
        == "20231114T221320Z-round-trip")
  }

  @Test func sameSecondSameSlugGetsSuffixes() throws {
    let (store, _, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let names = try (0..<3).map { _ in
      try store.createRunFolder(recipeId: "round-trip", label: "x", createdAt: Self.baseDate)
        .lastPathComponent
    }
    #expect(
      names == [
        "20231114T221320Z-round-trip-x", "20231114T221320Z-round-trip-x-2",
        "20231114T221320Z-round-trip-x-3",
      ])
  }

  // MARK: write

  @Test func writeLeavesNoTempFileAndOneTrailingNewline() throws {
    let (store, _, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let folder = try Self.save(Self.result(label: "Café ../x", tags: ["a"]), in: store)
    let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(contents == ["run.json"])

    let text = try String(contentsOf: folder.appendingPathComponent("run.json"), encoding: .utf8)
    #expect(text.hasSuffix("}\n"))
    #expect(!text.hasSuffix("\n\n"))
    #expect(text.contains("\"label\" : \"Café ../x\""))
  }

  // MARK: store paths

  @Test func storePathsPrecedenceAndAbsoluteRoot() throws {
    let flagRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-flag-\(UUID().uuidString)").path
    let envRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("soundping-env-\(UUID().uuidString)").path
    defer {
      try? FileManager.default.removeItem(atPath: flagRoot)
      try? FileManager.default.removeItem(atPath: envRoot)
    }

    let both = try StorePaths.resolve(flag: flagRoot, environment: ["SOUNDPING_HOME": envRoot])
    #expect(both.source == "flag")
    #expect(both.root.path == URL(fileURLWithPath: flagRoot).standardizedFileURL.path)

    let envOnly = try StorePaths.resolve(flag: nil, environment: ["SOUNDPING_HOME": envRoot])
    #expect(envOnly.source == "env")
    #expect(envOnly.root.path == URL(fileURLWithPath: envRoot).standardizedFileURL.path)

    #expect(
      Self.code {
        _ = try StorePaths.resolve(flag: "relative/store", environment: [:])
      } == "invalidStorePath")
    #expect(
      Self.code {
        _ = try StorePaths.resolve(flag: nil, environment: ["SOUNDPING_HOME": "relative"])
      } == "invalidStorePath")
  }

  // MARK: lock

  @Test func aSecondRunLockOnTheSameRootIsBusy() throws {
    let (store, _, cleanup) = try Self.makeStore()
    defer { cleanup() }
    var first: RunStore? = try store.acquiringRunLock()
    #expect(first != nil)

    var thrown: SoundPingError?
    do { _ = try store.acquiringRunLock() } catch let error as SoundPingError { thrown = error }
    #expect(thrown?.kind == .busy)
    #expect(thrown?.code == "runInProgress")

    // Releasing the first holder frees the lock again.
    first = nil
    #expect(Self.code { _ = try store.acquiringRunLock() } == nil)
  }

  // MARK: list

  @Test func listSortsNewestFirstThenByFolderName() throws {
    let (store, _, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let older = Self.baseDate
    let newer = Self.baseDate.addingTimeInterval(10)
    try Self.save(Self.result(label: "old", createdAt: older), in: store)
    try Self.save(Self.result(label: "b", createdAt: newer), in: store)
    try Self.save(Self.result(label: "a", createdAt: newer), in: store)

    let listing = try store.list()
    #expect(listing.map(\.label) == ["a", "b", "old"])
    #expect(listing.first?.recipe == "round-trip")
    #expect(listing.first?.medianMs == 2.08)
    #expect(listing.first?.valid == 10)
  }

  // MARK: load

  @Test func loadsByRunIdAndByAbsolutePath() throws {
    let (store, _, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let folder = try Self.save(Self.result(label: "x", tags: ["a", "b"]), in: store)

    let byId = try store.load(folder.lastPathComponent)
    #expect(byId.runId == folder.lastPathComponent)
    #expect(byId.tags == ["a", "b"])

    let byPath = try store.load(folder.path)
    #expect(byPath == byId)

    let bytes = try store.loadBytes(folder.lastPathComponent)
    #expect(bytes == (try Data(contentsOf: folder.appendingPathComponent("run.json"))))
  }

  @Test func loadRefusesIdsThatCouldLeaveRuns() throws {
    let (store, root, cleanup) = try Self.makeStore()
    defer { cleanup() }
    // A decodable run.json one level above runs/ must stay unreachable through any id.
    var decoy = Self.result(label: "decoy")
    decoy.runId = "decoy"
    try RunStore.encodedBytes(for: decoy).write(to: root.appendingPathComponent("run.json"))

    for id in ["..", ".", "../x", "a/b", ""] {
      #expect(Self.code { _ = try store.load(id) } == "unreadableRun", "id '\(id)'")
    }
    #expect(Self.code { _ = try store.load(root.appendingPathComponent("nope").path) } == "unreadableRun")
  }

  @Test func anUndecodableRunJsonIsUnreadableAndNamesThePath() throws {
    let (store, _, cleanup) = try Self.makeStore()
    defer { cleanup() }
    let folder = try store.createRunFolder(
      recipeId: "round-trip", label: nil, createdAt: Self.baseDate)
    try Data("not json".utf8).write(to: folder.appendingPathComponent("run.json"))

    var thrown: SoundPingError?
    do { _ = try store.load(folder.lastPathComponent) } catch let error as SoundPingError {
      thrown = error
    }
    #expect(thrown?.code == "unreadableRun")
    #expect(thrown?.detail.contains(folder.path) == true)
  }
}
