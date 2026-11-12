---
phase: 01-audio-round-trip
fixed_at: 2026-11-12T18:30:00Z
review_path: .planning/phases/01-audio-round-trip/01-REVIEW.md
iteration: 2
findings_in_scope: 13
fixed: 11
skipped: 2
status: partial
---

# Phase 01: Code Review Fix Report

**Fixed at:** 2026-11-12T18:30:00Z
**Source review:** .planning/phases/01-audio-round-trip/01-REVIEW.md
**Iteration:** 2

**Summary:**
- Findings in scope: 13 (2 critical, 11 warning; `fix_scope: critical_warning`)
- Fixed: 11 (8 in iteration 1, WR-04, WR-05 and WR-08 in iteration 2 after the maintainer decided them)
- Skipped: 2 (WR-01, WR-03)
- Info findings (IN-01..IN-09) are out of scope and remain open in REVIEW.md.

**Verification (iteration 2):** ran in an isolated worktree (`.claude/worktrees/rf-01-50604-1794503850`): `swift build`, `swift test` and `scripts/ci-sim.sh` before every commit, then once more in the main checkout after the fast-forward (255 tests in the kit target, 41 in the CLI target, `ci-sim: OK`). The three commits were rebased onto `ccc9be9` (a docs-only commit that landed on main meanwhile) before the fast-forward, so the hashes below are the post-rebase ones. Hardware tests (`just hw-test`, `just bench`) were NOT run, so the HAL paths of WR-04 and WR-05 (per-device buffer read, `'fsiz'` baseline re-arming) are covered only by the simulator and a unit test of the baseline logic, not by a real device.

**Verification (iteration 1):** ran in the isolated worktree (`.claude/worktrees/rf-01-4687-1794500267`), not the main checkout. `swift build`, `swift test` (242 tests in the kit target, 40 in the CLI target, all passing) and `scripts/ci-sim.sh` after each Swift fix, plus the full `scripts/test.sh` at the end. Hardware tests (`just hw-test`, `just bench`) were NOT run: no audio interface was driven.

## Fixed Issues

### CR-01: `--level` accepts NaN and ±inf. NaN bypasses the ceiling and plays NaN samples; inf throws away a finished run

**Status:** fixed: requires human verification (validation logic)
**Files modified:** `Sources/soundping/Commands/RunOptions.swift`, `Sources/SoundPingKit/Engine/HitScheduler.swift`, `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Sources/SoundPingKit/Preflight/ProbePlayer.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Tests/SoundPingKitTests/LevelRampTests.swift`, `Tests/SoundPingKitTests/SchedulerTests.swift`
**Commit:** 367c282
**Applied fix:**
- `--level` must be finite and 0 dBFS or below, checked in `RunOptions.makeRequest` and again in `HitScheduler.validate` (the app will not go through RunOptions).
- `LevelRamp.init` drops a non-finite fixed level, so `min(NaN, ceiling)` can no longer defeat the clamp.
- `ProbePlayer.play` and `RunCoordinator.measure` refuse a non-finite level before computing a gain.
- Confirmed on the CLI: `--level nan` and `--level inf` now exit with `invalidParameters` before any sound plays.
- Note: a positive `--level` (for example `3`) is now refused too. Before, it was silently clamped to the ceiling with a warning. Say so if that stricter behaviour is not wanted.

### CR-02: `--in-channel auto` ignores the headphone ceiling and probes up to -18 dBFS into known headphones

**Status:** fixed: requires human verification (safety ceiling logic; only the pure classification is unit tested, the open-device path needs hardware)
**Files modified:** `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Tests/SoundPingKitTests/ChannelProbeTests.swift`
**Commit:** 992f51a
**Applied fix:**
- After the first `backend.open`, the probe classifies the output device once and keeps the -30 dBFS headphone ceiling for known headphones (built-in output on the `hdpn` data source). Everything else keeps the -18 dBFS unknown ceiling, as before. `--listener` and `--max-level` still win.
- Deviation from the suggested snippet: it called `LevelRamp.classify`, which returns `.loopback` as soon as the probed channel is named "Loop N", and that would have skipped the headphone check. I added `LevelRamp.outputIsHeadphones` (output device only) and used it for both `classify` and the probe.

### WR-02: Calibration and self-test records are written before run.json, so a failed write orphans them

**Status:** fixed: requires human verification (ordering)
**Files modified:** `Sources/SoundPingKit/Engine/RunCoordinator.swift`
**Commit:** 709047d
**Applied fix:** `storeCalibration` became `calibrationToStore`, which only decides and returns the `CalibrationRef` plus the record. `finish` now writes run.json first, then the calibration record, then the self-test record. If run.json cannot be encoded or written, no side file is touched. If a side-file write fails after run.json is written, the run exists with `calibration.stored == true` and no calibration entry; that is a smaller fault than an orphan record, but not zero.

### WR-06: Interactive save of the probed channel can write it into a setup with a different input device

