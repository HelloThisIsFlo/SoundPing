import ArgumentParser
import Foundation
import SoundPingKit
import Testing

@testable import soundping

/// The failure contract (D-03): an agent branches on the exit code and on one JSON object,
/// never on prose.
@Suite struct ErrorReportingTests {
  private static func error(
    _ kind: SoundPingError.Kind, code: String = "someCode", detail: String = "something went wrong",
    context: [String: String] = [:]
  ) -> SoundPingError {
    SoundPingError(kind: kind, code: code, detail: detail, context: context)
  }

  private static func object(_ line: String) throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8))
    return try #require(parsed as? [String: Any])
  }

  // MARK: exit codes

  @Test func everyErrorClassHasItsOwnExitCode() {
    #expect(ExitCodes.code(for: .usage) == 64)
    #expect(ExitCodes.code(for: .preflight) == 65)
    #expect(ExitCodes.code(for: .deviceChanged) == 75)
    #expect(ExitCodes.code(for: .gate) == 3)
    #expect(ExitCodes.code(for: .busy) == 73)
    #expect(ExitCodes.code(for: .internalError) == 70)
  }

  @Test func theExitCodesAreDistinct() {
    let kinds: [SoundPingError.Kind] = [
      .usage, .preflight, .deviceChanged, .gate, .busy, .internalError,
    ]
    #expect(Set(kinds.map { ExitCodes.code(for: $0) }).count == kinds.count)
    #expect(!kinds.contains { ExitCodes.code(for: $0) == 0 }, "no failure may exit 0")
  }

  @Test func aReportCarriesTheExitCodeOfItsKind() {
    for kind: SoundPingError.Kind in [.usage, .preflight, .deviceChanged, .gate, .busy] {
      let report = ErrorReporting.report(for: Self.error(kind), jsonMode: true)
      #expect(report.exitCode == ExitCodes.code(for: kind), "\(kind)")
    }
  }

  @Test func anErrorThatIsNotASoundPingErrorIsInternal() throws {
    struct Surprise: Error, CustomStringConvertible { var description: String { "surprise" } }
    let report = ErrorReporting.report(for: Surprise(), jsonMode: true)
    #expect(report.exitCode == 70)
    let envelope = try Self.object(try #require(report.stdout))
    #expect(envelope["kind"] as? String == "internal")
    #expect(envelope["code"] as? String == "internal")
    #expect((envelope["detail"] as? String)?.contains("surprise") == true)
  }

  // MARK: JSON envelope

  @Test func jsonModePutsExactlyOneEnvelopeLineOnStdout() throws {
    let error = Self.error(
      .preflight, code: "micPermissionDenied", detail: "the microphone is blocked",
      context: ["terminalApp": "Ghostty", "fix": "enable it in System Settings"])
    let report = ErrorReporting.report(for: error, jsonMode: true)

    let line = try #require(report.stdout)
    #expect(!line.contains("\n"), "one line")
    let envelope = try Self.object(line)
    #expect(envelope["schemaVersion"] as? Int == 1)
    #expect(envelope["type"] as? String == "error")
    #expect(envelope["kind"] as? String == "preflight")
    #expect(envelope["code"] as? String == "micPermissionDenied")
    #expect(envelope["detail"] as? String == "the microphone is blocked")
    #expect(envelope["terminalApp"] as? String == "Ghostty", "context keys sit at top level")
    #expect(envelope["fix"] as? String == "enable it in System Settings")
    #expect(envelope["context"] == nil, "context is flattened, not nested")
  }

  @Test func aNonAsciiAppNameReachesTheEnvelopeAsUTF8Unchanged() throws {
    let name = "Ünïcödé 録音 🎛"
    let app = ResponsibleApp(
      name: name, bundleId: "dev.example.unicode", detectedVia: "processTree")
    let error = try #require(Preflight.permissionError(status: .denied, app: app))
    let line = try #require(ErrorReporting.report(for: error, jsonMode: true).stdout)

    #expect(line.contains(name), "raw UTF-8 on the wire, no \\u escapes")
    #expect(!line.contains("\\u"))
    let envelope = try Self.object(line)
    #expect(envelope["terminalApp"] as? String == name)
    #expect(envelope["code"] as? String == "micPermissionDenied")
    #expect(envelope["terminalAppBundleId"] as? String == "dev.example.unicode")
  }

  @Test func envelopeKeysAreSorted() throws {
    let line = ErrorEnvelope.line(
      for: Self.error(.busy, context: ["terminalApp": "Ghostty", "alpha": "1"]))
    let keys = ["alpha", "code", "detail", "kind", "schemaVersion", "terminalApp", "type"]
    let positions = try keys.map {
      try #require(line.range(of: "\"\($0)\"")?.lowerBound, "missing \($0): \(line)")
    }
    #expect(positions == positions.sorted(), "\(line)")
  }

  @Test func contextCanNeverOverwriteTheEnvelopeFields() throws {
    let line = ErrorEnvelope.line(
      for: Self.error(
        .busy, code: "runInProgress", context: ["code": "evil", "kind": "usage", "type": "ok"]))
    let envelope = try Self.object(line)
    #expect(envelope["code"] as? String == "runInProgress")
    #expect(envelope["kind"] as? String == "busy")
    #expect(envelope["type"] as? String == "error")
  }

  @Test func theEnvelopeIsTheLastLineAfterAnAbortedEventInNdjsonMode() throws {
    let error = SoundPingError.deviceChanged(
      "deviceGone", "device 'abc' disappeared during the run", context: ["uid": "abc"])
    let aborted = try NDJSONRenderer().line(for: .aborted(error))
    let report = ErrorReporting.report(for: error, jsonMode: true)
    let lines = [aborted, try #require(report.stdout)]

    #expect(try Self.object(lines[0])["type"] as? String == "aborted")
    let last = try Self.object(lines[1])
    #expect(last["type"] as? String == "error")
    #expect(last["code"] as? String == "deviceGone")
    #expect(report.exitCode == 75)
  }

  // MARK: human message

  @Test func plainModeKeepsStdoutEmptyAndExplainsOnStderr() {
    let error = Self.error(
      .usage, code: "invalidStorePath", detail: "the store root must be absolute",
      context: ["fix": "pass an absolute path"])
    let report = ErrorReporting.report(for: error, jsonMode: false)

    #expect(report.stdout == nil)
    #expect(
      report.stderr == [
        "error: invalidStorePath: the store root must be absolute", "fix: pass an absolute path",
      ])
    #expect(report.exitCode == 64)
  }

  @Test func plainModeWithoutAFixPrintsOneLine() {
    let report = ErrorReporting.report(
      for: Self.error(.busy, code: "runInProgress", detail: "another run holds the store"),
      jsonMode: false)
    #expect(report.stderr == ["error: runInProgress: another run holds the store"])
  }

  @Test func jsonModeAlsoExplainsOnStderr() {
    let report = ErrorReporting.report(
      for: Self.error(.busy, code: "runInProgress", detail: "another run holds the store"),
      jsonMode: true)
    #expect(report.stderr == ["error: runInProgress: another run holds the store"])
  }

  // MARK: gate

  @Test func theRequiredValidCountIsTheCeilingOfTheFraction() {
    #expect(RunGate.requiredValid(hits: 20, minValidFraction: 0.5) == 10)
    #expect(RunGate.requiredValid(hits: 21, minValidFraction: 0.5) == 11)
    #expect(RunGate.requiredValid(hits: 100, minValidFraction: 0.5) == 50)
    #expect(
      RunGate.requiredValid(hits: 10, minValidFraction: 0.3) == 3,
      "0.3 * 10 is 3.0000000000000004 in floating point")
  }

  private static func result(valid: Int, hits: Int = 20) -> RunResult {
    let stats = SummaryStats(
      n: hits, valid: valid,
      median: valid > 0 ? StatValue(frames: 412.37, ms: 8.591) : nil)
    return RunResult(
      runId: "20261112T120000Z-round-trip",
      runPath: "/tmp/soundping-store/runs/20261112T120000Z-round-trip",
      createdAt: Date(timeIntervalSince1970: 1_794_484_800),
      toolVersion: "test",
      os: "macOS test",
      recipe: RecipeRegistry.roundTrip.ref,
      label: nil,
      tags: [],
      parameters: RunParameters(hits: hits, seed: 7),
      setup: SetupSnapshot(
        setup: .simulatedDuplex, sampleRate: 48_000, outputBufferFrames: 128,
        inputBufferFrames: 128, simulated: true),
      measured: Measured(headline: .path, domain: .sample, path: stats),
      histogram: nil,
      hits: [],
      rejectedCounts: [:],
      segments: RecipeRegistry.roundTrip.segments,
      corrections: [],
      simulation: nil)
  }

  @Test func theGateFailsBelowTheThresholdAndPassesAtIt() throws {
    let failing = try #require(RunGate.check(Self.result(valid: 9)))
    #expect(failing.kind == .gate)
    #expect(failing.code == "tooFewValidHits")
    #expect(failing.context["valid"] == "9")
    #expect(failing.context["required"] == "10")
    #expect(failing.context["hits"] == "20")
    #expect(failing.context["runPath"] == "/tmp/soundping-store/runs/20261112T120000Z-round-trip")
    #expect(ExitCodes.code(for: failing.kind) == 3)

    #expect(RunGate.check(Self.result(valid: 10)) == nil, "exactly the threshold passes")
    #expect(RunGate.check(Self.result(valid: 20)) == nil)
  }

  @Test func aRunWithNoValidHitsFailsTheGate() throws {
    let failing = try #require(RunGate.check(Self.result(valid: 0)))
    #expect(failing.code == "tooFewValidHits")
    #expect(failing.context["valid"] == "0")
  }

  @Test func aRunWithoutStatisticsFailsTheGate() throws {
    var result = Self.result(valid: 0)
    result.measured.path = nil
    #expect(RunGate.check(result)?.code == "tooFewValidHits")
  }

  @Test func aFailureAfterThePrintedResultLeavesStdoutAlone() throws {
    let gate = try #require(RunGate.check(Self.result(valid: 9)))
    for jsonMode in [true, false] {
      let report = ErrorReporting.report(for: FailedAfterResult(error: gate), jsonMode: jsonMode)
      #expect(report.stdout == nil, "stdout holds the result and nothing else")
      #expect(report.exitCode == 3)
      #expect(report.stderr.first?.hasPrefix("error: tooFewValidHits:") == true)
    }
  }
}
