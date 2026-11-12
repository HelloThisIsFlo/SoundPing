---
phase: 01-audio-round-trip
plan: 02
subsystem: engine
tags: [swift6, coreaudio-free-engine, simulated-backend, matched-filter, vdsp, run-store, argument-parser, swift-testing]

requires:
  - phase: 01-audio-round-trip/01
    provides: SwiftPM scaffold, justfile/scripts orchestration, macos-26 CI
provides:
  - RunEvent/RunResult Codable contract (type discriminator, schemaVersion 1)
  - RunCoordinator.run(_:) -> AsyncThrowingStream<RunEvent, Error> over an AudioBackend protocol
  - SimulatedBackend (virtual time, analytic sub-sample rendering), Scenario, seeded SplitMix64
  - Chirp template, vDSP matched-filter Correlator, type-7 Stats and Histogram
  - HitScheduler (seeded spacing, warm-ups, arm-time validate)
  - StorePaths and RunStore (atomic run.json under <store>/runs/<stamp>-<recipe id>)
  - soundping run <recipe> with RunOptions / SimulationOptions / OutputOptions, withErrorReporting seam
  - scripts/ci-sim.sh in scripts/test.sh and CI, just sim recipe
affects: [01-03, 01-04, 01-05, 01-06, 01-07, 01-08, 01-09, 01-10, all later phases]

plan_head_before: a2fe9a29a5475dc20c0d289e3821b71ac333839a
plan_head_after: 7cc12a890aa8b627462d12d7f77b71119ce5ba48

actuals:
  tokens: 16700
  tasks: 2
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Hand-written Codable with a `type` discriminator; payloads flattened beside it (verified flat with JSONEncoder)"
    - "Coordinator waits on sample positions via waitUntilCaptured, never the wall clock"
    - "Supervised TaskGroup: a measuring child plus a device-event child; the first fault cancels the run"
    - "OptionGroup per concern (run, simulation, output) so parallel plans edit separate files"
    - "--json prints RunStore.encodedBytes(for:), the same function run.json is written with"

key-files:
  created:
    - Sources/SoundPingKit/Engine/RunModel.swift
    - Sources/SoundPingKit/Engine/RunRequest.swift
    - Sources/SoundPingKit/Engine/SoundPingError.swift
    - Sources/SoundPingKit/Engine/RunCoordinator.swift
    - Sources/SoundPingKit/Engine/HitScheduler.swift
    - Sources/SoundPingKit/Recipes/Recipe.swift
    - Sources/SoundPingKit/Audio/AudioBackend.swift
    - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
    - Sources/SoundPingKit/Stimulus/Stimulus.swift
    - Sources/SoundPingKit/Detection/Correlator.swift
    - Sources/SoundPingKit/Stats/Stats.swift
    - Sources/SoundPingKit/Store/StorePaths.swift
    - Sources/SoundPingKit/Store/RunStore.swift
    - Sources/soundping/Commands/RunCommand.swift
    - Sources/soundping/Commands/RunOptions.swift
    - Sources/soundping/Commands/SimulationOptions.swift
    - Sources/soundping/Commands/OutputOptions.swift
    - Sources/soundping/Render/JSONRenderer.swift
    - Sources/soundping/Render/ErrorReporting.swift
    - scripts/ci-sim.sh
    - Tests/SoundPingKitTests/SimulationRecoveryTests.swift
  modified:
    - Sources/soundping/SoundPing.swift
    - scripts/test.sh
    - justfile
    - .github/workflows/ci.yml

key-decisions:
  - "BackendInfo gained an optional `simulation: Scenario?` (default nil) so run.json records the scenario without the coordinator downcasting; HALBackend can keep calling BackendInfo(sampleRate:bufferFrames:)"
  - "Templates reach AudioBackend.open at a nominal 48 kHz; a backend regenerates them at its real rate with StimulusTemplate.atSampleRate(_:) and reports that rate in BackendInfo"
  - "waitUntilCaptured(throughInputFrame:) takes an exclusive bound: every frame below it is captured on return"
  - "A missing --seed draws a random UInt64 below 2^53, so the recorded seed survives a JavaScript JSON round trip"
  - "RunStore.createRunFolder refuses an existing folder instead of overwriting; plan 01-10 adds the collision suffix"
  - "rejectedCounts counts measure-phase rejections only; warm-up rejections stay visible in hits[]"

