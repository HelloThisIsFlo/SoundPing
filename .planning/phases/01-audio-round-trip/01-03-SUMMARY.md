---
phase: 01-audio-round-trip
plan: 03
subsystem: cli-output
tags: [swift6, ndjson, pretty-output, exit-codes, error-envelope, no-color, swift-testing, argument-parser]

requires:
  - phase: 01-audio-round-trip/02
    provides: RunEvent/RunResult contract, RunCoordinator stream, withErrorReporting seam, OutputOptions, ci-sim.sh
  - phase: 01-audio-round-trip/04
    provides: Scenario.missedHits and --sim-miss (used to make hits fail at the normal latency)
  - phase: 01-audio-round-trip/10
    provides: RunLock (busy class), RunsCommand list/show
provides:
  - "--ndjson: the live RunEvent stream, one flushed JSON line per event, stdout data-only (exclusive with --json)"
  - "Default pretty output: live hit lines, summary block, Unicode-bar histogram, sparkline, NO_COLOR and non-TTY clean"
  - "Error envelope {schemaVersion, type:error, kind, code, detail, ...context} on stdout in data modes; error:/fix: lines on stderr"
  - "Exit codes 0 / 3 gate / 64 usage / 65 preflight / 70 internal / 73 busy / 75 device change"
  - "tooFewValidHits gate: result saved and printed, then exit 3"
  - "soundpingTests test target (@testable import of the executable), RunStreamTests, extended ci-sim.sh"
affects: [01-05, 01-07, 01-08, 01-09, phase-2 recipes, the native app]

plan_head_before: 231e19486818be34fa59173a29f51f0a9a0811db
plan_head_after: f9cfde9ccc4ee2a36aaaca425d606a9cb2718f4e
commits: 5

actuals:
  tokens: 11900
  tasks: 3
  commits: 5

tech-stack:
  added: []
  patterns:
    - "Renderers return Strings (PrettyRenderer) or lines (NDJSONRenderer) and the command prints them, so layout is unit-testable"
    - "ErrorReporting.report(for:jsonMode:) is a pure function returning stdout line, stderr lines and exit code; withErrorReporting only performs the I/O"
    - "FailedAfterResult wraps a failure that struck after stdout already holds the result, so the envelope is withheld and stdout stays one parseable object"
    - "Gate and failure cases in ci-sim.sh are driven by --sim-miss at the normal in-window latency, never by an out-of-window latency"

key-files:
  created:
    - Sources/soundping/Render/NDJSONRenderer.swift
    - Sources/soundping/Render/Output.swift
    - Sources/soundping/Render/PrettyRenderer.swift
    - Sources/soundping/Render/Terminal.swift
    - Sources/soundping/Render/ExitCodes.swift
    - Tests/SoundPingKitTests/RunStreamTests.swift
    - Tests/soundpingTests/PrettyRendererTests.swift
    - Tests/soundpingTests/ErrorReportingTests.swift
  modified:
    - Sources/soundping/Render/ErrorReporting.swift
    - Sources/soundping/Commands/OutputOptions.swift
    - Sources/soundping/Commands/RunCommand.swift
    - Package.swift
    - scripts/ci-sim.sh

key-decisions:
  - "A gate failure in --json/--ndjson mode puts no envelope on stdout: the saved result is already the one object (or the last finished line) there, and the cause travels on stderr plus exit 3. Other failures (before a result exists) print the envelope"
  - "Context keys are flattened into the envelope but can never overwrite schemaVersion, type, kind, code or detail"
  - "requiredValid uses ceil(fraction * hits - 1e-9) so 0.3 * 10 (3.0000000000000004) demands 3 hits, not 4"
  - "Pretty mode prints segment short names by id (Audio output, Cable or air, Audio input) because the recipe names are full sentences; unknown ids fall back to the recipe name"
  - "ArgumentParser ValidationError, ExitCode and CleanExit pass through withErrorReporting untouched, so parse errors keep ArgumentParser's own exit 64"
  - "Colour is dimming only (ESC[2m ... ESC[0m on rejected lines); TERM=dumb also disables it"

patterns-established:
  - "RED stubs for a new executable-target type are compile-only (empty strings, nil, zero) so the target fails on its assertion"
  - "swift-testing RED evidence is classified with SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1; tests index only after #require so a crash never replaces a failure"

requirements-completed: [ENG-02, RES-01]

