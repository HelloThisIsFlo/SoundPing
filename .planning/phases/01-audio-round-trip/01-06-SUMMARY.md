---
phase: 01-audio-round-trip
plan: 06
subsystem: clock-and-measurement
tags: [swift6, host-clock, mach-timebase, device-timeline, least-squares, clock-selftest, calibration, two-device, swift-testing]

requires:
  - phase: 01-audio-round-trip/02
    provides: RunCoordinator, AudioBackend, SimulatedBackend, RunModel, RunStore, StorePaths (clock-selftest.json and calibrations.json paths)
  - phase: 01-audio-round-trip/03
    provides: withErrorReporting seam, named exit codes, RunGate, PrettyRenderer
  - phase: 01-audio-round-trip/05
    provides: SimulatedCatalog fixtures, ReportedLatency.compute, SetupResolver, run flag groups
provides:
  - "HostClock (Double tick/ns conversion on any mach timebase), TimelinePoint, StampLog, DeviceTimeline (local least squares over +-16 callbacks, rateScalar fallback, both directions of the mapping)"
  - "ClockSelfTest.evaluate/verdict/hostPathFrames: one shared function behind the in-run self-test and `soundping selftest clock`; pass at |median delta| <= 1 and p95 |delta| <= 2 frames, inclusive"
  - "RunEvent.selfTest, RunResult.selfTest/hostTimebase/reported/calibration, clock-selftest.json (ClockSelfTestStore), calibrations.json (CalibrationStore, CalibrationKey, CalibrationKind with roundTrip only)"
  - "Same-device figures: path (sample domain), ioOffset (measured per callback), appRoundTrip = path + median ioOffset, headline appRoundTrip; two-device figures: host-path only"
  - "soundping selftest clock; --sim-drift-ppm and --sim-stamp-bias; AudioBackend.stampLog/halHostTime/currentInputFrame; two-device simulation"
affects: [01-07, 01-08, 01-09, phase-02-midi]

plan_head_before: 5ee96637071f3adcc0404a9f07d11b4e47e26037
plan_head_after: 196e3c2ed88b38387e2b7e8de6adc9f45d496966

actuals:
  tokens: 26800
  tasks: 3
  commits: 5

tech-stack:
  added: []
  patterns:
    - "Host times are subtracted as integers or relative to a base before they become Double, so a tick value above 2^50 costs no precision"
    - "The same engine function (ClockSelfTest) serves the automatic in-run check and the explicit CLI gate; the CLI only turns its verdict into an exit code"
    - "Every JSON side file shares one VersionedFile loader: missing is empty, another schemaVersion or malformed JSON is a usage error naming the file, writes are atomic"
    - "Stores are pre-flighted at run start, so an unreadable side file fails the run before any audio instead of after it"
    - "The simulator stamps every callback from one virtual host clock, with per-device label origins and drift, so clock behaviour is testable without hardware"

key-files:
  created:
    - Sources/SoundPingKit/Clock/HostClock.swift
    - Sources/SoundPingKit/Clock/DeviceTimeline.swift
    - Sources/SoundPingKit/Clock/ClockSelfTest.swift
    - Sources/SoundPingKit/Store/ClockSelfTestStore.swift
    - Sources/SoundPingKit/Store/CalibrationStore.swift
    - Sources/soundping/Commands/SelftestCommand.swift
    - Tests/SoundPingKitTests/ClockTests.swift
    - Tests/SoundPingKitTests/MeasuredFiguresTests.swift
    - Tests/SoundPingKitTests/CalibrationStoreTests.swift
    - Tests/soundpingTests/ReportedBlockTests.swift
  modified:
    - Sources/SoundPingKit/Audio/AudioBackend.swift
    - Sources/SoundPingKit/Engine/RunCoordinator.swift
    - Sources/SoundPingKit/Engine/RunModel.swift
    - Sources/SoundPingKit/Engine/RunRequest.swift
    - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
    - Sources/SoundPingKit/Store/RunStore.swift
    - Sources/soundping/Commands/SimulationOptions.swift
    - Sources/soundping/Commands/RunCommand.swift
    - Sources/soundping/Render/PrettyRenderer.swift
    - Sources/soundping/Render/ErrorReporting.swift
    - Sources/soundping/SoundPing.swift
    - scripts/ci-sim.sh
    - Tests/SoundPingKitTests/RunStreamTests.swift
    - Tests/SoundPingKitTests/SimulationRecoveryTests.swift