patterns-established:
  - "Command-level `mutating func validate()` pins the random seed once after parsing (mutations persist in ArgumentParser 1.8.2)"
  - "RED evidence for swift test needs SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 so the classifier can read the swift-testing report"

requirements-completed: [ENG-05, ENG-02, ENG-04, ENG-06, RUN-01, RES-01]

coverage:
  - id: D1
    description: "`soundping run round-trip --simulate --sim-latency 412.37 --sim-jitter 0 --seed 7 --json` recovers the injected latency within 0.1 frame, valid 100/100, stdout byte-identical to run.json"
    requirement: ENG-05
    verification:
      - kind: other
        ref: "bash scripts/ci-sim.sh -> ci-sim: OK"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/SimulationRecoveryTests.swift#recoversInjectedLatencyAndExcludesWarmups"
        status: pass
    human_judgment: false
  - id: D2
    description: "Seeded uniform spacing in [450, 750] ms, 5 default warm-ups in hits[] excluded from every statistic, default N 100, same seed gives the same schedule"
    requirement: ENG-04
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/SimulationRecoveryTests.swift#recoversInjectedLatencyAndExcludesWarmups"
        status: pass
      - kind: other
        ref: "two runs with --seed 5 produce identical outputFrame lists"
        status: pass
    human_judgment: false
  - id: D3
    description: "Jitter is reported as p95 - p5 and tracks the injected Gaussian spread (3.29 sigma within 10 percent); a 105-hit simulated run finishes in under 2 s"
    requirement: RES-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/SimulationRecoveryTests.swift#jitterTracksTheInjectedSpread"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/SimulationRecoveryTests.swift#aFullRunFinishesFast"
        status: pass
    human_judgment: false
  - id: D4
    description: "Every result lists its segments in signal-flow order, separately, with `corrections: []` always encoded; run.json carries schemaVersion, recipe, date, setup and parameters"
    requirement: ENG-06
    verification:
      - kind: other
        ref: "scripts/ci-sim.sh asserts segment ids [audioOutput, transmission, audioInput], corrections == [], schemaVersion 1"
        status: pass
    human_judgment: false
  - id: D5
    description: "Arm-time refusal of spacing below maxLatency + stimulus + 50 ms (spacingTooShort) and out-of-range hits/warmup (invalidParameters); defaults pass the guard"
    requirement: ENG-04
    verification:
      - kind: other
        ref: "soundping run round-trip --simulate --hits 0 -> error: invalidParameters, exit 1; defaults run clean"
        status: pass
    human_judgment: true
    rationale: "spacingTooShort itself is not asserted by any committed test yet; plan 01-10's SchedulerTests pins validate() directly"
  - id: D6
    description: "A device-change event aborts the run: `aborted` event, stream throws the deviceChanged error, backend stopped; audio-thread overloads reject the hit as discontinuity"
    requirement: ENG-02
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/SimulationRecoveryTests.swift#aVanishedDeviceAbortsTheRun"
        status: pass
    human_judgment: true
    rationale: "The overload-to-discontinuity path is implemented but no committed test exercises it; plan 01-07 injects overload faults through Scenario"
  - id: D7
    description: "Shared flag groups, error seam (`error: <code>: <detail>`, exit 1) and `soundping run` without --simulate refused with hardwareBackendUnavailable"
    requirement: RUN-01
    verification:
      - kind: other
        ref: "NOHW-OK gate and manual unknownRecipe / invalidStorePath / unknownTemplate runs"
        status: pass
    human_judgment: false
  - id: D8
    description: "GitHub Actions runs scripts/ci-sim.sh after swift test on macos-26"
    requirement: ENG-05
    verification:
      - kind: other
        ref: "WIRING-OK grep gate on ci.yml and scripts/test.sh; just test green locally"
        status: pass
    human_judgment: true
    rationale: "The workflow has not run on GitHub; a green macos-26 (Xcode 26.6) run is only provable after a push"

