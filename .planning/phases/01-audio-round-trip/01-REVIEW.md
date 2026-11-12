---
phase: 01-audio-round-trip
reviewed: 2026-11-12T21:36:04Z
depth: standard
files_reviewed: 15
files_reviewed_list:
  - README.md
  - Sources/SoundPingKit/Audio/AudioBackend.swift
  - Sources/SoundPingKit/Audio/DeviceCatalog.swift
  - Sources/SoundPingKit/Audio/DeviceListeners.swift
  - Sources/SoundPingKit/Audio/HALBackend.swift
  - Sources/SoundPingKit/Engine/RunCoordinator.swift
  - Sources/SoundPingKit/Preflight/ChannelProbe.swift
  - Sources/SoundPingKit/Preflight/LevelRamp.swift
  - Sources/SoundPingKit/Preflight/Preflight.swift
  - Sources/soundping/Commands/RunOptions.swift
  - Tests/SoundPingKitTests/AbortTests.swift
  - Tests/SoundPingKitTests/ChannelProbeTests.swift
  - Tests/SoundPingKitTests/HardwareRoundTripTests.swift
  - Tests/SoundPingKitTests/LevelRampTests.swift
  - Tests/SoundPingKitTests/LoudnessInvariantTests.swift
findings:
  critical: 0
  warning: 0
  info: 0
  total: 0
  necessity: 0
status: clean
---

# Phase 01: Code Review Report

**Reviewed:** 2026-11-12T21:36:04Z
**Depth:** standard
**Files Reviewed:** 15
**Status:** clean

## Summary

This pass re-checked `git diff f54d1cf HEAD` over the 15 listed paths, reading each file in full.
- **Callees outside the list that were read:** `RunCommand.probeChannels`, `RunOptions.preflightOptions` / `--level` validation, `SoundPingError.forDeviceEvent(.outputRouteChanged)`, and `HALBackend`'s per-open event stream (`beginOpen`).
- **Tests run (read-only):** `swift test --filter "LoudnessInvariantTests|ChannelProbeTests|AbortTests|LevelRampTests"` → 95 tests in 4 suites, all passing. No hardware was used and no sound was played.
- **Stop rule applied:** only real defects count. None were found.

All reviewed files meet quality standards. No issues found.

### ✅ The 4 previous findings

| ID | Verdict | Note |
|---|---|---|
| CR-05 | ✅ holds (cause removed) | The ceiling comes from `outputClass` alone. That type has no loop case, so no input or loop can raise the ceiling. `classify` now reports `loopback` only on one device (same UID, plus a `Loop` channel or a virtual input), and only for the band, the reported listener and the hint. Two virtual devices are `unknown`. |
| WR-15 | ✅ holds | The probe keeps one baseline: `decided` = (loudness, data source, jack) from the first open. Every reopen re-derives the loudness and compares all three. Any difference calls `stop()` and throws `outputRouteChanged` before anything plays. `probeCeiling` comes from the current open, which has just been checked equal to the baseline. |
| WR-16 | ✅ holds | `playedLevel: fixed.map { _ in level }`, where `level` is `ramp.firstLevel = min(fixed, ceiling)`. Glitch replays keep that level, and a fixed level never steps. When the level was clamped, the detail names the played level and the clamp, and the context carries both levels. A non-finite `--level` cannot get this far: `RunOptions` refuses it. |
| IN-22 | ✅ holds | `transportName(for:)` is internal. The invariant builds every device through it, and `everyHALTransportGetsTheRuleCeilingThroughTheProductionMapping` walks every `kAudioDeviceTransportType*` constant against literal ceilings. BLE is `bluetooth` → -30. |

### 🔊 The loudness rule, path by path

- **Code (`LevelRamp.loudness`)**
  - `--max-level` replaces the ceiling (validated ≤ 0 and finite).
  - Otherwise `--listener` only lowers it: `named < fromOutput`, and `loopback` gives nil, so it lowers nothing.
  - Otherwise the output decides: headphones -30, `ispk` -12, other -18.
  - `outputIsHeadphones` fails safe. A built-in output that is not `ispk`, has no data source or has no device info counts as headphones.
- **Run path:** `RunCoordinator.preflight` → `runLoudness`. `--level` is clamped by `LevelRamp.firstLevel`, with a warning that names `ceilingOrigin`.
- **Probe path:** `ChannelProbe` → the same `runLoudness`, given a setup without a channel name, so the ceiling can never depend on the channel. `--max-level` is validated before the first open.
- **User-facing text all states the same rule:**
  - `--max-level`, `--listener` and `--level` help
  - `listenerNotRaisedWarning`
  - the `--level` clamp warning
  - all five `nothingHeardAtCeiling` hint branches and `ceilingOrigin`
  - the README "Test-sound loudness" section
  - the `LevelRamp.loudness` and `classify` doc comments, and the hardware-test header
  - **Stale wording:** a grep found none left: no "-6 loopback ceiling", "a loop it can see", `probeLoudness` or "probe's limit". The only `-6` left is the `--max-level -6` example.

### 🧪 `LoudnessInvariantTests`

- **Literal values:** the expected ceilings are hard-coded (`ruleCeiling`, `listenerLowersTo`, `expected`). None are read from `LevelRamp`.
- **Combinations covered:** 15 outputs × 7 inputs × 5 `--listener` × 3 `--max-level`, on both the run and the probe path.
  - It asserts the exact ceiling, and that `--listener` only lowers it.
  - It asserts the input never changes the ceiling: one ceiling per output and flag set, across all inputs.
  - It asserts nothing goes above -12 without `--max-level`, and known headphones stay at or below -30.
- **Played-level tests:** these drive the real coordinator and probe through the simulator and check the loudest gain actually scheduled. That includes `--level -3`, so a broken clamp fails them.
- **Mutations checked by reading the code against the tests:** each of these would fail the suite.
  - A fail-open `ispk` check
  - A `max` instead of a `min` for `--listener`
  - `--max-level` combined with `min` instead of replacing
  - Any input-dependent ceiling
  - A remapped BLE or `builtIn` transport

### 🎧 Route watching (data source + jack)

- **One comparison:** `DeviceListeners.routeChange` handles both properties.
  - The baseline is the value read at open: `outInfo.output.dataSource`, and `outJack` read in `open`.
  - It falls back to the value read at registration only when nothing could be read at open.
  - There is an immediate re-check after registering, then one on every notification.
- **Event stream:** events go into the per-open stream created by `beginOpen`. So the immediate re-check is buffered for that run's `supervise`, or for the probe's `withDeadline`.
- **No false-abort path found:**
  - Only the output scope of the playing device is watched, and only where `AudioObjectHasProperty` says the property exists.
  - Every notification is compared with the baseline, never trusted on its own.
  - Between probe reopens the backend is stopped, so each open reads the route in the same state.
- **No missed change found:**
  - A change between two probe opens is caught by the probe's own comparison.
  - A change between open and registration is caught by the immediate re-check, against a value already checked equal to the first open's.

### 📋 Necessity

- The rubric (`necessity-review.md`) was read.
- **`noLoudness` guard (`ChannelProbe.swift:185-187`):** it is unreachable. `channels` is non-empty and `decided` is set at the first open or the call throws.
  - The rubric counts unreachable code as dead code (category 3), not necessity.
  - It costs one line, and the stop rule for this pass excludes it.
  - So no necessity finding was raised.

## Narrative Findings (AI reviewer)

No findings. The previous four fixes hold, the output-only loudness rule is the same on every path and in every user-facing string, and the route-watching changes add no regression.

---

_Reviewed: 2026-11-12T21:36:04Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
