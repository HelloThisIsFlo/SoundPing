---
phase: 01-audio-round-trip
plan: 08
subsystem: preflight
tags: [swift6, tcc, microphone-permission, process-tree, level-ramp, hearing-safety, channel-probe, swift-testing]

requires:
  - phase: 01-audio-round-trip/02
    provides: AudioBackend protocol, RunCoordinator event stream, SimulatedBackend
  - phase: 01-audio-round-trip/03
    provides: error envelope, exit 65 for preflight, ndjson stream and its ci-sim block
  - phase: 01-audio-round-trip/05
    provides: SetupResolver, DeviceInfo channel names and data sources, SimulatedCatalog
  - phase: 01-audio-round-trip/06
    provides: run folder created before armed, same-device self-test inside the run
  - phase: 01-audio-round-trip/07
    provides: HALBackend, HALProperty readers, mid-run abort
provides:
  - "Preflight in a fixed order: microphone permission (names the app that owns it), output mute/volume/process mute, then the level ramp; the first failure ends the run with a named cause and exit 65"
  - "LevelRamp: first probe -48 dBFS, +6 dB steps, per-listener ceilings (loopback -6, speaker -12, headphones -30, unknown -18, or --max-level), 12 dB step-down on clipping, lock at confidence >= 0.9"
  - "Probe phase: uncounted probes with negative indices, probe and levelLocked events before armed, RunResult.preflight"
  - "ChannelProbe: soundping run ... --in-channel auto probes every input channel, ranks, refuses a tie, saves on request, never measures"
  - "Error codes micPermissionDenied, outputMuted, inputDigitalSilence, inputClipping, nothingHeardAtCeiling, inChannelAmbiguous"
affects: [01-09, 01-10, phase-02-midi]

plan_head_before: 77b561c5655422d39019d46e56d3c7428ed05b55
plan_head_after: ba90d728625c786c90c1904ddaac45433892d76f

actuals:
  tokens: 36900
  tasks: 3
  commits: 6

tech-stack:
  added: []
  patterns:
    - "Preflight failures are announced as an aborted event and then thrown, the same two-step the device-change abort uses, so ndjson readers see the cause on the stream"
    - "One listening path (HitListener) serves warm-ups, measured hits, level probes and the channel probe, so a probe is judged exactly the way a hit is"
    - "Probe indices are negative, so every simulation knob keyed by hit index is blind to probes by construction"
    - "The ramp is a pure state machine (LevelRamp.record) fed by the coordinator, so every boundary (-6.0 exact, -1.0 exact, non-aligned ceiling) is a plain unit test"
    - "RED commits carry compile-only scaffolds (real data types, stubbed logic) so the target tests fail on assertions, validated with gsd_run check tdd-red-evidence and SWT_SF_SYMBOLS_ENABLED=0"

key-files:
  created:
    - Sources/SoundPingKit/Preflight/ResponsibleApp.swift
    - Sources/SoundPingKit/Preflight/Preflight.swift
    - Sources/SoundPingKit/Preflight/LevelRamp.swift
    - Sources/SoundPingKit/Preflight/ChannelProbe.swift
    - Sources/SoundPingKit/Preflight/ProbePlayer.swift
    - Sources/SoundPingKit/Engine/HitListener.swift
    - Tests/SoundPingKitTests/PreflightTests.swift
    - Tests/SoundPingKitTests/LevelRampTests.swift
    - Tests/SoundPingKitTests/ChannelProbeTests.swift
  modified:
    - Sources/SoundPingKit/Audio/AudioBackend.swift
    - Sources/SoundPingKit/Audio/HALBackend.swift
    - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
    - Sources/SoundPingKit/Engine/RunCoordinator.swift
    - Sources/SoundPingKit/Engine/RunModel.swift
    - Sources/SoundPingKit/Engine/RunRequest.swift
    - Sources/SoundPingKit/Engine/SetupResolver.swift
    - Sources/SoundPingKit/Engine/SoundPingError.swift
    - Sources/soundping/Commands/RunOptions.swift
    - Sources/soundping/Commands/RunCommand.swift
    - Sources/soundping/Commands/SelftestCommand.swift
    - Sources/soundping/Commands/SimulationOptions.swift
    - Sources/soundping/Render/PrettyRenderer.swift
    - scripts/ci-sim.sh
    - Tests/SoundPingKitTests/RunStreamTests.swift
    - Tests/SoundPingKitTests/RejectionTests.swift
    - Tests/SoundPingKitTests/ClockTests.swift
    - Tests/SoundPingKitTests/ResolverTests.swift
    - Tests/SoundPingKitTests/HardwareRoundTripTests.swift
    - Tests/soundpingTests/ErrorReportingTests.swift

