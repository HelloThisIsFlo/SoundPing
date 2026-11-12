---
phase: 01-audio-round-trip
reviewed: 2026-11-12T15:03:25Z
depth: standard
files_reviewed: 87
files_reviewed_list:
  - .github/workflows/ci.yml
  - Package.swift
  - Sources/SoundPingKit/Audio/AudioBackend.swift
  - Sources/SoundPingKit/Audio/DeviceCatalog.swift
  - Sources/SoundPingKit/Audio/DeviceInfo.swift
  - Sources/SoundPingKit/Audio/DeviceListeners.swift
  - Sources/SoundPingKit/Audio/HALBackend.swift
  - Sources/SoundPingKit/Audio/HALProperty.swift
  - Sources/SoundPingKit/Audio/IOCycle.swift
  - Sources/SoundPingKit/Audio/RTState.swift
  - Sources/SoundPingKit/Clock/ClockSelfTest.swift
  - Sources/SoundPingKit/Clock/DeviceTimeline.swift
  - Sources/SoundPingKit/Clock/HostClock.swift
  - Sources/SoundPingKit/Detection/Correlator.swift
  - Sources/SoundPingKit/Engine/HitListener.swift
  - Sources/SoundPingKit/Engine/HitScheduler.swift
  - Sources/SoundPingKit/Engine/RunCoordinator.swift
  - Sources/SoundPingKit/Engine/RunModel.swift
  - Sources/SoundPingKit/Engine/RunRequest.swift
  - Sources/SoundPingKit/Engine/SetupResolver.swift
  - Sources/SoundPingKit/Engine/SoundPingError.swift
  - Sources/SoundPingKit/MIDI/MIDIEndpoints.swift
  - Sources/SoundPingKit/Measurement/ReportedLatency.swift
  - Sources/SoundPingKit/Preflight/ChannelProbe.swift
  - Sources/SoundPingKit/Preflight/LevelRamp.swift
  - Sources/SoundPingKit/Preflight/Preflight.swift
  - Sources/SoundPingKit/Preflight/ProbePlayer.swift
  - Sources/SoundPingKit/Preflight/ResponsibleApp.swift
  - Sources/SoundPingKit/Recipes/Recipe.swift
  - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
  - Sources/SoundPingKit/Simulation/SimulatedCatalog.swift
  - Sources/SoundPingKit/SoundPingKit.swift
  - Sources/SoundPingKit/Stats/Stats.swift
  - Sources/SoundPingKit/Stimulus/Stimulus.swift
  - Sources/SoundPingKit/Store/CalibrationStore.swift
  - Sources/SoundPingKit/Store/ClockSelfTestStore.swift
  - Sources/SoundPingKit/Store/RunLock.swift
  - Sources/SoundPingKit/Store/RunStore.swift
  - Sources/SoundPingKit/Store/Setups.swift
  - Sources/SoundPingKit/Store/StorePaths.swift
  - Sources/soundping/Commands/DevicesCommand.swift
  - Sources/soundping/Commands/OutputOptions.swift
  - Sources/soundping/Commands/PathsCommand.swift
  - Sources/soundping/Commands/RecipesCommand.swift
  - Sources/soundping/Commands/RunCommand.swift
  - Sources/soundping/Commands/RunOptions.swift
  - Sources/soundping/Commands/RunsCommand.swift
  - Sources/soundping/Commands/SelftestCommand.swift
  - Sources/soundping/Commands/SimulationOptions.swift
  - Sources/soundping/Render/ErrorReporting.swift
  - Sources/soundping/Render/ExitCodes.swift
  - Sources/soundping/Render/JSONRenderer.swift
  - Sources/soundping/Render/NDJSONRenderer.swift
  - Sources/soundping/Render/Output.swift
  - Sources/soundping/Render/PrettyRenderer.swift
  - Sources/soundping/Render/Terminal.swift
  - Sources/soundping/SoundPing.swift
  - Tests/SoundPingKitTests/AbortTests.swift
  - Tests/SoundPingKitTests/CalibrationStoreTests.swift
  - Tests/SoundPingKitTests/ChannelProbeTests.swift
  - Tests/SoundPingKitTests/ClockTests.swift
  - Tests/SoundPingKitTests/CorrelatorTests.swift
  - Tests/SoundPingKitTests/HardwareDevicesTests.swift
  - Tests/SoundPingKitTests/HardwareRoundTripTests.swift
  - Tests/SoundPingKitTests/IOCycleTests.swift
  - Tests/SoundPingKitTests/LevelRampTests.swift
  - Tests/SoundPingKitTests/MeasuredFiguresTests.swift
  - Tests/SoundPingKitTests/PreflightTests.swift
  - Tests/SoundPingKitTests/RejectionTests.swift
  - Tests/SoundPingKitTests/ReportedLatencyTests.swift
  - Tests/SoundPingKitTests/ResolverTests.swift
  - Tests/SoundPingKitTests/ResultSchemaTests.swift
  - Tests/SoundPingKitTests/RunStoreTests.swift
  - Tests/SoundPingKitTests/RunStreamTests.swift
  - Tests/SoundPingKitTests/SchedulerTests.swift
  - Tests/SoundPingKitTests/SimulationRecoveryTests.swift
  - Tests/SoundPingKitTests/SmokeTests.swift
  - Tests/SoundPingKitTests/StatsTests.swift
  - Tests/soundpingTests/ErrorReportingTests.swift
  - Tests/soundpingTests/PrettyRendererTests.swift
  - Tests/soundpingTests/ReportedBlockTests.swift
  - Tests/soundpingTests/RunsListTests.swift
  - justfile
  - scripts/bench.sh
  - scripts/ci-sim.sh
  - scripts/cli.sh
  - scripts/test.sh