key-decisions:
  - "Failing `selftest clock` throws a plain gate error (clockSelfTestFailed, exit 3) so --json prints the standard one-line error envelope on stdout; the numbers travel as envelope context keys. A pass prints the SelfTestReport. The run is saved either way"
  - "Two-device runs find each hit's input window by mapping H_out(output frame) through the input timeline, with a 5 ms pre-roll, then measure the hit as H_in(found sample) - H_out(output frame) in frames at the nominal rate; the timelines are refitted from the stamp log after every hit"
  - "AudioBackend gained currentInputFrame() (not in the plan): a two-device run must wait a stretch of callbacks (40, the fit needs 33) before the first hit, and cannot know the input device's labels without asking"
  - "BackendInfo gained hostClock (the simulator pins Apple Silicon's 125/3 so results are machine-independent), outputDevice and inputDevice (what the HAL reports; nil when unknown)"
  - "The run folder is created before `armed` is emitted, so the streamed run id is the final one with its -2 suffix; a run that dies before run.json takes its empty folder along (fixes the 01-10/01-03 carry-forward note)"
  - "The valid-hit rule lives once in RunParameters.requiredValidHits; RunGate.requiredValid and the calibration writer both use it"
  - "RunStore.list and the runs table show the headline median, which is now the app round trip for same-device runs"
  - "Reported latencies are display-only: corrections stay [], calibrations are never subtracted, and CalibrationKind has no mic-delay case (T-01-20, pinned by tests)"

patterns-established:
  - "RED commits for a plan with an existing API surface carry compile-only stubs (empty store functions, never-set result fields), so the target test fails on its assertion"
  - "Timing assertions in the test suite must tolerate a CPU-saturated parallel `swift test`"

requirements-completed: [CAL-03, CAL-02, RES-02, ENG-06]

