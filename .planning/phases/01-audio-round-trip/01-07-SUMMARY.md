---
phase: 01-audio-round-trip
plan: 07
subsystem: hal-backend
tags: [swift6, coreaudio, hal, ioproc, noLocks, atomics, device-listeners, mid-run-abort, simulated-faults, swift-testing]

requires:
  - phase: 01-audio-round-trip/02
    provides: AudioBackend protocol, RunCoordinator device-event handling, SimulatedBackend
  - phase: 01-audio-round-trip/05
    provides: HALDeviceCatalog, HALProperty readers, SetupResolver, DeviceInfo channel/stream layout
  - phase: 01-audio-round-trip/06
    provides: StampLog, DeviceTimeline, ClockSelfTest, currentInputFrame/stampLog/halHostTime protocol requirements
provides:
  - "HALBackend: AudioBackend over one raw HAL IOProc per distinct device (duplex = one IOProc), SoundPing's own per-process buffer size, applied size reported back, stall detection, sample-time gaps surfaced as overload events"
  - "RTState + StampRing + ioCycleInput/ioCycleOutput: preallocated rings and Atomic indices, every function reachable from the IOProc is @_noLocks and compiles"
  - "DeviceListeners: HAL listeners ('livn' 'nsrt' 'fsiz' 'slay' 'over' 'stpd' and the system 'dev#' list) compared with the opened state before they become DeviceEvents, removed in stop()"
  - "soundping run --buffer <frames>; hardware runs without --simulate; Scenario.faults + Fault.parse + repeatable --sim-fault <kind>@<hit>; just hw-test"
affects: [01-08, 01-09, phase-02-midi]

plan_head_before: 4b8cc688dfd39999e26abf8a2d976a631afaa014
plan_head_after: 47d0e41c6d094f52d4b90094588299b27efe26ef

actuals:
  tokens: 24500
  tasks: 2
  commits: 5

tech-stack:
  added: []
  patterns:
    - "Audio-thread state lives inline in one final class RTState: Atomic indices, calloc'd stamp rings as noncopyable structs, raw pointers for rings; the compiler's @_noLocks check rejects any reference counting, allocation or lock on the audio path"
    - "A HAL notification becomes an event only after it is compared with the value the run opened with, so another app changing its own (per-process) buffer on a shared device aborts nothing"
    - "Simulated device changes behave like real ones: the fatal kinds emit their event and then stop delivering audio until the coordinator cancels the wait; an overload is an xrun that also announces itself, so the rejection never depends on event timing"
    - "Source-rule tests scan Sources/ for the set-property call sites and the CoreAudio importers, so the never-tune prohibition (T-01-25) is a test, not a code review"

key-files:
  created:
    - Sources/SoundPingKit/Audio/HALBackend.swift
    - Sources/SoundPingKit/Audio/RTState.swift
    - Sources/SoundPingKit/Audio/IOCycle.swift
    - Sources/SoundPingKit/Audio/DeviceListeners.swift
    - Tests/SoundPingKitTests/IOCycleTests.swift
    - Tests/SoundPingKitTests/HardwareRoundTripTests.swift
    - Tests/SoundPingKitTests/AbortTests.swift
  modified:
    - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
    - Sources/soundping/Commands/RunOptions.swift
    - Sources/soundping/Commands/SimulationOptions.swift
    - scripts/ci-sim.sh
    - justfile

key-decisions:
  - "StampRing is a noncopyable struct stored inline in RTState, not a class: reaching a class-typed ring from the audio thread costs a retain, which @_noLocks refuses"
  - "Rounding and zeroing on the audio thread are hand-written (nearestLabel, a Float loop): Double.rounded() needs rounding-rule metadata and memset is not available to the checker; both are refused by @_noLocks"
  - "BackendInfo.bufferFrames is the input device's applied buffer on two-device runs (it drives the warm-up length and the calibration key); both devices are asked for the same size, and the output device's applied size is still checked by its 'fsiz' listener"
  - "Two devices at different nominal rates are refused (usage sampleRateMismatch): SoundPing never resamples and never changes a device's rate"
  - "Fatal simulated faults hang the wait after emitting their event, like a vanished device, instead of racing the coordinator's event task; the abort therefore never depends on scheduling"
  - "An overload fault reuses the simulated xrun (zeros plus a stamp jump) and adds the overload event on top, so the hit is rejected through the stamps whether or not the event is consumed in time"
  - "Faults naming a hit the run never fires are a usage error (invalidParameters, like --sim-miss/--sim-xrun); the 'event after finished' boundary is tested with a backend that reports the device gone from stop()"
  - "SoundPingError gained no helper: HALBackend builds its preflight errors (exit 65) locally, so no shared file changes in the same wave as the other plans"