findings:
  critical: 2
  warning: 11
  info: 9
  total: 22
  necessity: 0
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-11-12T15:03:25Z
**Depth:** standard
**Files Reviewed:** 87
**Status:** issues_found

## Summary

I read every source file in scope in full. Tests and scripts were checked only where they bear on reliability. Two findings were confirmed by running the built CLI against the simulator (`.build/debug/soundping`).

The real-time path is careful. The IOProc work is `@_noLocks`, and buffer sizes are checked against each callback's own buffer list. Discontinuities are rejected through the callback stamps.

The defects sit around that core:

- **🔊 Hearing-safety ceiling (Critical).** It can be bypassed in two ways:
  - `--level nan` plays NaN samples, which the simulator renders at full scale.
  - `--in-channel auto` probes at the -18 dBFS "unknown" ceiling even when the output is headphones (-30 dBFS ceiling).
- **🎯 Accuracy (Warnings).** These touch the number itself:
  - Overload rejection is racy and checks a single frame.
  - The stamp log pairs directions by array index, and its ring wraps on long runs.
  - Two-device runs record only the input device's buffer.
  - Store side files are written before run.json, so a failed write leaves orphan calibration and self-test records. Confirmed with `--level inf`.

The known items (`/private/tmp` store bug, `--in-channel auto` on stereo loops, MacBook speakers → mic) were not re-reported. Nothing found makes them worse.

The necessity rubric (`necessity-review.md`) was read. No finding met its evidence bar, so `necessity: 0`. The unused dependency and helpers below are filed as dead code (Info).

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: `--level` accepts NaN and ±inf. NaN bypasses the ceiling and plays NaN samples; inf throws away a finished run