duration: 15min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 02: Walking skeleton Summary

**`soundping run round-trip --simulate --json` goes CLI -> RunCoordinator -> virtual-time simulated backend -> chirp matched filter -> stats -> run store and returns the injected 412.37-frame latency, saved as an atomic run.json whose bytes equal the printed JSON, with CI running it on every push.**

## Performance

- **Duration:** ~15 min
- **Completed:** 2026-11-12
- **Tasks:** 2 (tracer + TDD expansion)
- **Files modified:** 25 (21 created, 4 modified)
- **Commits:** 3

## Accomplishments

- The Codable contract later plans consume exists with the names from `<interfaces>`: `RunEvent` (flat `type` discriminator, round-trips through `JSONEncoder` for bare and nested use), `RunResult` (schemaVersion 1), `HitRecord`, `SummaryStats`, `Histogram`, `SetupSnapshot`, `SoundPingError`.
- Sub-sample accuracy on the default scenario: median 412.26 frames at jitter 0.5, 412.37 +- 0.1 at jitter 0 (ci-sim asserts it); whole 100-hit run in about 2.6 s including a debug build check, 0.3 s in the test.
- 105 hits (5 warm-ups plus 100 measured) draw gaps uniformly from [450, 750] ms with SplitMix64; identical seeds give identical `outputFrame` lists.
- `--json` stdout and run.json are the same bytes by construction (`RunStore.encodedBytes(for:)`), and `cmp` in ci-sim proves it.
- Device-event handling: a `TaskGroup` supervises the measuring child and a listener child; a `gone`/rate/buffer/stream/ioStopped event emits `aborted` and throws a `deviceChanged` error while the backend is still stopped on every path.

## Task Commits

1. **Task 1: Walking skeleton (tracer)** - `a1a4fe9` (feat)
2. **Task 2 RED: failing SimulationRecoveryTests** - `c209b67` (test)
3. **Task 2 GREEN: seeded spacing, warm-ups, aborts, flag groups, CI** - `7cc12a8` (feat)

**Plan metadata:** committed after this file (docs: complete plan)

Tracer feedback gate: the tracer `<verify>` carried only `<automated>` checks; re-run end-to-end after the tracer commit and passed (`ci-sim: OK`), so expansion continued without a checkpoint.

## TDD

- **RED:** `SimulationRecoveryTests` written against the tracer API. Target `recoversInjectedLatencyAndExcludesWarmups()` failed on `warmups.count == 5` (actual 0) and `result.hits.count == 105` (actual 100). Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, 4 tests, 3 failing, format swift-testing). Command: `SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 swift test --filter SimulationRecoveryTests`. Semantic assessment: the target ran and failed on the planned warm-up assertions while the earlier median and valid-count assertions in the same test passed, so the failure is the missing HitScheduler, not a build or fixture fault. The device-abort case failed for the right reason (events not consumed); the jitter case already passed against the tracer, as expected.
- **GREEN:** HitScheduler plus the supervised coordinator; all four cases pass (suite 1.0 s).
- **REFACTOR:** none needed.
- RED commit `c209b67` precedes GREEN `7cc12a8`; the tracer commit `a1a4fe9` is the pre-existing baseline the RED test ran against.

## Files Created/Modified

Engine: `Engine/{RunModel,RunRequest,SoundPingError,RunCoordinator,HitScheduler}.swift`, `Recipes/Recipe.swift`, `Audio/AudioBackend.swift`, `Simulation/SimulatedBackend.swift`, `Stimulus/Stimulus.swift`, `Detection/Correlator.swift`, `Stats/Stats.swift`, `Store/{StorePaths,RunStore}.swift`. CLI: `Commands/{RunCommand,RunOptions,SimulationOptions,OutputOptions}.swift`, `Render/{JSONRenderer,ErrorReporting}.swift`, `SoundPing.swift`. Tooling: `scripts/ci-sim.sh`, `scripts/test.sh`, `justfile`, `.github/workflows/ci.yml`. Tests: `Tests/SoundPingKitTests/SimulationRecoveryTests.swift`.

## Decisions Made

See `key-decisions` above. Two worth repeating for the parallel plans:

- **RunOptions signatures differ slightly from the shorthand in plans 01-05/01-10.** Actual: `makeStore() throws -> RunStore`, `makeBackend(simulation:) throws -> (backend, setup)`, `makeRequest(recipe:setup:) throws -> RunRequest`, plus `mutating func pinSeed()` called from `RunCommand.validate()`. The setup comes from `makeBackend` because the simulated duplex setup lives there.
- **runId** is the run folder name, predicted from `createdAt` for the `armed` event and confirmed from the created folder; they match because a duplicate folder is refused.

## Deviations from Plan

### Auto-fixed / additive

**1. [Rule 2 - Missing critical] Fourth test case `aVanishedDeviceAbortsTheRun`**
- **Found during:** Task 2 RED
- **Issue:** The plan's `<behavior>` lists three cases, but the device-event abort is a core Task 2 requirement and would otherwise ship untested.
- **Fix:** Added a test using a wrapper backend that reports `gone` after the first capture, then hangs like a vanished device until cancelled. Deterministic, no wall-clock race.
- **Files modified:** `Tests/SoundPingKitTests/SimulationRecoveryTests.swift`
- **Commit:** `c209b67`

**2. [Rule 3 - Blocking interface gap] `BackendInfo.simulation` and template regeneration**
- **Found during:** Task 1
- **Issue:** `AudioBackend.open` takes templates before the sample rate is known, and `RunResult.simulation` needs the scenario, but the listed `BackendInfo` has only two fields.
- **Fix:** `BackendInfo` gained an optional `simulation: Scenario?` defaulting to nil; `StimulusTemplate.atSampleRate(_:)` regenerates templates at the device rate. Source-compatible for `BackendInfo(sampleRate:bufferFrames:)` callers.
- **Files modified:** `Audio/AudioBackend.swift`, `Stimulus/Stimulus.swift`, `Simulation/SimulatedBackend.swift`
- **Commit:** `a1a4fe9`

**3. [Plan shorthand] RunOptions method signatures** (see Decisions Made). No behaviour change.

**Total deviations:** 3 (1 added test, 1 interface-compatible field, 1 signature shorthand). **Impact:** none on the plan's goals; later plans read the real signatures from the code.

## Issues Encountered

- `swift test` prints SF Symbols glyphs the RED-evidence classifier does not read; `SWT_SF_SYMBOLS_ENABLED=0` fixed it. Worth carrying into later TDD plans.
- Running the CLI twice in the same second against the same store fails with `runFolderUnavailable` (deliberate no-overwrite). Plan 01-10 adds collision suffixes.

## Known Stubs

- `Correlator.detect` returns `psr: nil` and ignores `stamps`: placeholders by design, resolved by plan 01-04 (PSR, first-peak, clipping, discontinuity from stamps). Not recorded in `.planning/WINDOWS.md` to avoid a cross-worktree merge conflict on a shared file; the orchestrator can add it.
- `levelDbfs` is nil by default and uses the recipe start level until plan 01-08 adds the D-14 ramp.
- Hardware runs are refused with `hardwareBackendUnavailable` until plan 01-07.

## Threat Flags

None. The only new surface is the store filesystem write already covered by T-01-07 (atomic write), T-01-08 (absolute-root refusal) and T-01-10 (hits 1...10000, warmup 0...100, spacingTooShort); no audio is written to disk and nothing leaves the machine. T-01-SC: no new packages.

## User Setup Required

None.

## Next Phase Readiness

- Wave 3 (plans 01-04, 01-10) can build on the frozen contract; wave 4 (01-03, 01-05) follows.
- Confirm the first macos-26 CI run is green after Flo pushes (`gh run list --limit 1`); the Xcode 26.6 toolchain is older than the local Swift 6.4.2 and the only unverified surface is `Mutex`/Swift Testing behaviour on it.

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*

## Self-Check: PASSED

All 25 files present; commits a1a4fe9, c209b67 and 7cc12a8 are ancestors of HEAD; verify gates TRACER-OK, SUITE-OK (`Suite SimulationRecoveryTests passed`), WIRING-OK and NOHW-OK pass; `just test` green.