coverage:
  - id: D1
    description: "`--ndjson` streams armed first, one hit/rejected line per hit in strictly increasing index order, finished last; nothing else on stdout; finished line equals run.json"
    requirement: ENG-02
    verification:
      - kind: other
        ref: "bash scripts/ci-sim.sh (ndjson block) -> ci-sim: OK"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/RunStreamTests.swift (aNormalRunIsArmedThenOneLinePerHitThenFinished)"
        status: pass
    human_judgment: false
  - id: D2
    description: "ENG-02 adjacency and empty cases: a hit and an adjacent rejected hit are two lines in order; a run where every hit is rejected still emits armed, 25 rejected lines and finished, with valid 0 and no median"
    requirement: ENG-02
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/RunStreamTests.swift#aHitAndAnAdjacentRejectedHitAreTwoSeparateEventsInOrder"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/RunStreamTests.swift#everyHitRejectedStillEmitsArmedRejectedLinesAndFinished"
        status: pass
    human_judgment: false
  - id: D3
    description: "Pretty output: hit lines with frames/ms/confidence, dimmed rejected lines with reason, summary (valid/N, median, jitter p5-p95, p95, max), histogram bars capped at 40 columns, sparkline, valid 0 prints 'no valid hits'; NO_COLOR or a non-TTY gives zero ESC bytes"
    requirement: RES-01
    verification:
      - kind: unit
        ref: "Tests/soundpingTests/PrettyRendererTests.swift (13 cases)"
        status: pass
      - kind: other
        ref: "Task 2 automated verify -> PRETTY-OK (NO_COLOR piped run: no ESC byte, 'valid 20/20')"
        status: pass
    human_judgment: false
  - id: D4
    description: "Readability of the live TTY output (hit lines landing, bar and sparkline legibility, dimming) as Flo sees it in a real terminal"
    requirement: RES-01
    verification: []
    human_judgment: true
    rationale: "Layout taste and live pacing are judged by a person at a terminal; tests pin content, escape bytes and bar proportions, not how it feels"
  - id: D5
    description: "Every failure class has its own exit code and a single JSON envelope on stdout in --json; stderr carries the human message; invalidStorePath and unknownRecipe exit 64, runInProgress exits 73"
    requirement: ENG-02
    verification:
      - kind: unit
        ref: "Tests/soundpingTests/ErrorReportingTests.swift (16 cases)"
        status: pass
      - kind: other
        ref: "bash scripts/ci-sim.sh (expect_failure block) -> ci-sim: OK"
        status: pass
    human_judgment: false
  - id: D6
    description: "Gate boundary pinned: at 20 hits, valid 0 and valid 9 exit 3 with tooFewValidHits and a saved result; valid 10 exits 0"
    requirement: RES-01
    verification:
      - kind: other
        ref: "bash scripts/ci-sim.sh (gate_run none / nine / ten) -> ci-sim: OK"
        status: pass
      - kind: unit
        ref: "Tests/soundpingTests/ErrorReportingTests.swift#theGateFailsBelowTheThresholdAndPassesAtIt"
        status: pass
    human_judgment: false

duration: 25min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 03: Live output, pretty summary and named failures Summary

**`soundping run` now streams every RunEvent as flushed NDJSON, prints a speed-test-style pretty report (live hit lines, summary, 40-column histogram, sparkline, clean under NO_COLOR), and ends every failure as one JSON envelope plus a per-class exit code (64/65/70/73/75, gate 3), with the too-few-valid-hits boundary pinned in CI.**

## Performance

- **Duration:** ~25 min
- **Completed:** 2026-11-12
- **Tasks:** 3 (1 tracer, 2 TDD)
- **Files:** 13 (8 created, 5 modified)
- **Commits:** 5 task commits

## Accomplishments

- **Watch a run live, two ways.** `--ndjson` writes `armed`, one `hit`/`rejected` line per hit, then `finished` (27 lines for a 20-hit run), each flushed as it happens; `--json` plus `--ndjson` is a usage error (exit 64). In both data modes progress goes to stderr, and only when stderr is a TTY.
- **Speed-test summary for people.** Pretty mode prints `#007  measure  412.37 frames  8.591 ms  conf 0.93` per hit (rejected hits dimmed as `rejected: lowConfidence`), then valid/N with a rejection breakdown, median, jitter (p5-p95), p95, max in frames and ms, the segments, corrections, the saved path, a histogram and a timeline. A run with no valid hits says `no valid hits: nothing to report` and prints no zeros.
- **Failures an agent can branch on.** `{"code":"invalidStorePath","detail":...,"kind":"usage","path":...,"schemaVersion":1,"type":"error"}` on stdout, `error: <code>: <detail>` (and `fix:`) on stderr, exit 64. Distinct codes per class: 64 usage, 65 preflight, 75 device change, 3 gate, 73 busy, 70 internal.
- **The gate cannot be mistaken for success.** A completed run with fewer than `ceil(minValidFraction x hits)` valid hits is saved and printed, then exits 3 with `tooFewValidHits`. ci-sim pins valid 0 and valid 9 at exit 3 and valid 10 at exit 0, driven by `--sim-miss` at the normal latency.