patterns-established:
  - "Real-device code is proven twice: a hardware-gated test (SOUNDPING_HW=1) plus a synthetic-buffer test of the same functions that runs everywhere"
  - "RED commits for a plan with an existing API surface carry compile-only stubs (empty cycle functions, a Fault.parse that throws notImplemented) so the target test fails on its assertion"

requirements-completed: [CAL-01, ENG-07, ENG-02]

coverage:
  - id: D1
    description: "soundping run round-trip --output <Scarlett> --input <Scarlett> --in-channel 7 --buffer 128 runs on the real interface through a raw HAL IOProc, shows hits live and saves a run whose setup records the applied buffer; two consecutive 20-hit runs on the Scarlett Loop 1 loop agree within 2 frames"
    requirement: CAL-01
    verification:
      - kind: other
        ref: "Tests/SoundPingKitTests/HardwareRoundTripTests.swift#twoRunsOnTheSameLoopAgreeWithinTwoFrames (SOUNDPING_HW=1): valid >= 18, median 0...4800, medians within 2 frames, selfTest present, setup.bufferFrames == 128"
        status: pass
    human_judgment: false
  - id: D2
    description: "Everything reachable from the IOProc is @_noLocks and works on preallocated buffers and Atomic indices; the cycle lands a scheduled template at the exact output offset on only the selected channels, captures the selected input channel at the right ring index, logs stamps, and flags a 64-frame label jump"
    requirement: ENG-02
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/IOCycleTests.swift (15 tests: exact offset, selected channels only, split across callbacks, overlapping hits, stamps, 64-frame gap, 0.5-frame tolerance, ring wrap, schedule ring order and capacity)"
        status: pass
      - kind: other
        ref: "swift build compiles IOCycle.swift and RTState.swift.append under @_noLocks (no reference-counting, allocation or lock diagnostic)"
        status: pass
    human_judgment: false
  - id: D3
    description: "SoundPing never sets a device's nominal sample rate, volume, mute or default; its only SetPropertyData call is its own per-process buffer size, and only Audio/ imports CoreAudio"
    requirement: CAL-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/IOCycleTests.swift#theOnlyDevicePropertyEverSetIsSoundPingsOwnBufferSize, onlyTheAudioFolderTouchesCoreAudio"
        status: pass
    human_judgment: false
  - id: D4
    description: "A device that disappears, or whose rate, buffer size or stream layout changes mid-run, aborts with kind deviceChanged and a named code (deviceGone, sampleRateChanged, bufferSizeChanged, streamConfigChanged), exit 75, no finished event and no run.json"
    requirement: ENG-07
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/AbortTests.swift#aSampleRateChangeAtHitThirtyAbortsTheRun, aDeviceLostAtTheFirstMeasuredHitAborts, aBufferChangeInsideTheLastHitsWindowStillAborts, aStreamConfigurationChangeAborts, theFirstOfTwoFaultsDecidesTheCause"
        status: pass
      - kind: other
        ref: "bash scripts/ci-sim.sh: --sim-fault sampleRateChange@30 and deviceGone@5 exit 75 with the named code and leave no run.json"
        status: pass
    human_judgment: false
  - id: D5
    description: "An overload or sample-time gap rejects only the hits whose window it touches (discontinuity), the run completes; a gap seen by the audio thread surfaces as an overload event"
    requirement: ENG-07
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/AbortTests.swift#anOverloadAtHitTwelveRejectsOnlyThatHit; IOCycleTests#aSixtyFourFrameJumpOfTheLabelSetsTheGapFlagAndLeavesSilence"
        status: pass
      - kind: other
        ref: "bash scripts/ci-sim.sh: overload@12 run rejects exactly hit 12 (discontinuity 1, valid 19)"
        status: pass
    human_judgment: false
  - id: D6
    description: "ENG-07 boundaries and precision: a change at the first measured hit or inside the last hit's window still aborts; an event after finished is ignored; sample-time continuity is Double with a 0.5-frame tolerance"
    requirement: ENG-07
    verification:
      - kind: unit
        ref: "AbortTests#aDeviceLostAtTheFirstMeasuredHitAborts, aBufferChangeInsideTheLastHitsWindowStillAborts, anEventAfterTheRunFinishedIsIgnored; IOCycleTests#continuityIsComparedInDoubleWithAHalfFrameTolerance"
        status: pass
    human_judgment: false
  - id: D7
    description: "On the real Scarlett, changing its sample rate in Audio MIDI Setup mid-run, and unplugging its USB cable mid-run, each stop the run within a second with error sampleRateChanged or deviceGone and exit 75, no summary printed"
    requirement: ENG-07
    verification:
      - kind: other
        ref: "Tests/SoundPingKitTests/HardwareRoundTripTests.swift#deviceListenersRegisterOnARealDeviceAndComeOffAgain (registration and removal only; the physical rate change and cable pull are the open human check)"
        status: pass
    human_judgment: true
    rationale: "A real sample-rate change or cable pull cannot be triggered from a script, and changing the user's device rate is exactly what SoundPing must never do on its own; the listener-to-abort wiring is proven on the simulator and the registration on the real device, the end-to-end physical case still needs Flo"