key-decisions:
  - "Probes are a separate uncounted phase and the declared 5 warm-ups run after the lock (RESEARCH open question 1, plan discretion); plan 01-09 records it in PROJECT.md"
  - "Probe ScheduledHits carry negative indices (-1, -2, ...); the simulator validates fault indices only once a real hit is scheduled, so --sim-miss/--sim-xrun/--sim-fault never touch a probe and the gate-fail checks still exit 3, not 65"
  - "armed is now emitted after backend.start() and after the lock (it used to precede start); its run id is still the final one because the run folder is created first"
  - "The chirp band follows the listener only when --template is absent: RunRequest.preflight.templateFollowsListener is false by default, so engine callers and existing tests keep the template they pass; the CLI sets it when --template is not given"
  - "--level L is one confirmation probe, capped by the ceiling with a warning in preflight.warnings instead of a silent change; clipping at a chosen level fails (inputClipping) rather than stepping down"
  - "A silent (all-exact-zero) probe re-asks the backend for the permission: denied or restricted is micPermissionDenied, anything else inputDigitalSilence; a silent probe is not emitted as a probe event (its peak would be -infinity)"
  - "--in-channel auto defaults to chirp-loopback and the unknown-listener ceiling (-18 dBFS) because the channel is not known yet; --listener, --max-level and --template override it; each channel gets a 60 s deadline because nobody listens to device events during the probe"
  - "RunResult.preflight is optional so run.json files saved before this plan still decode"

patterns-established:
  - "Preflight check order is data in one place (Session.preflight then Session.lockLevel); a new check slots in by position and the 'first failure wins' test pins it"
  - "ProbePlayer + HitListener are the only code that plays and hears an uncounted sound; new probe-like features reuse them"

requirements-completed: [ENG-03, ENG-05]