## Task Commits

1. **Task 1: --ndjson live stream (tracer)** - `efd718e` (feat)
2. **Task 2 RED: failing PrettyRendererTests + soundpingTests target** - `6259aaf` (test)
3. **Task 2 GREEN: pretty renderer, Terminal** - `8c035a6` (feat)
4. **Task 3 RED: failing ErrorReportingTests** - `4f993c3` (test)
5. **Task 3 GREEN: envelope, exit codes, gate** - `f9cfde9` (feat)

**Plan metadata:** committed after this file (docs: complete plan)

Tracer feedback gate: the tracer `<verify>` is automated-only (`workflow.human_verify_mode` is `end-of-phase`); `RunStreamTests` and `ci-sim.sh` were re-run end to end after the tracer commit and passed, so expansion continued without a checkpoint.

## TDD

- **Task 2 RED:** `PrettyRendererTests` (13 cases) written first against compile-only `PrettyRenderer`/`Terminal` stubs. Command: `SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 swift test --filter PrettyRendererTests`. Target `theSummaryShowsEveryStatisticInFramesAndMilliseconds()` failed on `summary.contains("valid 98/100")` (the stub returned an empty string). Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, 13 tests, 13 failing, swift-testing). Semantic assessment: the target executed and failed on the planned content assertions; all 13 fail because every renderer method is a stub, which is the expected shape for a new type. A first RED run crashed (`Index out of range` from test indexing into an empty string); the tests were fixed to index only after `#require`, and the RED was re-run to a complete report before classifying.
- **Task 2 GREEN:** all 13 pass. One test fix in GREEN: stat lines are found by `hasPrefix(label)` because the jitter line also contains `p95` (`p5–p95`); the assertions are unchanged.
- **Task 3 RED:** `ErrorReportingTests` (16 cases) against compile-only `ExitCodes.code(for:)`, `ErrorEnvelope`, `ErrorReporting`, `RunGate` stubs. Target `theGateFailsBelowTheThresholdAndPassesAtIt()` failed on the planned gate assertions (stub returned nil). Verdict `RED_EVIDENCE_OK` (16 tests, 15 failing, 1 passing by coincidence with the stub). Semantic assessment: the target ran and failed on `RunGate.check` returning nil instead of a `tooFewValidHits` gate error; the other failures are the stubbed envelope, report and mapping, all planned behaviour.
- **Task 3 GREEN:** all 16 pass; `ci-sim.sh` failure and gate blocks pass.
- **REFACTOR:** none.
- Gate order in history: RED `6259aaf` before GREEN `8c035a6`; RED `4f993c3` before GREEN `f9cfde9`. Task 1 is a tracer with characterization tests (`RunStreamTests` passed at once, by design).

## Files Created/Modified

- `Sources/soundping/Render/NDJSONRenderer.swift` - RunEvent to one line (lineEncoder), written flushed
- `Sources/soundping/Render/Output.swift` - flushed stdout lines, stderr lines, TTY-only progress
- `Sources/soundping/Render/PrettyRenderer.swift` - hit lines, summary, histogram bars, sparkline, report
- `Sources/soundping/Render/Terminal.swift` - colour decision (TTY, NO_COLOR, TERM=dumb)
- `Sources/soundping/Render/ExitCodes.swift` - Kind to exit code
- `Sources/soundping/Render/ErrorReporting.swift` - envelope, report, RunGate, `withErrorReporting`
- `Sources/soundping/Commands/OutputOptions.swift` - `--ndjson`, exclusive with `--json`
- `Sources/soundping/Commands/RunCommand.swift` - per-event rendering by mode, gate after finished
- `Package.swift` - `soundpingTests` target
- `scripts/ci-sim.sh` - ndjson block, named-failure block, gate block (final line stays `ci-sim: OK`)
- `Tests/SoundPingKitTests/RunStreamTests.swift`, `Tests/soundpingTests/{PrettyRendererTests,ErrorReportingTests}.swift`

## Decisions Made

See `key-decisions`. One worth a second look: **a gate failure prints no envelope on stdout** in `--json` mode. The plan says the failure is "a single JSON envelope on stdout" for every class and, for the gate, that "stdout is that run's RunResult". Both cannot hold at once on one stdout; the result wins (it is the object an agent needs) and the cause is on stderr plus exit 3 plus `error: tooFewValidHits` with `valid`, `hits`, `required` and `runPath`. If an agent wants the cause as JSON, it can recompute it from `measured.path.valid` and `parameters`.

## Deviations from Plan

### Auto-fixed / additive