coverage:
  - id: D1
    description: "Every same-device round-trip run computes the host-clock self-test through the generic per-direction timelines, reports median delta and p95 |delta|, emits a selfTest event before finished and refreshes clock-selftest.json keyed by device UID, sample rate and buffer"
    requirement: CAL-03
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/ClockTests.swift#aSimulatedSameDeviceRunPassesItsOwnSelfTest, aRunWritesTheStatusKeyedByDeviceRateAndBuffer, theSelfTestEventEncodesFlatWithItsTypeKey"
        status: pass
      - kind: other
        ref: "bash scripts/ci-sim.sh: ndjson stream ends armed, 25 hits, selfTest, finished; clock-selftest.json entry for soundping-sim-duplex / 48000 / 128"
        status: pass
    human_judgment: false
  - id: D2
    description: "`soundping selftest clock` runs the same engine function as an explicit gate: exit 0 with a SelfTestReport on a pass, exit 3 with code clockSelfTestFailed at 3 frames of input stamp bias, usage error selfTestNeedsSameDevice for two devices"
    requirement: CAL-03
    verification:
      - kind: other
        ref: "bash scripts/ci-sim.sh: selftest clock --simulate --json passes; --sim-stamp-bias 3 exits 3 clockSelfTestFailed; two devices exits 64 selfTestNeedsSameDevice"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/ClockTests.swift#aThreeFrameInputStampBiasFailsTheSelfTest, aBiasInsideTheLimitsStillPasses"
        status: pass
    human_judgment: false
  - id: D3
    description: "CAL-03 boundary and precision: the self-test passes at exactly |median| 1.0 and p95 |delta| 2.0 and fails at 1.01 / 2.01; ticks convert to nanoseconds in Double without overflow on 1/1 and 125/3 above 2^50; timeline fits err below 0.01 frame at +-50 ppm and are local, not global"
    requirement: CAL-03
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/ClockTests.swift#theLimitsThemselvesPass, justPastTheMedianLimitFails, justPastTheP95LimitFails, ticksRoundTripAboveTwoToTheFifty, theFitErrsByLessThanAHundredthOfAFrame, theFitIsLocalAndNotOneGlobalLine"
        status: pass
    human_judgment: false
  - id: D4
    description: "Same-device results report path, measured ioOffset and appRoundTrip = path + median ioOffset (headline appRoundTrip); two-device results (speakers to microphone, up to 50 ppm drift) are measured only through the host path with appRoundTrip and ioOffset absent"
    requirement: RES-02
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/MeasuredFiguresTests.swift#aSameDeviceRunMeasuresPathIoOffsetAndAppRoundTrip, theIoOffsetIsReadFromTheStampsNotAssumed, aTwoDeviceRunIsMeasuredOnlyThroughTheHostPath"
        status: pass
    human_judgment: false
  - id: D5
    description: "Every result shows the HAL-reported breakdown and both reported sums next to the measured figures (Scarlett 57 / 341, speakers to microphone 2203) and expected vs measured delta-io; pretty output has a 'Reported vs measured' block; corrections stay [] and no measured number changes when reported values change"
    requirement: RES-02
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/MeasuredFiguresTests.swift#theReportedFiguresAreTheCatalogSumsAtTheBufferUsed, correctionsStayEmptyAndReportedValuesNeverMoveAMeasuredNumber; Tests/soundpingTests/ReportedBlockTests.swift"
        status: pass
    human_judgment: true
    rationale: "Whether the reported sums agree with measured hardware figures, and which safety-offset reading is right (RESEARCH P3), is only settled when plans 01-07 and 01-09 put them next to real devices"
  - id: D6
    description: "Each run that passes the valid-hit gate stores a calibration keyed by {outputUID, outChannels, inputUID, inChannel, sampleRate, bufferFrames}, kind roundTrip, labelled 'round trip'; exact key equality (48000 vs 44100, buffer 128 vs 129, input channel 7 vs 8 differ); a run below the gate stores nothing; no mic-delay case exists"
    requirement: CAL-02
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/CalibrationStoreTests.swift (15 tests)"
        status: pass
      - kind: other
        ref: "bash scripts/ci-sim.sh asserts calibrations.json (schemaVersion 1, one roundTrip record) and result.calibration.stored"
        status: pass
    human_judgment: false
  - id: D7
    description: "A clock-selftest.json or calibrations.json this build cannot read fails the run before any audio with a usage error naming the file, and leaves no run folder behind"
    requirement: CAL-02
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/ClockTests.swift#anUnreadableStatusFileFailsTheRunBeforeAnyAudio; CalibrationStoreTests#anUnreadableCalibrationFileFailsTheRunBeforeAnyAudio, anotherSchemaVersionOrMalformedJSONIsAUsageErrorNamingThePath"
        status: pass
    human_judgment: false

duration: 27min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 06: Host-clock self-test, measured vs reported, calibrations Summary

**Every same-device run now proves its host clock against its sample clock (median/p95 delta inside 1/2 frames or `selftest clock` exits 3), reports path, measured I/O offset and app round trip next to what the HAL claims, measures two-device setups through fitted per-direction host timelines, and stores each passing run as a round-trip calibration that nothing can mistake for a mic delay.**

## Performance

- **Duration:** ~27 min
- **Started:** 2026-11-12T01:07Z
- **Completed:** 2026-11-12T01:35Z
- **Tasks:** 3 (tracer + two TDD expansions)
- **Files modified:** 24 (10 created, 14 modified)
- **Commits:** 5 production commits