coverage:
  - id: D1
    description: "Denied or restricted microphone stops the run before any hit with micPermissionDenied (exit 65), naming the owning app, how it was detected and the System Settings fix"
    requirement: ENG-03
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/PreflightTests.swift#aDeniedMicrophoneStopsTheRunBeforeAnyHitAndNamesTheApp, aRestrictedMicrophoneStopsTheRunTheSameWay"
        status: pass
      - kind: integration
        ref: "bash scripts/ci-sim.sh (denied microphone block: exit 65, micPermissionDenied, terminalApp)"
        status: pass
    human_judgment: false
  - id: D2
    description: "Level ramp from -48 dBFS in +6 dB steps, capped by the listener ceiling, locked for every warm-up and measured hit; probes uncounted with negative indices; stream order probe, levelLocked, armed, hits, finished"
    requirement: ENG-03
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/LevelRampTests.swift (33 tests), Tests/SoundPingKitTests/RunStreamTests.swift"
        status: pass
      - kind: integration
        ref: "bash scripts/ci-sim.sh (ndjson order block, ramp block, gate-fail runs exit 3 not 65)"
        status: pass
    human_judgment: false
  - id: D3
    description: "Named causes inputDigitalSilence, inputClipping, nothingHeardAtCeiling, outputMuted, checked in a fixed order"
    requirement: ENG-03
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/LevelRampTests.swift#allZeroInputWithPermissionIsDigitalSilence, aPathHotterThanEvenTheFloorProbeCanTakeIsClipping, aDeafPathFailsAsNothingHeardAtTheCeilingAfterEveryStep, aMutedOutputIsNamedBeforeTheFirstProbe, theChecksRunInAFixedOrderAndTheFirstFailureWins"
        status: pass
    human_judgment: false
  - id: D4
    description: "--in-channel auto probes every input channel, prints the winner with confidence and margin, refuses a tie, saves on request, never creates a run"
    requirement: ENG-05
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/ChannelProbeTests.swift, Tests/SoundPingKitTests/ResolverTests.swift#autoLeavesTheChannelUnresolvedAndFlagsItForTheProbe"
        status: pass
      - kind: integration
        ref: "bash scripts/ci-sim.sh (channel probe block: chosen 7, saved, setups.json bench inChannel 7, no run folder, ambiguous exits 65)"
        status: pass
    human_judgment: false
  - id: D5
    description: "Real-hardware behaviour of the HAL permission read, the mute/volume/process-mute reads and the ramp on the Scarlett loop, and which prompt macOS shows for the host app"
    requirement: ENG-03
    verification: []
    human_judgment: true
    rationale: "Needs the real Scarlett, a real TCC state for the host app and a person listening; running it from an agent could raise an unexpected macOS prompt on Flo's screen. Plan 01-09's bench covers it."

duration: 34min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 08: Preflight, Level Ramp and Auto Channel Summary

**A run now refuses to start blind: a denied microphone stops it with the owning app named, a gentle -48 dBFS ramp finds a safe level and locks it, silent, clipping, muted or deaf setups each get a named exit-65 cause, and `--in-channel auto` finds the loop channel without ever measuring.**

## Performance

- **Duration:** about 34 min (start time was not captured at launch; taken from the first commit)
- **Completed:** 2026-11-12T02:29Z
- **Tasks:** 3
- **Commits:** 6 production/test commits (plus the format pass folded into each, plus this summary)
- **Files:** 9 created, 20 modified

## Accomplishments

- **Permission with a name (T-01-27).** `ProcessTreeResolver` walks `getpid()` up through `sysctl`/`proc_pidpath` to the first `*.app/Contents/MacOS/` and reads `CFBundleDisplayName`, else `CFBundleName`, else the folder name. Fallbacks are `__CFBundleIdentifier`, then `TERM_PROGRAM`, both labelled `env (likely)`; the process tree wins when it finds an app (T-01-29). Non-ASCII names pass through the JSON envelope as raw UTF-8.
- **Hearing safety (T-01-28).** First probe -48 dBFS, +6 dB per miss, never above the listener's ceiling; a ceiling that falls between two steps is probed exactly once at the ceiling. Headphones top out at -30, and only an explicit `--max-level` replaces a ceiling. Pinned by `LevelRampTests`, including the engine-level "nothing is ever played above -30" case.
- **Boundaries as data.** A peak of exactly -1.0 dBFS is clipping (12 dB step-down, floor -60, at most two retries); exactly -6.0 locks clean; anything between locks with "input is hot".
- **One listening path.** `HitListener` (extracted from the coordinator, with `HostMapping`) serves warm-ups, measured hits, probes and the channel probe. Two-device runs get their host-clock mapping before the first probe.
- **`--in-channel auto`.** Opens each input channel, climbs -48 dBFS in 12 dB steps to the ceiling, ranks by confidence, requires a 0.2 margin or fails `inChannelAmbiguous` with the candidates. Pretty table or `channelProbe` JSON; `--save-setup NAME` writes the channel, a TTY with `--setup NAME` is asked "Save in-channel N to setup NAME? [y/N]", JSON never prompts.
- **Flags.** `--max-level`, `--listener`, `--sim-permission`, `--sim-input-zeros`, `--sim-muted`, `--sim-loop-channel`.