**1. [Rule 3 - Blocking] RED stubs in the production tree**
- **Found during:** Task 2 and Task 3 RED
- **Issue:** a test referencing `PrettyRenderer`, `Terminal`, `ErrorEnvelope`, `RunGate` fails to build before they exist, which is INVALID_RED, not RED.
- **Fix:** the RED commits carry compile-only stubs; GREEN replaces them. Same approach as plan 01-10.
- **Files modified:** `PrettyRenderer.swift`, `Terminal.swift`, `ExitCodes.swift`, `ErrorReporting.swift`
- **Commits:** `6259aaf`, `4f993c3`

**2. [Rule 1 - Test bug] Stat-line lookup matched the wrong line**
- **Found during:** Task 2 GREEN
- **Issue:** `first { $0.contains("p95") }` returned the jitter line (it names `p5–p95`).
- **Fix:** look lines up by prefix. Assertions unchanged.
- **Files modified:** `Tests/soundpingTests/PrettyRendererTests.swift`
- **Commit:** `8c035a6`

**3. [Plan shorthand] RunsCommand not modified**
- `RunsCommand` bodies were already wrapped in `withErrorReporting` by plan 01-10, so upgrading the internals of `withErrorReporting` gave `runs list|show` the envelope and exit codes with no edit (checked: `runs show nonexistent --json` prints `unreadableRun` and exits 64).

**4. [Plan shorthand] Gate envelope** (see Decisions Made).

**Total deviations:** 4 (1 blocking-gap stub, 1 test bug, 2 plan-shorthand notes). **Impact:** none on the plan's goals.

## Issues Encountered

- **Armed event run id (carried from 01-10).** The coordinator predicts the `armed` event's `runId` before the run folder exists, so a second run started in the same second as another streams an `armed` id without the `-2` suffix, while the final `run.json` and the `finished` event carry the real one. `NDJSONRenderer` and the pretty `armedLine` print events as received. The pretty armed line deliberately omits the run id; the NDJSON `armed` line includes it. A consumer that needs the id should read it from `finished.result.runId`. `RunCoordinator.swift` is outside this plan's files; the clean fix (create the folder before emitting `armed`) belongs to a plan that owns the coordinator.
- **Plan-head ledger.** The sandbox refused git plumbing inside the shared `.git` directory (same as plan 01-10), so `gsd-plan-head-before-01-03` could not be written. `plan_head_before` is the dispatch base `231e194` and `commits` is measured from it with `git rev-list --count`.
- zsh `multios` makes `2>&1 >/dev/null` duplicate stdout into the pipe; the stderr-is-empty check was redone under `bash -c` (0 bytes on stderr for a piped `--ndjson` run).

## Known Stubs

None.

## Threat Flags

None. T-01-11 (stdout in JSON modes) is mitigated: stdout carries data only, and ci-sim parses every ndjson line and the single `--json` object or envelope. T-01-13 (agent misreads failure as success) is mitigated by distinct non-zero codes and the pinned gate boundary (valid 9 exits 3, valid 10 exits 0). T-01-12 accepted as planned. T-01-SC: no new packages; the only `Package.swift` change is a local test target.

## User Setup Required

None.

## Next Phase Readiness

- Plan 01-05 (parallel, wave 4) can add commands inside `withErrorReporting` and get the envelope and exit codes for free; `ExitCodes.code(for:)` is the single mapping.
- Plan 01-08 inserts `probe` and `levelLocked` events before `armed`; update the "armed first" assertions in `RunStreamTests`, the ndjson block of `ci-sim.sh` (it asserts 27 events and `armed` first) and `PrettyRenderer`/`RunCommand`, which currently switch only over `armed`, `hit`, `rejected`, `aborted`, `finished` (new cases need a branch or `default`).
- Preflight errors (kind `preflight`, exit 65) already map; plan 01-08 only needs to throw them.
- Real-terminal look of the pretty output is judged by Flo (coverage D4); `just sim` shows it.

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*

## Self-Check: PASSED

Files present: `NDJSONRenderer.swift`, `Output.swift`, `PrettyRenderer.swift`, `Terminal.swift`, `ExitCodes.swift`, `ErrorReporting.swift`, `OutputOptions.swift`, `RunCommand.swift`, `RunStreamTests.swift`, `PrettyRendererTests.swift`, `ErrorReportingTests.swift`, `scripts/ci-sim.sh`, `Package.swift`. Commits `efd718e`, `6259aaf`, `8c035a6`, `4f993c3`, `f9cfde9` are ancestors of HEAD. Gates: `Suite RunStreamTests passed`, `Suite PrettyRendererTests passed`, `Suite ErrorReportingTests passed`, `PRETTY-OK`, full `swift test` (55 tests in 9 suites) green, `scripts/ci-sim.sh` ends `ci-sim: OK`; acceptance greps (`missedHits` in RunStreamTests, `--sim-miss` in ci-sim.sh, the six exit-code values in ExitCodes.swift) hold.