duration: 20min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 07: HAL backend, real-time cycle and mid-run abort Summary

**The round trip now runs on Flo's Scarlett through a raw CoreAudio HAL IOProc (a 26.00-frame path on Loop 1 at SoundPing's own 128-frame buffer, zero jitter, clock self-test passing, I/O offset measured at exactly the 284 frames the HAL sums predict), on an audio path the compiler proves free of locks and allocation, and a device that changes under a run now stops it with a named cause and exit 75.**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-11-12T01:41Z
- **Completed:** 2026-11-12T02:02Z
- **Tasks:** 2 (tracer + one TDD expansion)
- **Files modified:** 12 (7 created, 5 modified)
- **Commits:** 5 production commits (two RED, two GREEN, one format)

## Accomplishments

- **Real hardware, first try (CAL-01).** `soundping run round-trip --output Scarlett --input Scarlett --in-channel 7 --buffer 128` measured **26.00 frames (0.542 ms)** from Output 1/2 into `Loop 1`, confidence 1.00, jitter 0.00, 8/8 valid; the clock self-test passed (median delta -0.00, p95 0.01 frames) and `AudioDeviceTranslateTime` agreed with our timeline to -0.05 frames. The measured I/O offset was **284.00 frames, exactly the expected 128 + 128 + 14 + 14**; the HAL-reported path (57) and app round trip (341) sit next to the measured 26 and 310 in the new "Reported vs measured" block. `HardwareRoundTripTests` (two 20-hit runs, buffer 128) passes under a fully parallel `swift test` on 14 cores.
- **Real-time safety by construction (ENG-02).** `ioCycleInput` and `ioCycleOutput` are `@_noLocks` and build. The compiler found three real problems the first time (`Double.rounded()` needs metadata, `memset` is opaque to the checker, a class-typed stamp ring costs a retain) and all three were fixed in the code, not suppressed. Everything shared with the engine is preallocated in `RTState`: a mono capture ring (8 s), per-direction stamp rings (2^21 entries each from `calloc`, so unused pages cost nothing), a 32768-entry SPSC schedule ring and the templates; indices are `Atomic<Int>` with releasing stores.
- **Never tunes the user's devices (T-01-25).** The only `AudioObjectSetPropertyData` call in `Sources` sets `kAudioDevicePropertyBufferFrameSize` (SoundPing's own, per-process buffer, clamped to the device's range, read back and reported). A source-scanning test pins that, and pins that only `Audio/` imports CoreAudio and that `IOCycle.swift` contains nothing that suspends, spawns or logs.
- **Two devices work on the real HAL.** MacBook speakers to MacBook microphone opened two IOProcs, collected 44 input and 57 output callbacks before the first hit, placed each hit's input window through the host timelines and found the chirp at the same fractional position on three hits (13148.165, 37148.159, 61148.160 on labels 24000 apart). The default `chirp-loopback` recipe level and the correlator's 0.5 confidence limit reject every acoustic hit (ZNCC 0.35, run saved, `tooFewValidHits`); that is signal quality for plan 01-09's bench, not the backend.
- **Mid-run abort (ENG-07).** `DeviceListeners` watches 'livn', 'nsrt', 'fsiz', 'slay', 'over', 'stpd' and the system 'dev#' list, compares each notification with the state the run opened with, and removes every listener in `stop()`. In simulation `--sim-fault sampleRateChange@30` stops a 40-hit run after hit 29 with `error: sampleRateChanged`, exit 75, no summary and no `run.json`; `overload@12` rejects only hit 12 and the run passes with 19 valid.

## Task Commits

1. **Task 1 RED: failing IOCycle tests** - `cafb5b9` (test)
2. **Task 1 GREEN (tracer): real round trip through a raw HAL IOProc per device** - `b7bf102` (feat)
3. **Task 2 RED: failing abort tests** - `2ce879e` (test)
4. **Task 2 GREEN: stop a run with a named cause when a device changes** - `6711878` (feat)
5. **Formatting** - `47d0e41` (style)