**File:** `Sources/soundping/Commands/RunOptions.swift:158-163, 364`, `Sources/SoundPingKit/Preflight/LevelRamp.swift:146-148`, `Sources/SoundPingKit/Preflight/ProbePlayer.swift:35`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:257`

**Issue:** `--level` is parsed as `Double` with `.unconditional` parsing and never validated. `Double("nan")` and `Double("inf")` both parse.

- **NaN.** `LevelRamp.firstLevel` is `Swift.min(fixedLevel ?? -48, ceiling)`. `min(NaN, c)` returns NaN, so the ceiling clamp does nothing.
  - The gain becomes `pow(10, NaN/20) = NaN`, and the IOProc mixes `template * NaN` into the output buffer.
  - The `fixed > ceiling` warning is also skipped, because NaN comparisons are false.
  - Reproduced: `soundping run round-trip --simulate --level nan` prints `probe nan dBFS … peak 0.0 dBFS` and fails `inputClipping`. The simulated converter turned NaN into full scale.
  - On real hardware, NaN Float32 reaches the driver's float-to-int conversion, which is undefined. That is exactly what the T-01-28 ceiling exists to prevent.
- **+inf.** The clamp makes it play at the ceiling, but `parameters.levelDbfs = inf` is stored in `RunParameters`.
  - Reproduced with `--level inf --hits 3`: all hits are measured, then `store.write` fails with `EncodingError … inf`.
  - run.json is lost, while `calibrations.json` and `clock-selftest.json` were already written (see WR-02). In `--ndjson` mode the first event already fails to encode.

**Fix:** validate at the edge, and make the ramp NaN-proof as defence in depth:
```swift
// RunOptions.makeRequest
if let level {
  guard level.isFinite, level <= 0 else {
    throw SoundPingError.usage(
      "invalidParameters", "--level must be a finite dBFS value of 0 or below, got \(level)",
      context: ["parameter": "level", "value": String(level)])
  }
  parameters.levelDbfs = level
}
// LevelRamp.init: also guard in the engine (the app will not go through RunOptions)
self.fixedLevel = fixedLevelDbfs.flatMap { $0.isFinite ? $0 : nil }
```
Also reject non-finite levels in `HitScheduler.validate`, and refuse a non-finite gain in `ProbePlayer.play` and `RunCoordinator.measure`.

### CR-02: `--in-channel auto` ignores the headphone ceiling and probes up to -18 dBFS into known headphones

**File:** `Sources/SoundPingKit/Preflight/ChannelProbe.swift:86-99, 188, 206`

**Issue:** `ChannelProbe.run` uses `options.listener ?? .unknown`, so the ceiling is -18 dBFS. Its comment justifies this: "the channel is not known yet, so it cannot say whether it is a loopback".

- **Unknown channel only blocks the loopback question.** Whether the output is headphones depends on the output device alone. `LevelRamp.classify` decides it from `output.transport == "builtIn"` and data source `hdpn`, and `info.outputDevice` is available right after `backend.open`.
- **Result.** With built-in headphones plugged in, the probe climbs -48 → -36 → -24 → -18 dBFS. That is 12 dB above the -30 dBFS headphone ceiling, which LevelRamp says exists "because the test sound reaches a person's ears (T-01-28)".
- **Repeats per channel.** It happens once for every input channel, so a 10-input interface plays up to 10 such ramps.

**Fix:** classify the output before probing, and take the lower of the classified ceiling and the unknown one:
```swift
let info = try await backend.open(channelSetup, templates: [nominal])
let classified = options.listener
  ?? (LevelRamp.classify(setup: channelSetup, output: info.outputDevice, input: info.inputDevice)
      == .headphones ? .headphones : .unknown)