## Accomplishments

- **Clock proof (CAL-03).** `HostClock` converts ticks in Double (a UInt64 product would overflow near 2^57 ticks at 125/3). `DeviceTimeline` answers each query with a least-squares line through the 33 nearest callbacks, in both directions (sample to host, host to sample); a test with a +0 / +400 ppm clock shows two different slopes, so the fit is local. `ClockSelfTest` compares the sample-clock path with the host-clock path per hit; the simulated duplex device lands at |median delta| around 1e-7 frames, a 3-frame input stamp bias fails with delta 3.00.
- **One function, two entry points.** The coordinator runs `ClockSelfTest` after the last hit of every same-device run, emits the `selfTest` event, stores the result in `clock-selftest.json` (latest per device UID, rate, buffer) and records it in run.json. `soundping selftest clock` runs the same recipe and turns the verdict into exit 0 or 3.
- **Measured next to reported (RES-02).** Same device: `path = S_in - S_out`, `ioOffset` read per callback from the stamp log, `appRoundTrip = path + median ioOffset`, headline `appRoundTrip` (412.37 + 284 = 696.37 on the simulator). The pretty output has a "Reported vs measured" block with the Scarlett fixture's 57 / 341 frames next to the measurement and expected vs measured delta-io.
- **Two devices through host time.** The simulator gives output and input separate label origins and a drifting input clock; the coordinator warms up 40 callbacks, places each hit's input window by mapping its output frame through the input timeline, and measures `H_in - H_out`. A speakers-to-microphone run at -50 to +50 ppm recovers the injected 412.37 frames within 0.5 frame with every hit valid; its reported path is the 2203-frame fixture sum.
- **Calibrations (CAL-02).** `calibrations.json` keeps the latest record per exact key; `CalibrationKind` has one case. A run below the valid-hit gate stores nothing and says `stored: false`.
- **Carry-forward fixed.** The `armed` event now carries the real run id, collision suffix included (a test runs twice in one second and compares armed ids with final ids).

## Task Commits

1. **Task 1: Host-clock self-test end to end (tracer)** - `0301271` (feat)
2. **Task 2 RED: failing measured-figures tests** - `904f2f5` (test)
3. **Task 2 GREEN: measured vs reported, two-device host path** - `f175109` (feat)
4. **Task 3 RED: failing calibration tests** - `45f077d` (test)
5. **Task 3 GREEN: round-trip calibrations** - `196e3c2` (feat)

**Plan metadata:** committed after this file (docs: complete plan)

Tracer feedback gate: the tracer `<verify>` carried only `<automated>` checks; re-run end to end after the tracer commit (`Suite ClockTests passed`, `ci-sim: OK`), so expansion continued without a checkpoint.

## TDD Gate Compliance

- **Task 1** is `type="tracer"` (no RED commit by design); `ClockTests` ship with the tracer.
- **Task 2 RED:** `MeasuredFiguresTests` plus compile-only stubs (`Scenario.ioOffsetFrames`, `RunResult.reported`). Command: `SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 swift test --filter MeasuredFiguresTests`. Target `aSameDeviceRunMeasuresPathIoOffsetAndAppRoundTrip()` failed on `measured.headline == .appRoundTrip` (actual `.path`) and `measured.ioOffset.median` (actual nil). Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, 9 tests, 6 failing, swift-testing). Semantic assessment: the target ran and failed on the planned assertions because the coordinator did not yet measure I/O offset or app round trip; the two-device cases failed on `domain == .host`, `hostTimebase` and `reported`, while their path-recovery assertions already held on the single-timeline simulator, as expected. **GREEN** `f175109`: all 9 pass.
- **Task 3 RED:** `CalibrationStoreTests` plus stubs (store functions that do nothing, `RunResult.calibration` never set). Target `aPassingRunStoresOneRoundTripCalibrationKeyedByItsSetup()` failed on `result.calibration == CalibrationRef(... stored: true)` (actual nil) and on the missing record in calibrations.json. Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, 15 tests, 9 failing, swift-testing). Semantic assessment: the stub store returned empty files, so every behavioural assertion failed on its value while the six key/kind tests (pure value types) passed at once. **GREEN** `196e3c2`: all 15 pass.
- **REFACTOR:** none needed. RED commits precede their GREEN commits (`904f2f5` < `f175109`, `45f077d` < `196e3c2`).