**Plan metadata:** committed after this file (docs: complete plan)

Tracer feedback gate: the tracer `<verify>` carried only `<automated>` checks; after the tracer commit both were re-run end to end (`RT-OK`, `Suite HardwareRoundTripTests passed`), so expansion continued without a checkpoint. The precondition (Scarlett connected, `Loop 1` fed by its output) was met; no human step was needed.

## TDD Gate Compliance

- **Task 1** is `type="tracer"`; its IOCycle tests were still written first. **RED** `cafb5b9`: `RTState` plus compile-only stubs for `ioCycleInput`/`ioCycleOutput`. Command: `SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 swift test --filter IOCycleTests`. Target `theScheduledTemplateLandsAtTheExactSampleOffsetOnlyOnTheSelectedChannels()` failed on its value assertions (output buffers stayed at the garbage fill because the stub writes nothing). Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, 13 tests, 10 failing, swift-testing). Semantic assessment: the target executed and failed on the planned sample-offset and silence assertions; the three tests that passed at once are the pure ones (channel numbering, schedule-ring order, template store). **GREEN** `b7bf102`: all 13 pass (15 with the two source-rule tests added there).
- **Task 2 RED** `2ce879e`: `Fault`, `Scenario.faults` and a `Fault.parse` that throws `notImplemented`; the simulator ignores faults. Target `aSampleRateChangeAtHitThirtyAbortsTheRun()` failed on `#require(outcome.error)` (the run finished instead of aborting). Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, 12 tests, 9 failing). Semantic assessment: the target ran a full 40-hit simulated run and failed because no error was thrown, the planned assertion; the overload, out-of-range, stream-change and parse tests failed on their values, the late-event and no-fault tests passed because that behaviour already existed. **GREEN** `6711878`: all 12 pass (13 with the selector-set test); 30 consecutive runs of the suite showed no flake.
- **REFACTOR:** none needed beyond the formatting commit. RED commits precede their GREEN commits (`cafb5b9` < `b7bf102`, `2ce879e` < `6711878`).

## Files Created/Modified

Audio: `Audio/{HALBackend,RTState,IOCycle,DeviceListeners}.swift` (new). Simulation: `SimulatedBackend` (`Fault`, `Scenario.faults`, pending device events). CLI: `RunOptions` (`--buffer`, HAL backend), `SimulationOptions` (`--sim-fault`, `scenario(seed:bufferFrames:)` now throws). Tooling: `scripts/ci-sim.sh`, `justfile` (`hw-test`). Tests: `IOCycleTests`, `HardwareRoundTripTests`, `AbortTests`.

## Decisions Made

See `key-decisions`. For the plans that follow:

- **Plan 01-08 (preflight):** microphone permission is not checked yet; a denied mic would deliver zero buffers and every hit would be rejected. `start()` already throws `preflight` errors (`deviceStartFailed`, `ioProcFailed`, `bufferSizeNotApplied`) with exit 65, so the TCC check can use the same kind. The responsible-process message is still to be written.
- **Plan 01-09 (bench):** the Scarlett Loop 1 path is 26 frames at buffer 128 with zero jitter. The two-device MacBook speakers to microphone path finds the chirp at a stable fractional position (about 0.16 frame spread) but scores ZNCC 0.35 against the 0.5 confidence limit with `chirp-speaker` at -24 and -12 dBFS (the built-in mic captured a peak of 1.5 at -6 dBFS gain 0.5, so the level ramp matters). Expect to tune the template, the level or the limit there.
- A two-device run takes `BackendInfo.bufferFrames` from the input device; the calibration key and warm-up length follow it.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `@_noLocks` rejected the first IOCycle and ring implementation**
- **Found during:** Task 1
- **Issue:** `Double.rounded()` ("can cause metadata allocation or locks"), `memset` ("not available in this module") and a class-typed `StampRing` ("reference counting operations") all failed the build, as the plan's gate intends.
- **Fix:** `nearestLabel` (hand-written round-half-away), a Float zeroing loop, and `StampRing` as a noncopyable struct stored inline in `RTState`. IOCycleTests read the ring through `point(at:)` into a local first because `#require` cannot capture a noncopyable value.
- **Files modified:** `IOCycle.swift`, `RTState.swift`, `IOCycleTests.swift`
- **Commit:** `b7bf102`

**2. [Rule 2 - Missing critical] `--buffer` must reach the simulator too**
- **Found during:** Task 1
- **Issue:** with `--simulate --buffer 64` the setup recorded a request the simulator silently ignored (always 128), so a saved run claimed a buffer it never used.
- **Fix:** `SimulationOptions.scenario(seed:bufferFrames:)` takes the requested buffer; `RunOptions` validates `--buffer` to 1...16384 (usage `invalidParameters`).
- **Files modified:** `RunOptions.swift`, `SimulationOptions.swift`
- **Commit:** `b7bf102`