## Task Commits

1. **Task 1 (tracer): denied microphone names the owning app** - `e72e942` (feat). Tracer gate: `<verify>` is automated-only and `human_verify_mode` is end-of-phase, so both automated checks were re-run after the commit (PreflightTests suite, ci-sim) and passed: tracer verified end-to-end, expansion continued.
2. **Task 2 RED: failing LevelRampTests** - `886183c` (test)
3. **Task 2 GREEN: ramp, lock, named causes, probe/levelLocked events** - `e040e30` (feat)
4. **Task 3 RED: failing ChannelProbeTests** - `e0ca02f` (test)
5. **Task 3 GREEN: `--in-channel auto`** - `351637f` (feat)
6. **Hardware smoke-test comment** - `ba90d72` (test)

No REFACTOR commit was needed; `swift format` ran before each commit.

## TDD Gate Compliance

- **Task 2 RED** `886183c`: `LevelRamp` as compile-only stubs plus real data types (events, `PreflightReport`, `PreflightOptions`, `MuteState`, `Scenario` knobs). Command `SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 swift test --filter LevelRampTests`. Target `aNormalRunRampsFromMinusFortyEightLocksAndThenPlaysWarmupsAndHits()` failed on `#require(result.preflight)` because the stub coordinator never ramps. Classifier `RED_EVIDENCE_OK` (`target_test_failed`, 33 tests, 31 failing). Semantic assessment: the target ran a full simulated run and failed on the planned assertion; the two that passed at once are the pure ones that already held for a stub.
- **Task 3 RED** `e0ca02f`: `ChannelProbe.run` returns an empty result; `ResolverTests` auto case rewritten. Target `theLoopChannelWinsWithHighConfidenceAndAClearMargin()` failed on `chosen.index == 7` and the other value assertions. Classifier `RED_EVIDENCE_OK`. Semantic assessment: assertion failures against the stub, the error-case tests failed because no error was thrown.
- RED precedes GREEN in both cases (`886183c` < `e040e30`, `e0ca02f` < `351637f`). Task 1 is a tracer without `tdd="true"`; its tests ship in its feat commit.

## Decisions Made

See `key-decisions` above. The ones to veto at review: probe phase separate from warm-ups (plan already flagged it), `armed` now after the lock, and `--level` capped by the ceiling with a warning.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Existing tests assumed `armed` is the first event**
- **Found during:** Task 2
- **Issue:** `RunStreamTests` was expected to change (plan says so); `ClockTests#theRunIdOnTheArmedEventIsTheFinalOneEvenWhenTwoRunsShareASecond` also read `events.first` as armed, which the plan did not list.
- **Fix:** it now picks the `armed` event wherever it sits.
- **Files modified:** `Tests/SoundPingKitTests/ClockTests.swift`
- **Committed in:** `e040e30`

**2. [Rule 1 - Bug] Simulator trapped on a negative hit index**
- **Found during:** Task 2
- **Issue:** `UInt64(index)` in the per-hit jitter crashes for probe indices, and `validateFaultIndices` took the highest index from probes alone (-1) and rejected every knob before the first real hit was scheduled.
- **Fix:** `UInt64(bitPattern:)`; fault validation waits for the first non-negative hit.
- **Files modified:** `Sources/SoundPingKit/Simulation/SimulatedBackend.swift`
- **Committed in:** `e040e30`

**3. [Rule 3 - Blocking] Negative flag values were rejected by the parser**
- **Found during:** Task 2 (acceptance `--sim-gain-db -80`)
- **Issue:** ArgumentParser read `-80` as an option.
- **Fix:** `.unconditional` parsing on `--sim-gain-db` and on `--level`/`--max-level` (the same fix `--sim-drift-ppm` already had).
- **Files modified:** `Sources/soundping/Commands/SimulationOptions.swift`, `Sources/soundping/Commands/RunOptions.swift`
- **Committed in:** `e040e30`