let ceiling = try LevelRamp.resolveCeiling(kind: classified, maxLevelDbfs: options.maxLevelDbfs)
```
Compute this once, from the first `open`, and pass it to `probe(channel:ceiling:…)`.

## Warnings

### WR-01: Overload rejection is racy and checks a single frame, not the lost interval

**File:** `Sources/SoundPingKit/Engine/HitListener.swift:7-17, 86-92`, `Sources/SoundPingKit/Audio/HALBackend.swift:436, 450-461`, `Sources/SoundPingKit/Audio/DeviceListeners.swift:100-104`, `Sources/SoundPingKit/Audio/IOCycle.swift:53-72`

**Issue:** Four defects stack up:

1. **Race.** `waitUntilCaptured` calls `surfaceGaps`, which `yield`s `.overload` to the AsyncStream and returns. `listen` then immediately calls `monitor.hasOverload(in:)`. The monitor is only fed by the separate supervisor child task (`RunCoordinator.swift:137-142`), which may not have run yet.
   - A gap surfaced in the final poll, or an `'over'` notification still queued on the HAL listener queue, is not seen.
   - The HAL `'over'` path has no stamp-based backstop when the sample time does not jump, so the hit is accepted.
   - `AbortTests.anOverloadAtHitTwelveRejectsOnlyThatHit` passes only through `Correlator.hasDiscontinuity` on the simulator's stamps, so the FaultMonitor path is effectively untested.
2. **Point, not interval.** `hasOverload` checks whether a single frame (`lastGapLabel` = first missing label) lies in the window.
   - Suppose a gap starts before `range.lowerBound` and the zero-filled run `[expected, label)` extends into the window. The window then holds synthetic zeros, but neither the point check nor `hasDiscontinuity` rejects it.
   - `hasDiscontinuity` misses it because only the post-gap callback overlaps the window.
3. **Gaps collapse.** `surfaceGaps` yields one event with the latest `lastGapLabel` however much `gapCount` rose since the last poll. Earlier gaps in the same 5 ms poll are lost.
4. **Wrong frame for `'over'`.** It records `inputNextLabel` at notification time, which is later than the glitch. In a two-device run, an output-device overload is also mapped to the current input position rather than to the window of the hit that was playing.

**Fix:**
- Record gaps as intervals (`[expected, label)`) in a small preallocated ring in `RTState`, with start and end labels.
- Have `HitListener` read them directly from the backend after `waitUntilCaptured`: add `func discontinuities(overlapping:) -> Bool` to `AudioBackend`. This takes the AsyncStream hop out of the decision.
- For `'over'`, record the interval `[lastProcessedLabelBeforeNotification - buffer, now)`, and test overlap, not containment.

### WR-02: Calibration and self-test records are written before run.json, so a failed write orphans them

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:439-450`

**Issue:** `finish` runs `CalibrationStore.record`, then `ClockSelfTestStore.record`, then `store.write(result)`.

- If the run.json write throws (encoding error as in CR-01, disk full, permissions), the run folder is removed as empty. The calibration and self-test entries still point at a `runId` that does not exist.
- Reproduced with `--level inf`: the store ends with `calibrations.json` and `clock-selftest.json` and no run.
- Phase 2 trusts `clock-selftest.json` before it trusts host time (D-05), so a record without its run is unverifiable evidence.

**Fix:** encode and write run.json first, then update the side files. Better still, encode everything up front (`RunStore.encodedBytes(for:)`) before any write:
```swift
result.calibration = calibrationRef   // computed, not yet written
let bytes = try RunStore.encodedBytes(for: result)    // fails before touching the store
try bytes.write(to: folder.appendingPathComponent("run.json"), options: .atomic)
try CalibrationStore.record(record, in: store.paths.calibrations)
if let selfTest { try ClockSelfTestStore.record(entry, in: store.paths.clockSelfTest) }
```

