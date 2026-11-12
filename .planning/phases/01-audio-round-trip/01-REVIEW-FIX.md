---
phase: 01-audio-round-trip
fixed_at: 2026-11-12T16:40:00Z
review_path: .planning/phases/01-audio-round-trip/01-REVIEW.md
iteration: 1
findings_in_scope: 13
fixed: 8
skipped: 5
status: partial
---

# Phase 01: Code Review Fix Report

**Fixed at:** 2026-11-12T16:40:00Z
**Source review:** .planning/phases/01-audio-round-trip/01-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 13 (2 critical, 11 warning; `fix_scope: critical_warning`)
- Fixed: 8
- Skipped: 5
- Info findings (IN-01..IN-09) are out of scope and remain open in REVIEW.md.

**Verification:** ran in the isolated worktree (`.claude/worktrees/rf-01-4687-1794500267`), not the main checkout. `swift build`, `swift test` (242 tests in the kit target, 40 in the CLI target, all passing) and `scripts/ci-sim.sh` after each Swift fix, plus the full `scripts/test.sh` at the end. Hardware tests (`just hw-test`, `just bench`) were NOT run: no audio interface was driven.

## Fixed Issues

### CR-01: `--level` accepts NaN and +-inf

**Status:** fixed: requires human verification (validation logic)
**Files modified:** `Sources/soundping/Commands/RunOptions.swift`, `Sources/SoundPingKit/Engine/HitScheduler.swift`, `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Sources/SoundPingKit/Preflight/ProbePlayer.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Tests/SoundPingKitTests/LevelRampTests.swift`, `Tests/SoundPingKitTests/SchedulerTests.swift`
**Commit:** 367c282
**Applied fix:**
- `--level` must be finite and 0 dBFS or below, checked in `RunOptions.makeRequest` and again in `HitScheduler.validate` (the app will not go through RunOptions).
- `LevelRamp.init` drops a non-finite fixed level, so `min(NaN, ceiling)` can no longer defeat the clamp.
- `ProbePlayer.play` and `RunCoordinator.measure` refuse a non-finite level before computing a gain.
- Confirmed on the CLI: `--level nan` and `--level inf` now exit with `invalidParameters` before any sound plays.
- Note: a positive `--level` (for example `3`) is now refused too. Before, it was silently clamped to the ceiling with a warning. Say so if that stricter behaviour is not wanted.

### CR-02: `--in-channel auto` ignores the headphone ceiling

**Status:** fixed: requires human verification (safety ceiling logic; only the pure classification is unit tested, the open-device path needs hardware)
**Files modified:** `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Tests/SoundPingKitTests/ChannelProbeTests.swift`
**Commit:** 992f51a
**Applied fix:**
- After the first `backend.open`, the probe classifies the output device once and keeps the -30 dBFS headphone ceiling for known headphones (built-in output on the `hdpn` data source). Everything else keeps the -18 dBFS unknown ceiling, as before. `--listener` and `--max-level` still win.
- Deviation from the suggested snippet: it called `LevelRamp.classify`, which returns `.loopback` as soon as the probed channel is named "Loop N", and that would have skipped the headphone check. I added `LevelRamp.outputIsHeadphones` (output device only) and used it for both `classify` and the probe.

### WR-02: Calibration and self-test records written before run.json

**Status:** fixed: requires human verification (ordering)
**Files modified:** `Sources/SoundPingKit/Engine/RunCoordinator.swift`
**Commit:** 709047d
**Applied fix:** `storeCalibration` became `calibrationToStore`, which only decides and returns the `CalibrationRef` plus the record. `finish` now writes run.json first, then the calibration record, then the self-test record. If run.json cannot be encoded or written, no side file is touched. If a side-file write fails after run.json is written, the run exists with `calibration.stored == true` and no calibration entry; that is a smaller fault than an orphan record, but not zero.

### WR-06: Interactive save writes the probed channel into a setup with another input device

**Status:** fixed: requires human verification (logic)
**Files modified:** `Sources/soundping/Commands/RunCommand.swift`, `Sources/soundping/Commands/RunOptions.swift`, `Tests/soundpingTests/SetupChannelSaveTests.swift` (new)
**Commit:** 7c9f406
**Applied fix:** the "Save in-channel N to setup NAME?" prompt is shown only when the saved setup binds the same output and input UIDs as the probed ones, and `updateSetupChannel` refuses (`setupDeviceMismatch`) otherwise. In the mismatch case the existing hint (`--in-channel auto --save-setup NAME`) is printed. I did not add the "save the whole resolved setup after an explicit confirmation" branch from the suggestion: that is a new prompt flow, so it is left to the existing `--save-setup`.

### WR-07: `.aborted` covers only some failures

**Status:** fixed: requires human verification (stream contract)
**Files modified:** `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Tests/SoundPingKitTests/AbortTests.swift`
**Commit:** 7753d3b
**Applied fix:** `Session.run` is now one wrapper that yields `.aborted` for any thrown error and rethrows it; `CancellationError` stays silent. The per-site `fail()` helper and the supervisor's own yield are gone, so nothing is announced twice (the existing `abortCodes == ["sampleRateChanged"]` test still holds). Errors that are not `SoundPingError` (for example an `EncodingError`) are announced as `internal`, the same mapping `ErrorReporting` uses. Usage errors such as `invalidParameters` now also appear as `.aborted` on the stream before the throw; a test covers that.