**4. [Rule 2 - Missing critical] Safety and misuse guards the plan implied but did not spell out**
- `--max-level` above 0 dBFS is a usage error; `--listener` is validated; `--level` above the ceiling is capped with a visible warning rather than silently honoured.
- `--in-channel auto` with `selftest clock` fails with a usage error (the self-test needs a number).
- The simulator resets its state on `open`, because the channel probe reopens one backend per channel.
- **Committed in:** `e040e30`, `351637f`

**5. [Rule 3 - Blocking] Two shared types gained fields**
- `ResolvedSetup.autoInChannel` (the "unresolved plus flag" the plan names) and `RunRequest.preflight` (`PreflightOptions`) are new public fields with defaults; two new internal files (`HitListener.swift`, `ProbePlayer.swift`) hold the shared listening code and are not in the plan's file list.

**6. [Rule 3 - Blocking] RejectionTests clipping case rewritten as the plan directs**, plus a clean-chirp counterpart that proves the guard is not over-eager.

---

**Total deviations:** 6 (1 bug, 1 missing-critical, 4 blocking). **Impact:** all necessary for the plan's own acceptance criteria; no scope creep.

## Issues Encountered

- `gsd_run check tdd-red-evidence` read "unknown" format on this Mac until `SWT_SF_SYMBOLS_ENABLED=0` made swift-testing print the plain glyphs (same fix plan 01-07 used).
- `swift format` rewrites `HitScheduler.swift` on every pass; that unrelated change was reverted each time so the diff stays on this plan.

## Known Stubs

None.

## Threat Flags

None beyond the plan's register. T-01-27 to T-01-30 are mitigated as listed; no packages were added (T-01-SC).

## User Setup Required

None for the code. First hardware run: macOS may ask the host app (Ghostty, Claude, ...) for microphone access, because `HALBackend.permissionStatus()` requests it when the status is undetermined.

## Next Phase Readiness

- **Plan 01-09 (bench):** run `just hw-test` and `just cli run round-trip --output Scarlett --input Scarlett --in-channel 7` on the Scarlett and check: dimmed probe lines then "Level locked at ... dBFS (loopback, ceiling -6 dBFS)"; `--in-channel auto` picks Loop 1 (confidence and margin on the real loop; Loop 2 should stay quiet); the process-mute/volume reads on the real device; which of prompt-or-`micPermissionDenied` Terminal.app gives (RESEARCH open question 3). Neither the HAL permission read nor the mute reads has run on hardware yet.
- The 0.9 confidence target and the ceilings are RESEARCH A3 assumptions, tunable in `LevelRamp`.
- Plan 01-09 Task 3 should record the separate probe phase in PROJECT.md Key Decisions.
- The built-in microphone path (two devices, `chirp-speaker`) now ramps instead of the fixed -30 dBFS; 01-07's note that it scored ZNCC 0.35 at -24/-12 dBFS is exactly the case the ramp is for, but it is unmeasured.

## Self-Check: PASSED

- All nine created files exist; all six task commits (`e72e942`, `886183c`, `e040e30`, `e0ca02f`, `351637f`, `ba90d72`) are ancestors of HEAD.
- `swift test`: 236 tests in 21 suites pass (plus the 17-test `soundpingTests` run); `bash scripts/ci-sim.sh` ends with `ci-sim: OK`.
- Plan-level checks re-run: PreflightTests, LevelRampTests, RunStreamTests, RejectionTests, ChannelProbeTests each print their "Suite ... passed" line; RAMP-OK and AUTO-OK/NO-RUN-OK commands print as expected; only `HALBackend.swift` imports AVFoundation.
- Not run: `just hw-test` and any real-device command (see Next Phase Readiness).