**Status:** fixed: requires human verification (logic)
**Files modified:** `Sources/soundping/Commands/RunCommand.swift`, `Sources/soundping/Commands/RunOptions.swift`, `Tests/soundpingTests/SetupChannelSaveTests.swift` (new)
**Commit:** 7c9f406
**Applied fix:** the "Save in-channel N to setup NAME?" prompt is shown only when the saved setup binds the same output and input UIDs as the probed ones, and `updateSetupChannel` refuses (`setupDeviceMismatch`) otherwise. In the mismatch case the existing hint (`--in-channel auto --save-setup NAME`) is printed. I did not add the "save the whole resolved setup after an explicit confirmation" branch from the suggestion: that is a new prompt flow, so it is left to the existing `--save-setup`.

### WR-07: The `.aborted` event covers only some failures, so the stream contract is inconsistent

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

### WR-04: Two-device runs record only the input device's buffer size

**Status:** fixed: requires human verification (persisted-format change; the HAL read of two different device sizes needs hardware)
**Maintainer decision:** option A, record both sizes with a schema bump (not "refuse a two-device run whose buffers differ", which could block the MacBook speakers-to-mic case).
**Files modified:** `Sources/SoundPingKit/Audio/AudioBackend.swift`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Engine/RunModel.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Sources/SoundPingKit/Engine/HitListener.swift`, `Sources/SoundPingKit/Measurement/ReportedLatency.swift`, `Sources/SoundPingKit/Simulation/SimulatedBackend.swift`, `Sources/SoundPingKit/Store/CalibrationStore.swift`, `Sources/SoundPingKit/Store/ClockSelfTestStore.swift`, `Sources/SoundPingKit/Store/RunStore.swift`, `Sources/soundping/Commands/SelftestCommand.swift`, `Sources/soundping/Render/ErrorReporting.swift`, `Sources/soundping/Render/PrettyRenderer.swift`, `scripts/ci-sim.sh`, and the matching tests (`CalibrationStoreTests`, `ReportedLatencyTests`, `ReportedBlockTests`, and the fixtures that build a `SetupSnapshot`)
**Commit:** faca50f
**Applied fix:**
- `BackendInfo`, `SetupSnapshot` and `CalibrationKey` carry `outputBufferFrames` and `inputBufferFrames`. The HAL backend returns both from `open` (it already computed both). `ReportedLatency.compute` takes both, so each direction uses its own size; `expectedIoOffsetFrames` and `appRoundTripFrames` are now right when they differ. The per-scope `bufferFrames` in `reported` already existed, so the "N + M buffer" text in the round-trip breakdown works unchanged. One-line displays use `SetupSnapshot.bufferSummary` ("128", or "512 out + 128 in" when they differ). Same-device runs behave as before (both fields equal).
- Schema bump: `run.json` is `schemaVersion` 2 and `calibrations.json` is `schemaVersion` 2. `ci-sim.sh` checks the new shape. The error envelope keeps its own `schemaVersion` 1 (its shape did not change); it used to borrow `RunResult.currentSchemaVersion`, so it now has its own constant.
- **Old files, the behaviour I picked:**
  - Old `calibrations.json` (schema 1, one `bufferFrames` in the key) still loads. Its keys read back with `outputBufferFrames = 0`, a size no device has, so they never match a new run: that setup is calibrated once more. The old record stays in the file, unused, and the first write rewrites the file as schema 2. I did not copy the input size into the output field, because for an old two-device calibration the output size is unknown and a guess could make it match a setup it was not measured on.
  - Old `run.json` (schema 1) still decodes: its single buffer reads back as both sizes (exact for the same-device runs of that time; display only, never matched).
  - The clock self-test key stays a single `bufferFrames` (a self-test is same-device only) and now takes the input size.
- `runs list` keeps its single `bufferFrames` column, now documented as the input device's size; the two-device row's `bufferMs` is still nil.
- The simulator gained an optional `outputBufferFrames` (two-device runs only) so tests can make the two devices differ. Tests cover the reported sums with different buffers, the key fields, a two-device run end to end, old-file loading, the old key never matching, and the file moving to schema 2.
- One judgement call: the two-device clock-mapping warm-up waits for `max(output, input)` buffer frames per callback.

### WR-05: A buffer size that settles at start always aborts the run, though the comment says the run adopts it

**Status:** fixed: requires human verification (real-time start-up logic; the driver behaviour it handles needs hardware to observe)
**Maintainer decision:** option A, adopt the size the HAL settles on at start (not "abort with a distinct code").
**Files modified:** `Sources/SoundPingKit/Audio/AudioBackend.swift`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Audio/DeviceListeners.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Sources/SoundPingKit/Simulation/SimulatedBackend.swift`, `Tests/SoundPingKitTests/AbortTests.swift`, `Tests/SoundPingKitTests/SimulationRecoveryTests.swift`
**Commit:** e1ee839
**Applied fix:**
- `AudioBackend.start()` now returns the `BackendInfo` with the buffer sizes the devices settled on. `HALBackend.start()` waits for both IO callbacks as before (the warm-up is silence), re-reads the buffer size of both devices (consistent with WR-04), keeps `open`'s value for a device whose size cannot be read, stores the adopted info, and returns it. `RunCoordinator` takes the snapshot, the reported figures and the calibration key from that started info, so `run.json`, the `armed` event, the reported latency and the key all carry the adopted size. `ChannelProbe` uses the started info too. The misleading comment is replaced.
- The `'fsiz'` listener keeps its per-device baseline in a small lock-protected `BufferBaselines` (listener queue only, never the audio thread). `start()` calls `beginSettling()` before the devices start, which makes a buffer notification not news (it would otherwise have been queued on the event stream and aborted the run later, after the new size was adopted). After the warm-up, `adoptSettledBuffers` sets the new baselines, ends the settling and re-reads each device once, so a change in the gap between the read and the re-arm is still reported. Only a change after that aborts, with the baseline as the `from` value.
- The IOProc code is untouched: still lock-free and allocation-free.
- The simulator gained `settledBufferFrames` (`open` reports the scenario's buffer, `start` returns this one). Tests cover a run that adopts the settled size (setup, reported, key and `armed` event), an abort from a change after adoption, and the baseline re-arming logic.

### WR-08: Bluetooth (and USB headset) outputs get the -18 dBFS "unknown" ceiling

**Status:** fixed: requires human verification (safety ceiling classification)
**Maintainer decision:** option A, a `bluetooth` output gets the headphone ceiling (-30 dBFS); USB outputs stay unknown (no reliable detection). Rationale: a wrong guess costs a Bluetooth-speaker user one flag (`--max-level`); the opposite wrong guess puts -18 dBFS clicks in someone's ears.
**Files modified:** `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Sources/SoundPingKit/Preflight/Preflight.swift`, `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Sources/soundping/Commands/RunOptions.swift`, `Tests/SoundPingKitTests/LevelRampTests.swift`
**Commit:** 2a87421
**Applied fix:**
- `LevelRamp.outputIsHeadphones` is true for the built-in headphone data source or any `bluetooth` transport (read from the device, else from the transport the setup recorded). `classify` uses it, and the channel probe already did (CR-02), so `--in-channel auto` gets the same ceiling. A loopback input (a `Loop` channel or virtual device) is still classed as loopback first, as before.
- The `nothingHeardAtCeiling` fix hint on a headphone listener now says Bluetooth outputs are treated as headphones and names `--max-level` (for example `--max-level -18`) to allow a louder probe on a Bluetooth speaker.
- The ceiling table now lives in the `LevelRamp.classify` doc comment (with the Bluetooth/USB rationale) and in the `--max-level` help text. No other user doc mentions the ceilings (checked README, AGENTS.md, CONTRIBUTING.md).
- Tests cover Bluetooth classification (from the device and from the recorded setup transport), USB staying unknown, the channel probe's kind, a simulated Bluetooth-output ramp that never passes -30 dBFS, and the hint text.

## Skipped Issues

### WR-01: Overload rejection is racy and checks a single frame, not the lost interval

**File:** `Sources/SoundPingKit/Engine/HitListener.swift:7-17, 86-92`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Audio/DeviceListeners.swift`, `Sources/SoundPingKit/Audio/IOCycle.swift`
**Reason:** needs a design change, not a patch: an interval ring in `RTState` written from the IOProc, a new `AudioBackend` requirement (`discontinuities(overlapping:)`) implemented by the HAL backend, the simulator and the test doubles, and a new semantics for HAL `'over'` events. It touches real-time code and cannot be validated without hardware (the simulator path is the one the review says does not exercise the FaultMonitor). Better done as its own planned change.
**Original issue:** the overload check can run before the supervisor has fed the monitor, tests a point instead of an interval, collapses several gaps into one event, and maps `'over'` to the wrong frame.

### WR-03: The stamp log pairs input and output by array index, and the 2^21-entry ring wraps on long runs

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:380`, `Sources/SoundPingKit/Audio/RTState.swift:119, 285-304`, `Sources/SoundPingKit/Audio/IOCycle.swift`
**Reason:** the fix is a redesign of the real-time stamp log (one ring entry per duplex callback, no ordinal pairing for two devices, ring sized from the run length). Real-time code, and the misalignment only shows on hardware. A partial change (restricting the self-test to hits inside the logged range) would hide the ring-wrap symptom without fixing the pairing, so I left both. The cheap mitigation, if wanted sooner: cap `hits` or size `stampCapacity` from the scheduled run length.
**Original issue:** one skipped stamp in either direction shifts every later pair by a buffer, and 2^21 entries is exceeded by a 10 000-hit run.

---

_Fixed: 2026-11-12T18:30:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 2_