## Files Created/Modified

Clock: `Clock/{HostClock,DeviceTimeline,ClockSelfTest}.swift`. Stores: `Store/{ClockSelfTestStore,CalibrationStore}.swift` (the first also holds the shared `VersionedFile` loader). Engine: `RunCoordinator` (self-test, two-device mapping, folder-before-armed, calibration), `RunModel` (new result fields, `selfTest` event, `Measured.headlineStats`), `RunRequest` (`requiredValidHits`), `AudioBackend`, `SimulatedBackend`. CLI: `SelftestCommand`, `SimulationOptions`, `PrettyRenderer`, `RunCommand`, `ErrorReporting`, `SoundPing`. Tooling: `scripts/ci-sim.sh`. Tests: `ClockTests`, `MeasuredFiguresTests`, `CalibrationStoreTests`, `ReportedBlockTests`.

## Decisions Made

See `key-decisions`. For the plans that follow:

- **Plan 01-07 (HAL backend) must implement three things the protocol now requires:** `stampLog()` (one entry per callback per direction, sample time, host time, rateScalar, frames), `halHostTime(forInputSample:)` (the `AudioDeviceTranslateTime` third opinion; may stay nil), and `currentInputFrame()` (the label of the next frame to be captured). It should also fill `BackendInfo.outputDevice/inputDevice` from `HALDeviceCatalog` and leave `hostClock` at `.system`. For two devices the backend must have 33+ callbacks logged on both sides before the first hit is scheduled; `waitUntilCaptured` is asked for an input label after `currentInputFrame()`.
- **Plan 01-09 (bench):** the headline is `appRoundTrip` for same-device runs (RESEARCH open question 2); switch it in `RunCoordinator.finish` (`figures.headline`) if the bench says otherwise. The calibration record, `runs list` and the run gate all follow `headlineStats`/`path` already.
- `RunEvent` consumers now see a `selfTest` event between the last hit and `finished` on same-device runs (ndjson line count is armed + hits + 2).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Existing tests pinned the old event stream and backend protocol**
- **Found during:** Task 1
- **Issue:** `RunStreamTests` asserted 27 events (now 28 with `selfTest`), and the `GoneAfterFirstHitBackend` test double in `SimulationRecoveryTests` no longer conformed to `AudioBackend` once `stampLog`, `halHostTime` and (Task 2) `currentInputFrame` became requirements.
- **Fix:** `RunStreamTests` expects 28 events and checks the self-test event; the test double forwards the new methods.
- **Files modified:** `Tests/SoundPingKitTests/RunStreamTests.swift`, `Tests/SoundPingKitTests/SimulationRecoveryTests.swift`
- **Commits:** `0301271`, `f175109`

**2. [Rule 3 - Blocking] `aFullRunFinishesFast` fails under a CPU-saturated parallel `swift test`**
- **Found during:** Task 3 (full suite)
- **Issue:** The 2 s wall-clock bound passed alone (0.55 s) but failed once the suite had grown to 155 tests sharing 14 cores with other agents' builds (load average 5+); the run itself costs the same as before (about 5 ms per hit in debug, 25 ms added by this plan).
- **Fix:** Bound raised to 10 s with a comment; it still catches a simulator that sleeps on the wall clock (105 hits spaced 450-750 ms is about a minute). New tests also use fewer hits to add less load.
- **Files modified:** `Tests/SoundPingKitTests/SimulationRecoveryTests.swift`
- **Commit:** `196e3c2`