**3. [Plan shorthand] Source rules as tests**
- The threat model's prohibition (`verification: test`) and acceptance greps became `IOCycleTests#theOnlyDevicePropertyEverSetIsSoundPingsOwnBufferSize` and `onlyTheAudioFolderTouchesCoreAudio`, which scan `Sources/` on every run instead of relying on a reviewer.

**4. [Plan shorthand] Simulated fault semantics**
- A fatal fault (gone, rate, buffer, stream) emits its event and then never returns from the wait, like a real vanished device, because an event that merely races the coordinator's event task would make the abort depend on scheduling. An overload is the existing xrun plus an event. The "event after the last hit's window" boundary is tested with a backend double that reports the device gone from `stop()`; a fault index past the last hit is a usage error, like the existing `--sim-miss` and `--sim-xrun` checks.
- **Files modified:** `SimulatedBackend.swift`, `AbortTests.swift`
- **Commit:** `6711878`

**5. [Plan shorthand] Extra tests and interface**
- `HardwareRoundTripTests` gained a listener register-and-remove test on the real device; `AbortTests` pins the selector set; `Fault.parse` and `Scenario.faults` are public API of `SoundPingKit`; `scenario(seed:)` now throws for a malformed `--sim-fault`.

**Total deviations:** 5 (1 blocking build fix the plan expected, 1 added validation, 3 shape choices). **Impact:** none on the plan's goals.

## Issues Encountered

- **Pre-existing, out of scope:** `RunStore.runsChild` compares a standardized child path with a standardized parent; `standardizedFileURL` strips a leading `/private` only for paths that exist, so `--store /private/tmp/...` fails at the end of a run with `unreadableRun: '<id>' is not a run id` (after the audio ran). `/tmp/...`, `/var/folders/...` and the default store are unaffected. Not fixed here; logged in `deferred-items.md`.
- Tool note: the sandbox refused compound shell commands, so commits used `git commit -F` with message files, and the plan commit ledger was written to `.git/worktrees/<id>/gsd-plan-head-before-01-07`.

## Known Stubs

None. `SimulatedBackend.halHostTime(forInputSample:)` still returns nil by design (the simulator has no HAL); `HALBackend` implements it with `AudioDeviceTranslateTime`.

## Threat Flags

None beyond the plan's threat model. T-01-23 is enforced by the compiler (`@_noLocks` build); T-01-24 by `RTState.append`/`readCapture` bounds, the per-callback buffer-list checks and the ring wrap tests; T-01-25 by the source-scanning tests; T-01-26 by `DeviceListeners` plus `AbortTests` and the ci-sim abort runs; T-01-SC: no new packages (`Synchronization` is stdlib).

## User Setup Required

None. The hardware tests and `just hw-test` need the Scarlett (or `SOUNDPING_HW_OUTPUT` / `SOUNDPING_HW_INPUT` / `SOUNDPING_HW_IN_CHANNEL`) with an output-to-input loop, such as `Loop 1` fed by Focusrite Control.

## Open item for Flo (human check, Task 2)

During a hardware run (`just cli run round-trip --output Scarlett --input Scarlett --in-channel 7 --hits 100`), change the Scarlett's sample rate in Audio MIDI Setup, then repeat and unplug the USB cable mid-run. Each should stop within a second with `error: sampleRateChanged` / `error: deviceGone`, exit 75, and no finished summary. This changes the device's rate on purpose, so it was not triggered from a script.

## Next Phase Readiness

- Plan 01-08 can build the preflight (mic permission, silence, clipping, level ramp) on a working hardware backend.
- Plan 01-09 can run the real bench: the Scarlett loop gives 26 frames at 128 with zero jitter, the self-test passes, `halCrossCheckMedianFrames` is -0.05 frames, and the acoustic path needs template or level tuning.
- Confirm a green `just test` and `just hw-test` after the wave merge (185 tests plus ci-sim pass here, hardware suite 31 s).

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*

## Self-Check: PASSED

All created files present; commits cafb5b9, b7bf102, 2ce879e, 6711878 and 47d0e41 are ancestors of HEAD; `swift build` (with `@_noLocks`), `Suite IOCycleTests passed`, `Suite AbortTests passed`, `Suite HardwareRoundTripTests passed` (SOUNDPING_HW=1), the full 185-test run and `ci-sim: OK` all hold. The one open item is the physical rate-change and cable-pull check above.