### WR-03: The stamp log pairs input and output by array index, and the 2^21-entry ring wraps on long runs

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:380`, `Sources/SoundPingKit/Audio/RTState.swift:119, 285-304`, `Sources/SoundPingKit/Audio/IOCycle.swift:33-46, 116-127`

**Issue:**

- **Index pairing.** `ioOffsets = zip(log.input, log.output)` and `callbackStamps(covering:)` assume input ordinal N and output ordinal N are the same callback. That breaks as soon as one direction skips logging:
  - `ioCycleInput` returns early without a stamp on a channel-count mismatch, `frames > capacity`, a nil `mData` or a non-finite sample time.
  - `ioCycleOutput` returns early when `headChannels == 0` or `frames == 0`.
  - After one such skip every later pair is off by one callback. The median Δio then moves by a whole buffer, and so do `appRoundTrip` and the stored calibration headline.
- **Ring wrap.** `stampCapacity = 1 << 21` callbacks is about 93 min at 48 kHz / 128 and about 23 min at buffer 32.
  - A 10 000-hit run (allowed by `HitScheduler.validate`) exceeds it.
  - Early hits then sit before the logged range, and `ClockSelfTest` extrapolates the timeline across the whole run.
  - Clock drift over that span inflates Δ, so a healthy device gets a FAIL written to `clock-selftest.json`.

**Fix:**
- On a duplex device, log both directions in one ring entry written by the single callback, so they cannot misalign.
- For two devices, never pair by ordinal.
- Size the stamp ring from the scheduled run length (hits × spacingMax / buffer, plus margin), or cap `hits` so the run fits.
- At minimum, evaluate the self-test only on hits whose frames fall inside the logged range.

### WR-04: Two-device runs record only the input device's buffer size

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:114-119, 172, 178`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:226-228, 410-413, 461-463`, `Sources/SoundPingKit/Measurement/ReportedLatency.swift:448-455`

**Issue:** `applyBuffer` can return different sizes for the two devices, because each clamps to its own range.

- **Lost value.** `BackendInfo.bufferFrames` is set to `inBuffer` only, so `outBuffer` is dropped.
- **Wrong reported figures.** `ReportedLatency.compute` uses that one value for both directions ("which both directions share"), so `appRoundTripFrames` and `expectedIoOffsetFrames` are wrong whenever they differ.
- **Ambiguous calibration key.** `CalibrationKey.bufferFrames` and `SetupSnapshot.bufferFrames` omit the output buffer, so two different configurations map to one key.

**Fix:**
- Carry `outputBufferFrames` and `inputBufferFrames` in `BackendInfo`, `SetupSnapshot` and `CalibrationKey` (schema bump).
- Pass both into `ReportedLatency.compute`.
- Alternatively, refuse a two-device run whose applied buffers differ.

### WR-05: A buffer size that settles at start always aborts the run, though the comment says the run adopts it

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:335-343`

**Issue:** The comment reads "The buffer the HAL settled on after the start is the one the run measures at", but the code does something else.

- It yields `.bufferSizeChanged`, which `RunCoordinator.abortError` turns into a `deviceChanged` abort (exit 75).
- `reportedBuffer` and `BackendInfo.bufferFrames` are never updated.
- A driver that applies the per-process size only when IO starts therefore always fails with "device changed buffer size from X to Y frames", although nothing changed during the run.

**Fix:** decide which behaviour is meant.

- **Adopt:** re-read the size after the first callbacks, update the state, return it through a `BackendInfo` refresh, and re-arm the `'fsiz'` listener's baseline.
- **Abort:** use a distinct code (`bufferSizeNotHonoured`) with a fix hint, and correct the comment.

### WR-06: Interactive save of the probed channel can write it into a setup with a different input device

**File:** `Sources/soundping/Commands/RunCommand.swift:96-104`, `Sources/soundping/Commands/RunOptions.swift:325-335`

**Issue:** Take `soundping run … --setup foo --input X --in-channel auto` and answer "y" at the prompt.

- `updateSetupChannel` sets `foo.inChannel` to the index found on device X.
- `foo.input` still names the setup's original device, so the stored channel now refers to a different device.
- The next `--setup foo` run passes `pickInChannel` validation whenever the index exists, and measures the wrong channel.

**Fix:**
- Only offer the in-place update when `resolved.input.uid == binding.input.uid` and the output matches.
- Otherwise save the whole resolved setup (`persistSetup(resolved, as: name)`) after an explicit confirmation that names the device change.

