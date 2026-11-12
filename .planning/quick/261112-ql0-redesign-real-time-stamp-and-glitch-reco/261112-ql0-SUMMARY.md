---
phase: quick-261112-ql0
plan: 01
subsystem: audio-engine
tags: [coreaudio, ioproc, real-time, stamps, fault-intervals, clock-selftest]
requires: []
provides:
  - "One stamp ring entry per callback; StampLog.ioOffsetFrames; DeviceTimeline.coveredSamples"
  - "ioCycle: the single @_noLocks IOProc entry point, with mFlags checked by raw bits"
  - "FaultInterval and AudioBackend.faults(overlappingInput:output:), four single-writer fault rings in RTState"
affects: [HitListener, RunCoordinator, DeviceListeners, SimulatedBackend, HALBackend, ClockSelfTest]
key-files:
  created:
    - Tests/SoundPingKitTests/FaultRecordingTests.swift
  modified:
    - Sources/SoundPingKit/Audio/RTState.swift
    - Sources/SoundPingKit/Audio/IOCycle.swift
    - Sources/SoundPingKit/Audio/AudioBackend.swift
    - Sources/SoundPingKit/Audio/HALBackend.swift
    - Sources/SoundPingKit/Audio/DeviceListeners.swift
    - Sources/SoundPingKit/Clock/DeviceTimeline.swift
    - Sources/SoundPingKit/Clock/ClockSelfTest.swift
    - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
    - Sources/SoundPingKit/Engine/HitListener.swift
    - Sources/SoundPingKit/Engine/RunCoordinator.swift
    - Sources/SoundPingKit/Engine/SoundPingError.swift
    - Sources/SoundPingKit/Preflight/ChannelProbe.swift
    - Sources/SoundPingKit/Preflight/ProbePlayer.swift
    - .planning/phases/01-audio-round-trip/01-REVIEW-FIX.md
key-decisions:
  - "StampSide / CycleSide are plain scalar structs defined in IOCycle.swift: @_noLocks refuses Optional<TimelinePoint> (metadata) and calls into other files' inits and static lets"
  - "Fault cause codes are module-level constants in IOCycle.swift for the same reason; RTState maps them back to FaultInterval.Cause"
  - "ioCycle appends the stamp entry before it publishes the labels, so a reader that sees a new label also finds that callback's stamp"
  - "The output direction got the same label-continuity check as the input"
  - "stampCapacity stays 2^21; the self-test range rule is the wrap fix, with a run warning when it judges fewer hits than were valid"
requirements-completed: [WR-03, WR-01, IN-08, CAL-02, CAL-03, ENG-07]
duration: ~1h 15m
completed: 2026-11-12
status: complete
commits: 2
plan_head_before: d6790cb6ab4cddf97ff0bccec04192bffa0d8490
plan_head_after: e9a31494623e1c9f1a527c8ad1868865319f1ee8
actuals:
  tokens: 95000
  tasks: 3
  commits: 2
---

# Phase quick-261112-ql0 Plan 01: Redesign real-time stamp and glitch recording Summary

**One stamp ring entry per callback, mFlags checked by raw bits, and glitches recorded as per-direction fault intervals that HitListener queries directly from the backend (WR-03, WR-01, IN-08).**

## Accomplishments