**3. [Rule 2 - Missing critical] Armed run id could lack the collision suffix**
- **Found during:** Task 1 (carry-forward note from 01-10/01-03)
- **Issue:** The coordinator predicted the run id for `armed` before the folder existed, so a second run in the same second streamed an id without its `-2`.
- **Fix:** The folder is created before `armed`; `finish` writes into it; a run that fails before run.json removes its empty folder.
- **Files modified:** `Sources/SoundPingKit/Engine/RunCoordinator.swift`
- **Commit:** `0301271`

**4. [Plan shorthand] Interface additions beyond the listed ones**
- `AudioBackend.currentInputFrame()` and `BackendInfo.hostClock` were not in the plan's lists; both are needed (two-device warm-up; a machine-independent timebase for the simulator). `RunParameters.requiredValidHits` moved the valid-hit rule into the engine so the calibration writer and `RunGate` share it. `RunStore.list` follows `headlineStats` so the runs table shows the headline median. A small extra suite `ReportedBlockTests` covers the pretty "Reported vs measured" block.
- **Files modified:** `AudioBackend.swift`, `RunRequest.swift`, `ErrorReporting.swift`, `RunStore.swift`

**5. [Plan shorthand] Failure output of `selftest clock`**
- The acceptance criterion asks for the stdout envelope to carry `clockSelfTestFailed`, so a failing self-test throws a plain gate error (envelope on stdout, `error:` on stderr) rather than printing a report and then failing. The numbers are envelope context keys; the saved run holds the full result.

**Total deviations:** 5 (2 blocking test fixes, 1 added fix, 2 interface or output shape choices). **Impact:** none on the plan's goals; plan 01-07 reads the new protocol requirements above.

## Issues Encountered

- A Double holds 2^50 host ticks only to 1/8 tick (0.0003 frame), so the inverse-mapping test tolerates 1e-3 frame; the fits themselves work on offsets from a base and are unaffected.
- Tool note: the sandbox refused some compound `git` and heredoc commands, so commits used `git commit -F` with message files and the plan commit ledger file was not written; `commits` above is measured as `git rev-list --count 5ee9663..HEAD`.

## Known Stubs

- `SimulatedBackend.halHostTime(forInputSample:)` returns nil by design: the simulator has no HAL to ask. Plan 01-07 implements it with `AudioDeviceTranslateTime`; until then `halCrossCheckMedianFrames` is nil in results. Not recorded in `.planning/WINDOWS.md` to avoid a cross-worktree conflict on a shared file.

## Threat Flags

None beyond the plan's threat model. T-01-20 is pinned by `CalibrationStoreTests` (one kind, no mic-delay raw value decodes) and `MeasuredFiguresTests` (corrections empty, reported never moves measured); T-01-21 by the unreadable-file tests for both JSON files; T-01-22 by `runId` and `measuredAt` on every entry; T-01-SC: no new packages.

## User Setup Required

None.

## Next Phase Readiness

- Plan 01-07 can implement the HAL backend against the listed protocol requirements and run `soundping selftest clock` on the Scarlett and the MacBook; the two-device path runs MacBook speakers to microphone end to end in simulation.
- Confirm a green `just test` after the wave merge (155 SoundPingKit/soundping tests plus ci-sim pass here; the timing test margin shrinks as more plans add suites).

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*

## Self-Check: PASSED

All created files present; commits 0301271, 904f2f5, f175109, 45f077d and 196e3c2 are ancestors of HEAD; `Suite ClockTests passed`, `Suite MeasuredFiguresTests passed`, `Suite CalibrationStoreTests passed`, `TWO-DEVICE-OK`, `CAL-OK`, and `ci-sim: OK` all hold; `scripts/test.sh` green.