### WR-07: The `.aborted` event covers only some failures, so the stream contract is inconsistent

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:69-88, 99-103, 230-235`

**Issue:** `fail()` says "A named failure is announced on the stream, then thrown". Only preflight and ramp failures and device events are announced, though.

Failures that are thrown without `.aborted`:
- `backend.open`: `sampleRateMismatch`, `unsupportedStreamFormat`, `deviceGone`, `bufferSizeNotApplied`
- `backend.start`: `ioStopped` when no callbacks arrive
- `prepareClockMapping`: `timelineUnavailable`
- store write failures in `finish`

The app is meant to read this one stream (D-03), and an NDJSON consumer that keys on `aborted` misses these.

**Fix:** wrap the whole `Session.run` body in one `catch let error as SoundPingError { continuation.yield(.aborted(error)); throw error }`, and drop the per-site `fail()` calls. Keep `CancellationError` silent.

### WR-08: Bluetooth (and USB headset) outputs get the -18 dBFS "unknown" ceiling

**File:** `Sources/SoundPingKit/Preflight/LevelRamp.swift:84-99`

**Issue:** `classify` returns `.headphones` only for `builtIn` + `hdpn`. Every other output gets `.unknown`, with a ceiling 12 dB above the headphone one.

- The stated reason ("an interface headphone jack looks like a line out") applies to audio interfaces.
- A `bluetooth` output is nearly always earbuds or headphones. AirPods are the common MacBook case.

**Fix:** classify `transport == "bluetooth"` as `.headphones`. Consider the same for USB devices whose output data source or terminal type reports a headphone or headset. Document the rule in the ceiling table.

### WR-09: `soundping recipes` advertises a start level the engine never uses

**File:** `Sources/SoundPingKit/Recipes/Recipe.swift:265, 296`, `Sources/soundping/Commands/RecipesCommand.swift:52, 62`, `Sources/SoundPingKit/Preflight/LevelRamp.swift:58`

**Issue:** `Recipe.startLevelDbfs = -30` is printed by `recipes` ("start level -30 dBFS", confirmed by running it) and published in `recipes --json` defaults. Nothing in the engine reads it: the ramp starts at `LevelRamp.firstProbeDbfs = -48`. Agents told to read `recipes` instead of guessing get a wrong default level.

**Fix:** either remove `startLevelDbfs` from `Recipe` and the recipes output, or make `LevelRamp` start from `recipe.startLevelDbfs` clamped to the ceiling. Then report the value the ramp really uses.

### WR-10: CI job has no `timeout-minutes`

**File:** `.github/workflows/ci.yml:11-12`

**Issue:** `build-and-test` runs on `macos-26` with no job-level `timeout-minutes`.

- `scripts/ci-sim.sh` starts a background lock holder that sleeps 60 s.
- A hung simulated run would also wait forever, since the simulator's fatal faults sleep in a loop until cancelled.
- A stuck job holds a macOS runner for the 6-hour default.

**Fix:** add `timeout-minutes: 30` under `build-and-test:`.

### WR-11: `bench.sh` aborts on any run with zero valid hits

**File:** `scripts/bench.sh:96-99, 214-223`

**Issue:** A run that fails the gate (exit 3) still prints its RunResult, with `"median": null`.

- `h["median"]["frames"]` then raises `TypeError`, so the heredoc python exits non-zero.
- Under `set -euo pipefail` that kills the whole bench, so section 6 (results) never prints.
- This is the very case (a broken cable, a deaf path) the bench should report. The results table at lines 214-223 has the same unguarded indexing.

**Fix:** guard every stat access, e.g. `med = (h.get("median") or {}).get("frames")`, and print `-` when it is missing. Or end the heredocs with `|| true` so one bad run cannot abort the bench.

## Info

### IN-01: A probe rejected for an overload or a discontinuity counts as "not heard", so the ramp climbs 6 dB

**File:** `Sources/SoundPingKit/Preflight/ProbePlayer.swift:39-45`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:320-321`, `Sources/SoundPingKit/Preflight/LevelRamp.swift:173-174`

**Issue:** An overloaded probe reports confidence 0 and peak -200 dBFS. The ramp treats it as faint and steps up, so the locked level can end 6 dB or more louder than needed (still at or below the ceiling). Repeated glitches end in `nothingHeardAtCeiling` with a misleading fix hint.

**Fix:** when `heard.overloaded` or the detection is `.rejected(.discontinuity)`, replay the probe at the same level instead of calling `ramp.record`.

### IN-02: The same-device window has no pre-roll, so a near-zero path is rejected as `outsideWindow`

**File:** `Sources/SoundPingKit/Engine/HitListener.swift:83-85`, `Sources/SoundPingKit/Detection/Correlator.swift:258`

**Issue:**
- The same-device window starts exactly at `outputFrame`.
- `Correlator` rejects a peak at lag 0 (`top > 0`).
- So a path under one frame, or a driver that labels the input slightly early, is rejected rather than measured.
- The pre-roll the comment describes is applied to two-device runs only.

**Fix:** apply `prerollFrames` to the same-device window as well.