- **WR-03 (Critical):** a duplex callback writes one entry carrying both directions, so a skipped or untimestamped side can never shift later input/output pairs. `StampLog.ioOffsetFrames` comes from single entries, `RunCoordinator` no longer zips the lists, and two devices never pair by ordinal. The clock self-test judges only hits inside `DeviceTimeline.coveredSamples`; a run warning says when it judged fewer than the valid hits.
- **IN-08:** `sampleTimeValid` / `hostTimeValid` / `rateScalarValid` are read as raw bits. A side without a host time is never logged, and its frames become an `invalidTimestamp` fault in its own direction.
- **WR-01:** four preallocated single-writer fault rings (input and output from the IOProc, input and output overloads from the listeners' queue). Intervals are never merged, a wrapped ring reports `logOverwritten`, and `HitListener` asks `backend.faults(...)` after the window plus a 20 ms settle, rejecting on any overlap with the input window or the played chirp. The overload `DeviceEvent` and the stream-fed `FaultMonitor` are gone.
- 01-REVIEW-FIX.md now lists WR-01, WR-03 and IN-08 under Fixed Issues with hashes; Skipped Issues reads `None.`

## Task Commits

1. **Task 1 (tracer): one stamp entry per callback, checked mFlags (WR-03, IN-08)** - `836f3db`
2. **Task 2: per-direction fault intervals, direct backend query (WR-01, IN-08)** - `e9a3149`
3. **Task 3: 01-REVIEW-FIX.md bookkeeping** - not committed (the orchestrator commits it, per the constraints)

## Verification

- `swift build`, `swift test` (291 tests in the kit target) and `bash scripts/ci-sim.sh` (`ci-sim: OK`) ran before each task commit. `swift build` passing proves the IOProc path is still `@_noLocks`.
- Gates: no `zip(log.input, log.output)` in RunCoordinator, `@_noLocks` directly above `func ioCycle(`, no `ioCycleInput`/`ioCycleOutput` in HALBackend, no `FaultMonitor|gapCount|lastGapLabel|surfaceGaps|overload(uid` anywhere in Sources or Tests.
- The Task 3 structure check script prints `ok`.
- `overload@12` over 20 hits still gives exactly one `discontinuity` rejection (AbortTests).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `@_noLocks` refused the planned shapes**
- **Found during:** Task 1
- **Issue:** `Optional<TimelinePoint>` ("can cause metadata allocation"), `TimelinePoint.init` and `static let` reads from another file ("called function is not available") all failed the compile-time lock check.
- **Fix:** the IOProc side works on plain scalar structs (`StampSide`, `CycleSide`) defined in `IOCycle.swift`, and cause codes are module-level `let` constants there. `StampRing.append` takes `StampSide` values and `StampSide.point` converts to `TimelinePoint` on the engine side. Behaviour is as the plan specified.
- **Commit:** 836f3db

**2. [Rule 2 - Missing critical] Stamp is appended before the labels are published**
- **Found during:** Task 1
- **Issue:** the plan has the helpers return their side and `ioCycle` append the entry. Done naively, the label store would come first, and a reader seeing the new label could miss that callback's stamp.
- **Fix:** the helpers no longer store labels; they return the next label and `ioCycle` stores it after the append (same release ordering that the fault rings need).
- **Commit:** 836f3db

**3. [Plan detail] Second stamp ring is minimal on a shared device**
- The output device's ring is allocated with capacity 1 when `sharedDevice` is true (nothing writes it), instead of a second 2^21 ring.

**4. [Test support] Helpers in IOCycleTests made internal**
- `SyntheticBuffers`, `timeStamp`, `cycle`, `captureCycle` and `playCycle` lost `private` so `FaultRecordingTests` shares them.

Otherwise the plan was executed as written.

## Known Stubs

None.

## Threat Flags

None. No new endpoints, auth paths or trust boundaries; the mitigations T-ql0-01 to T-ql0-05 and T-ql0-07 are implemented and unit tested. T-ql0-06 (late HAL `'over'` notification) is accepted as planned.

## Requires human verification (hardware, not run)

- `just hw-test`, then `soundping run round-trip` on a duplex loop: I/O offset median and `appRoundTrip` match a pre-change run within one frame; `soundping selftest clock` passes with no self-test warning on a normal-length run.
- Forced overloads on a real loop (smallest buffer, heavy CPU load): they appear as `discontinuity` rejections in run.json and the surviving medians do not shift.
- Measure how late the HAL `'over'` notification arrives; it must stay inside the 20 ms lookback and settle margins (`DeviceListeners.overloadLookbackMs`, `HitListener.faultSettleMs`). If not, raise both.

## Self-Check: PASSED

- FOUND: Tests/SoundPingKitTests/FaultRecordingTests.swift
- FOUND: commit 836f3db, commit e9a3149 (ancestors of HEAD)