### WR-09: `soundping recipes` advertises a start level the engine never uses

**Status:** fixed
**Files modified:** `Sources/SoundPingKit/Recipes/Recipe.swift`, `Sources/soundping/Commands/RecipesCommand.swift`
**Commit:** 20c3793
**Applied fix:** removed the dead `Recipe.startLevelDbfs` (-30). `recipes` now reports the level the ramp really starts at (`LevelRamp.firstProbeDbfs`, -48): the text line says "level ramp starts at -48 dBFS" and the JSON key `defaults.startLevelDbfs` is replaced by `defaults.rampStartLevelDbfs`. This is a JSON key change in `recipes --json`; I chose it over making the ramp start at -30 because that would have made the first probe 18 dB louder, a safety-relevant change.

### WR-10: CI job has no `timeout-minutes`

**Status:** fixed
**Files modified:** `.github/workflows/ci.yml`
**Commit:** a6c1f87
**Applied fix:** `timeout-minutes: 30` on `build-and-test`. The value is my pick, not the reviewer's number beyond the suggested 30; a normal run takes a few minutes.

### WR-11: `bench.sh` aborts on any run with zero valid hits

**Status:** fixed
**Files modified:** `scripts/bench.sh`
**Commit:** 964907b
**Applied fix:** every stat access in the per-run summary and the results table is guarded; a null median, jitter or missing stat prints `-`. Checked with `BENCH_SIMULATE=1` (unchanged output) and with a hand-edited run.json holding null medians (the table prints `0/100` and `-` instead of raising).

## Skipped Issues

### WR-01: Overload rejection is racy and checks a single frame

**File:** `Sources/SoundPingKit/Engine/HitListener.swift:7-17, 86-92`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Audio/DeviceListeners.swift`, `Sources/SoundPingKit/Audio/IOCycle.swift`
**Reason:** needs a design change, not a patch: an interval ring in `RTState` written from the IOProc, a new `AudioBackend` requirement (`discontinuities(overlapping:)`) implemented by the HAL backend, the simulator and the test doubles, and a new semantics for HAL `'over'` events. It touches real-time code and cannot be validated without hardware (the simulator path is the one the review says does not exercise the FaultMonitor). Better done as its own planned change.
**Original issue:** the overload check can run before the supervisor has fed the monitor, tests a point instead of an interval, collapses several gaps into one event, and maps `'over'` to the wrong frame.

### WR-03: Stamp log pairs input and output by array index; the stamp ring wraps on long runs

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:380`, `Sources/SoundPingKit/Audio/RTState.swift:119, 285-304`, `Sources/SoundPingKit/Audio/IOCycle.swift`
**Reason:** the fix is a redesign of the real-time stamp log (one ring entry per duplex callback, no ordinal pairing for two devices, ring sized from the run length). Real-time code, and the misalignment only shows on hardware. A partial change (restricting the self-test to hits inside the logged range) would hide the ring-wrap symptom without fixing the pairing, so I left both. The cheap mitigation, if wanted sooner: cap `hits` or size `stampCapacity` from the scheduled run length.
**Original issue:** one skipped stamp in either direction shifts every later pair by a buffer, and 2^21 entries is exceeded by a 10 000-hit run.

### WR-04: Two-device runs record only the input device's buffer size

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:114-119, 172, 178`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Sources/SoundPingKit/Measurement/ReportedLatency.swift:448-455`
**Reason:** needs a product decision. The two options are a schema bump of `BackendInfo`, `SetupSnapshot` and `CalibrationKey` (persisted formats), or refusing a two-device run whose applied buffers differ. The refusal could block the MacBook speakers-to-mic bench case, where the built-in devices may clamp differently, and I cannot tell from the repo docs which is wanted.
**Original issue:** `outBuffer` is dropped, so reported figures and the calibration key are wrong or ambiguous when the two devices apply different sizes.

### WR-05: A buffer size that settles at start always aborts the run

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:335-343`
**Reason:** needs a product decision between adopting the settled size (refresh `BackendInfo` and the `'fsiz'` baseline after start) and aborting with a distinct code. Both change run behaviour on real drivers and cannot be checked without hardware.
**Original issue:** the comment says the run adopts the size the HAL settled on, but the code yields `.bufferSizeChanged`, which aborts with exit 75.

### WR-08: Bluetooth and USB headset outputs get the -18 dBFS "unknown" ceiling

**File:** `Sources/SoundPingKit/Preflight/LevelRamp.swift:84-99`
**Reason:** product decision. Treating every `bluetooth` output as headphones applies the -30 dBFS ceiling to Bluetooth speakers too, which may leave them unable to hear the probe; the USB headset rule has no defined detection. The ceiling table is a user-facing safety/usability trade-off, so it is left to the maintainer.
**Original issue:** Bluetooth outputs, nearly always earbuds, get a ceiling 12 dB above the headphone one.

---

_Fixed: 2026-11-12T16:40:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