### IN-03: `requireFloat32` checks only the first stream of a scope

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:219-228`

**Issue:**
- Multi-stream devices can carry the selected channel in a later stream with another virtual format.
- That stream would then be read as Float32 noise.
- A failed property read also passes silently (`else { return }`).

**Fix:** check the stream of every selected channel slot (`slot.buffer`). Treat an unreadable format as an error.

### IN-04: Doc comments contradict the code

**File:** `Sources/SoundPingKit/Audio/HALProperty.swift:4-5`, `Sources/SoundPingKit/Store/RunStore.swift:190-198`

**Issue:**
- **HALProperty.** It says "nothing in this plan ever calls `AudioObjectSetPropertyData`", but `HALBackend.applyBuffer` does.
- **`RunStore.runFile`.** It says "nothing outside `runs/` is read (T-01-34)", but an absolute path anywhere is accepted and read. That behaviour is fine for a local CLI; the threat-model claim is not.

**Fix:** correct both comments, and update the T-01-34 wording in the security audit.

### IN-05: Dead code and an unused dependency

**File:** `Package.swift:37, 42`, `Sources/soundping/Render/ExitCodes.swift:32-34`, `Sources/SoundPingKit/Audio/HALProperty.swift:16-24`, `Sources/SoundPingKit/Audio/DeviceListeners.swift:52-53`

**Issue:**
- `swift-log` is declared and linked into SoundPingKit, but nothing imports `Logging`.
- `ExitCodes.exitCode(for:)` and `HALProperty.has` are never called.
- `DeviceListeners.refused` is counted but never read. A listener the HAL refused (e.g. `'livn'`) silently means device changes no longer abort the run.

**Fix:**
- Drop the unused dependency and helpers until they are used.
- Surface `refused > 0` as a run warning (preflight warnings) so a half-watched run is visible.

### IN-06: Duplicated logic

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:182-187`, `Sources/SoundPingKit/Store/Setups.swift:56-109`

**Issue:**
- `HALBackend.preflight(_:_:context:)` duplicates `SoundPingError.preflight`.
- `Setups.load` and `Setups.save` re-implement `VersionedFile.load` and `VersionedFile.save` (ClockSelfTestStore.swift) line for line, with a different decoder.

**Fix:** use `SoundPingError.preflight`. Route `Setups` through `VersionedFile`.

### IN-07: Several stdout writes bypass `Output`'s guarded write

**File:** `Sources/soundping/Render/JSONRenderer.swift:4-6`, `Sources/soundping/Commands/RunsCommand.swift:50, 106`, `Sources/soundping/Commands/DevicesCommand.swift:9`

**Issue:**
- These call the deprecated non-throwing `FileHandle.write(_:)`, which raises an Objective-C exception on a write error.
- `Output.write` uses `try? write(contentsOf:)` specifically so "a reader that went away must not crash the tool".

**Fix:** route all of them through `Output.writeData`.

### IN-08: The IOProc stamps `mHostTime` and `mSampleTime` without checking `mFlags`

**File:** `Sources/SoundPingKit/Audio/IOCycle.swift:45-46, 85-87, 119, 129-131`

**Issue:**
- A timestamp without `kAudioTimeStampHostTimeValid` may carry host time 0.
- That point then enters the per-device least-squares fit and the self-test.

**Fix:** skip a stamp, and count a gap, unless both `sampleTimeValid` and `hostTimeValid` are set. Reading `mFlags` is RT-safe.

### IN-09: `HALBackend` is not reusable after `stop()`, though ChannelProbe reopens it

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:47-49, 163-175, 511-523`

**Issue:**
- `stop()` finishes `eventSink` for good.
- `open()` does not reset `gapsReported` or `stallReported`.
- ChannelProbe's open → stop → open sequence works only because it never reads events.
- A long-lived app that reuses one backend for a second run would get an already-finished `events` stream. `supervise` would then see `.eventsEnded`, and device changes would stop aborting runs.

**Fix:** make the backend single-use (throw on a second `open`), or recreate the stream and reset the per-open state in `open()`.

---

_Reviewed: 2026-11-12T15:03:25Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
