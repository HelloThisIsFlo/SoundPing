---
phase: 01-audio-round-trip
reviewed: 2026-11-12T17:38:50Z
depth: standard
files_reviewed: 95
files_reviewed_list:
  - .github/workflows/ci.yml
  - .gitignore
  - AGENTS.md
  - CLA.md
  - CONTRIBUTING.md
  - LICENSE
  - Package.resolved
  - Package.swift
  - README.md
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
  - Tests/soundpingTests/SetupChannelSaveTests.swift
  - justfile
  - scripts/bench.sh
  - scripts/ci-sim.sh
  - scripts/cli.sh
  - scripts/test.sh
findings:
  critical: 1
  warning: 4
  info: 13
  total: 18
  necessity: 0
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-11-12T17:38:50Z
**Depth:** standard
**Files Reviewed:** 95
**Status:** issues_found

## Summary

Second full review of Phase 1, after two fix rounds. Every Swift source file was read in full; the fix-round diffs (`26c9043..HEAD`) were read line by line; tests, scripts and docs were checked where they bear on correctness or reliability. One read-only command was run: `soundping devices --json`, to see what the local HAL reports for transport and data source. Nothing was built, tested or modified.

### ✅ Fix verification (the 11 fixed findings)

- **Hold, no regression found:** CR-01, WR-04, WR-05, WR-06, WR-07, WR-09, WR-10, WR-11.
  - CR-01: `--level` is now checked at three layers (`RunOptions.makeRequest`, `HitScheduler.validate`, `LevelRamp.init`/`ProbePlayer`/`measure`).
  - WR-04: old schema-1 `run.json` and `calibrations.json` still decode, and legacy keys can never match.
  - WR-05: the settling window is closed by a re-read after adoption, and the IOProc code is unchanged.
- **Hold, with a residual next to them:**
  - **CR-02** holds for `--in-channel auto`. The measured run's own classifier (`LevelRamp.classify`) still lets the loopback rule override a headphone output → **CR-03**.
  - **WR-08** holds for Bluetooth. The built-in branch fails open when the `hdpn` data source is missing → **WR-12**.
  - **WR-02** holds for the run.json-first order. A side-file write that fails afterwards turns a saved run into a reported failure → **IN-13**.

### 🔊 Key concerns this pass

- **Hearing safety (Critical, CR-03, also raised by Codex).**
  - A virtual input, or an input channel whose name starts with "Loop", classifies the run as `loopback` before the output is looked at.
  - With built-in headphones or Bluetooth output, the ramp may then climb to -6 dBFS: 24 dB above the -30 dBFS headphone ceiling.
  - This machine has exactly such inputs (`Loopback: Ableton In`, transport `virtual`).
- **Accuracy (WR-01, WR-03 still open; skipped deliberately as real-time redesigns).**
  - Codex independently confirms the WR-03 pairing defect.
- **IN-02 raised to Warning.**
  - The bench itself expects a virtual loopback to measure "close to 0 frames" (`scripts/bench.sh:177`).
  - A zero-frame path peaks at lag 0, which the correlator rejects. Every probe then reads as unheard, and the ramp ends in `nothingHeardAtCeiling`.

### 🤝 Codex lane

All 8 Codex claims were re-read against the source and confirmed:

| Codex claim | Where it went |
|---|---|
| P1 loopback beats headphones | new CR-03 |
| P2 zero-latency loopback | folded into IN-02 (escalated) |
| P2 stamp pairing | folded into WR-03 |
| P2 first-stream format | folded into IN-03 |
| P2 backend reuse after stop | folded into IN-09, with a new hang angle |
| P2 sim flags trap | new IN-12 |
| P2 channel probe ignores device events | new IN-10 |
| P2 `minValidFraction` unvalidated | new IN-11 |

### 📋 Necessity

The necessity rubric (`necessity-review.md`) was read. The new guards from CR-01 are deliberate defence in depth at a trust boundary (the app will not go through `RunOptions`), so they are not necessity findings. `necessity: 0`.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-03: A virtual or "Loop" input overrides the headphone ceiling: the ramp can reach -6 dBFS in headphones (external: codex)

**File:** `Sources/SoundPingKit/Preflight/LevelRamp.swift:51-62`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:121-126`

**Issue:** `classify` returns `.loopback` as soon as the input transport is `virtual` or the input channel name starts with "loop". Only then does it look at the output:

```swift
let looped = setup.inChannelName?.lowercased().hasPrefix("loop") == true
if looped || inputTransport == "virtual" { return .loopback }   // -6 dBFS
...
if outputIsHeadphones(setup: setup, output: output) { return .headphones }  // -30 dBFS
```

- **The trigger is a two-device run.** The output is built-in headphones (`hdpn`) or any Bluetooth device. The input is a virtual device, e.g. `Loopback: Ableton In`, which `soundping devices` reports as `virtual` on this machine. Or it is an interface channel named "Loopback 1".
- **Why the ramp climbs instead of stopping.**
  - The sound goes to the person's ears, not into the virtual input.
  - So the chirp is never heard. Exact-zero input would stop the ramp with `inputDigitalSilence` at the first probe.
  - But a virtual device that carries anything (a DAW's audio, another app) is not silent. The ramp then steps -48 → -42 → … → **-6 dBFS**, 24 dB above the headphone ceiling, and finally fails with `nothingHeardAtCeiling`.
- **Same class of bug as CR-02**, which the maintainer fixed for `--in-channel auto` by classifying on the output alone (`ChannelProbe.listenerKind`).
  - The fixer noted the ordering problem in 01-REVIEW-FIX.md ("returns `.loopback` as soon as the probed channel is named 'Loop N', and that would have skipped the headphone check").
  - That fix only covered the probe. The measured run still goes through `classify`.
- **The speaker ceiling has the same gap.** A built-in speaker output with a virtual input gets -6 instead of -12 dBFS.
- **No test catches it.** `LevelRampTests.aLoopChannelOrAVirtualInputIsALoopback` only uses duplex devices, so no test pins the combination.
- Also raised by Codex (P1); verified against the source.

**Fix:** a loop can only return what the output played when the output feeds the input. So the output's own ceiling must win whenever the output reaches a person:
```swift
public static func classify(setup: ResolvedSetup, output: DeviceInfo?, input: DeviceInfo?) -> ListenerKind {
  // Ears first: an output a person hears keeps its own ceiling whatever the input is (T-01-28).
  if outputIsHeadphones(setup: setup, output: output) { return .headphones }
  let outputTransport = output?.transport ?? setup.output.transport
  let inputTransport = input?.transport ?? setup.input.transport
  let sameDevice = setup.output.uid == setup.input.uid
  let looped = setup.inChannelName?.lowercased().hasPrefix("loop") == true
  // A loop needs the output to feed the input: one device (interface loop channel, virtual
  // duplex) or a virtual output. A physical output into some other virtual input is not a loop.
  if (sameDevice && (looped || inputTransport == "virtual")) || outputTransport == "virtual" {
    return .loopback
  }
  if outputTransport == "builtIn" { return .speaker }
  return .unknown
}
```
Add tests for `hdpn`, Bluetooth and built-in speakers combined with a virtual input and with a "Loop" channel on another device.

## Warnings

### WR-01: Overload rejection is racy and checks a single frame, not the lost interval

**File:** `Sources/SoundPingKit/Engine/HitListener.swift:5-17, 88-95`, `Sources/SoundPingKit/Audio/HALBackend.swift:455-489`, `Sources/SoundPingKit/Audio/DeviceListeners.swift:139-144`, `Sources/SoundPingKit/Audio/IOCycle.swift:54-71`

**Status:** still open. Skipped deliberately in fix iteration 2, because it is a real-time redesign that needs hardware. The code is unchanged since the first review; only the line numbers moved.

**Issue:** four defects stack up.

1. **Race.** `waitUntilCaptured` → `surfaceGaps` yields `.overload` to the AsyncStream and returns. `listen` then immediately calls `monitor.hasOverload(in:)` (HitListener.swift:91).
   - The monitor is only fed by the supervisor child task (RunCoordinator.swift:142-151), which may not have run yet.
   - The HAL `'over'` path has no stamp-based backstop when the sample time does not jump.
2. **Point, not interval.** `hasOverload` checks whether one frame (`lastGapLabel`, the first missing label) lies in the window.
   - A gap that starts before the window and zero-fills into it is missed.
   - `hasDiscontinuity` misses it too, because only the post-gap callback overlaps the window.
3. **Gaps collapse.** `surfaceGaps` yields one event with the latest `lastGapLabel`, however far `gapCount` rose since the last 5 ms poll.
4. **Wrong frame for `'over'`.** It records `inputNextLabel` at notification time, which is later than the glitch. A two-device run also maps an output-device overload onto the current input position.

**Fix:**
- Record gaps as `[expected, label)` intervals in a preallocated ring in `RTState`.
- Have `HitListener` query the backend directly after `waitUntilCaptured` (`discontinuities(overlapping:)` on `AudioBackend`). This takes the AsyncStream hop out of the decision.
- For `'over'`, record an interval that covers the buffer before the notification, and test overlap, not containment.

### WR-03: The stamp log pairs input and output by array index, and the 2^21-entry ring wraps on long runs

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:388`, `Sources/SoundPingKit/Audio/RTState.swift:119, 285-304`, `Sources/SoundPingKit/Audio/IOCycle.swift:33-46, 116-127`

**Status:** still open. Skipped deliberately in fix iteration 2 (real-time redesign). Also raised independently by Codex (P2), which confirms the pairing defect.

**Issue:**

- **Index pairing.** `ioOffsets = zip(log.input, log.output)` (RunCoordinator.swift:388) and `callbackStamps(covering:)` (RTState.swift:285-304) assume that input ordinal N and output ordinal N are the same callback. That breaks as soon as one direction skips logging:
  - `ioCycleInput` returns early without a stamp on a channel-count mismatch, `frames > capacity`, a nil `mData` or a non-finite sample time.
  - `ioCycleOutput` returns early on `headChannels == 0` or `frames == 0`.
  - After one such skip, every later pair is off by one callback. The median Δio then moves by a whole buffer, and so do `appRoundTrip` (= path + median Δio, RunCoordinator.swift:393-395) and the stored calibration headline.
- **Ring wrap.** `stampCapacity = 1 << 21` callbacks is about 93 min at 48 kHz / 128 frames, and about 23 min at 32 frames.
  - A 10 000-hit run (allowed by `HitScheduler.validate`) can exceed it.
  - The self-test then extrapolates the timeline over hits outside the logged range, and can write a false FAIL to `clock-selftest.json`.

**Fix:**
- On a duplex device, log both directions in one ring entry written by the single callback.
- Never pair by ordinal across two devices.
- Size the ring from the scheduled run length, or cap `hits`.
- At minimum, evaluate the self-test only on hits inside the logged range.

### IN-02: The same-device window has no pre-roll, so a near-zero path is rejected as `outsideWindow`

**File:** `Sources/SoundPingKit/Engine/HitListener.swift:85-87`, `Sources/SoundPingKit/Detection/Correlator.swift:82`, `scripts/bench.sh:175-179`

**Severity:** raised from Info to Warning in this pass. The ID is kept so the disposition ledger carries over.

**Issue:**
- **The window starts exactly at the output frame.** For a same-device run it begins at `hit.outputFrame` (HitListener.swift:86); the 5 ms pre-roll is applied to two-device windows only.
- **Lag 0 is rejected.** `Correlator.detect` rejects a strongest peak at lag 0 as `outsideWindow` (`guard top > 0`, Correlator.swift:82). So any path under about half a frame is never measured, and neither is a driver that labels input slightly early (a negative path).
- **Worse consequence than the first write-up (Codex P2, verified).** Level probes go through the same `HitListener.listen` (ProbePlayer.swift:43).
  - A zero-delay loop therefore gives every probe confidence 0.
  - The ramp climbs to the -6 dBFS loopback ceiling and fails the whole run with `nothingHeardAtCeiling`.
  - Its fix hint ("check the cable or loop routing…") points the user at the wrong cause.
- **The project's own bench expects this case.** Section 5 runs a virtual loopback with "expected: path close to 0 frames (a software loop adds no converter latency)" (bench.sh:177). If Rogue Amoeba Loopback (installed on this machine) labels its loop with zero offset, that bench step can only fail preflight. Hardware is needed to confirm the exact offset.

**Fix:** give the same-device window the same pre-roll. The latency stays `frame - outputFrame`, so nothing else changes:
```swift
range = (hit.outputFrame - prerollFrames)..<(hit.outputFrame + maxLatencyFrames + templateFrames)
```
Decide explicitly how a negative path is reported: keep it and flag it, or reject it with a named reason, not `outsideWindow`.

### WR-12: A built-in output without a readable `hdpn` data source gets the speaker ceiling: the classifier fails open

**File:** `Sources/SoundPingKit/Preflight/LevelRamp.swift:58-71`

**Issue:** `outputIsHeadphones` is true for a built-in output only when `output?.output?.dataSource == "hdpn"`. Every other built-in output, including one whose data source is nil or unreadable, falls through to `.speaker` (-12 dBFS), 18 dB above the headphone ceiling.

- **The rule fails open.** Missing information picks the louder ceiling, which is the opposite of the WR-08 rationale ("the opposite wrong guess would put … clicks next to someone's ears").
- **Ways the data source can be missing:**
  - `DeviceInfo.output` is nil (catalog miss).
  - The HAL read fails.
  - The headphone jack is exposed as its own built-in device that does not implement `kAudioDevicePropertyDataSource`. Apple Silicon MacBooks list wired headphones as a separate "External Headphones" device; whether it reports `hdpn` is not confirmed anywhere in the repo or the research (verify on hardware).
- **This is a hardware question, not a code question.** On this machine the built-in speakers do report `ispk` (`soundping devices --json`), so the narrower rule below would not cost the speaker case anything here.

**Fix:** prove "speaker" instead of proving "headphones". A built-in output is a speaker only on a known speaker data source; anything else built-in is treated as headphones:
```swift
public static func outputIsHeadphones(setup: ResolvedSetup, output: DeviceInfo?) -> Bool {
  let outputTransport = output?.transport ?? setup.output.transport
  if outputTransport == "bluetooth" { return true }
  guard outputTransport == "builtIn" else { return false }
  return output?.output?.dataSource != "ispk"   // unknown built-in output: assume ears
}
```
Update the ceiling table in the `classify` doc comment and the `--max-level` help text. Add a test for a built-in output with `dataSource: nil`.

## Info

### IN-01: A probe rejected for an overload or a discontinuity counts as "not heard", so the ramp climbs 6 dB

**File:** `Sources/SoundPingKit/Preflight/ProbePlayer.swift:43-49`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:325-331`, `Sources/SoundPingKit/Preflight/LevelRamp.swift:146-147`

**Status:** still open, unchanged.

**Issue:** an overloaded probe reports confidence 0 and peak -200 dBFS, and is not `silent`. The ramp treats it as faint and steps up 6 dB. Repeated glitches end in `nothingHeardAtCeiling` with a misleading fix hint. The level stays at or below the ceiling.

**Fix:** when `heard.overloaded` or the detection is `.rejected(.discontinuity)`, replay the probe at the same level (bounded retries) instead of calling `ramp.record`.

### IN-03: `requireFloat32` checks only the first stream of a scope

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:224-243`

**Status:** still open, unchanged. Also raised by Codex (P2).

**Issue:**
- A multi-stream device can carry the selected channel in a later stream with another virtual format. That stream would then be read as Float32 noise, or written as Float32 into a non-float buffer.
- A failed property read also passes silently (`else { return }`).

**Fix:** check the stream of every selected slot (`inSlot.buffer`, each `outSlots[i].buffer`). Treat an unreadable format as `unsupportedStreamFormat`.

### IN-04: Doc comments contradict the code

**File:** `Sources/SoundPingKit/Audio/HALProperty.swift:4-5`, `Sources/SoundPingKit/Store/RunStore.swift:191-192`

**Status:** still open, unchanged.

**Issue:**
- **HALProperty.** It says "nothing in this plan ever calls `AudioObjectSetPropertyData`", but `HALBackend.applyBuffer` does (HALBackend.swift:260). `HALBackend`'s own header now states the exception correctly.
- **`RunStore.runFile`.** It says "nothing outside `runs/` is read (T-01-34)", but any absolute folder path is accepted and read.

**Fix:** correct both comments and the T-01-34 wording in the security audit.

### IN-05: Dead code and an unused dependency

**File:** `Package.swift:13, 18`, `Sources/soundping/Render/ExitCodes.swift:32-34`, `Sources/SoundPingKit/Audio/HALProperty.swift:16-24`, `Sources/SoundPingKit/Audio/DeviceListeners.swift:88`

**Status:** still open.

**Issue:**
- `swift-log` is declared and linked, but nothing imports `Logging`.
- `ExitCodes.exitCode(for:)` and `HALProperty.has` are never called.
- `DeviceListeners.refused` is now read only by a hardware test (HardwareRoundTripTests.swift:110). A run whose `'livn'` or `'fsiz'` registration was refused still says nothing at runtime, so device changes can silently stop aborting it.

**Fix:**
- Drop the unused dependency and helpers.
- Surface `refused > 0` as a preflight warning in the result.

### IN-06: Duplicated logic

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:188-192`, `Sources/SoundPingKit/Store/Setups.swift:60-110`

**Status:** still open, unchanged.

**Issue:**
- `HALBackend.preflight(_:_:context:)` duplicates `SoundPingError.preflight`.
- `Setups.load` and `Setups.save` re-implement `VersionedFile.load` and `VersionedFile.save`. Calibrations already moved to `VersionedFile` (with `alsoReads`), so the two now diverge in behaviour too: setups use a plain `JSONDecoder`, the others `RunJSON.decoder()`.

**Fix:** use `SoundPingError.preflight`, and route `Setups` through `VersionedFile`.

### IN-07: Several stdout writes bypass `Output`'s guarded write

**File:** `Sources/soundping/Render/JSONRenderer.swift:7`, `Sources/soundping/Commands/RunsCommand.swift:50, 106`, `Sources/soundping/Commands/DevicesCommand.swift:9`

**Status:** still open, unchanged.

**Issue:** these call the non-throwing `FileHandle.write(_:)`, which raises an Objective-C exception on EPIPE. `Output.write` uses `try? write(contentsOf:)` precisely so "a reader that went away must not crash the tool". `soundping run … --json | head -c1` can therefore crash after the run is saved.

**Fix:** route all four through `Output.writeData`.

### IN-08: The IOProc stamps `mHostTime` and `mSampleTime` without checking `mFlags`

**File:** `Sources/SoundPingKit/Audio/IOCycle.swift:85-87, 129-131`

**Status:** still open, unchanged.

**Issue:** a timestamp without `kAudioTimeStampHostTimeValid` may carry host time 0. That point then enters the per-device least-squares fit (DeviceTimeline) and the self-test.

**Fix:** skip the stamp, and count a gap, unless both `sampleTimeValid` and `hostTimeValid` are set. Reading `mFlags` is RT-safe.

### IN-09: `HALBackend` is not reusable after `stop()`, though ChannelProbe reopens it

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:17-18, 49-51, 55-59, 170-182, 539-551`

**Status:** still open. Also raised by Codex (P2), which adds a worse consequence.

**Issue:**
- `stop()` finishes `eventSink` for good, and `open()` neither recreates it nor resets `gapsReported` or `stallReported`.
- ChannelProbe's open → stop → open sequence works only because it never reads events.
- **New angle (Codex, verified).** If a long-lived caller (the app) reuses one backend for a run:
  - `supervise`'s event task returns `.eventsEnded` at once, and the group loop ignores it (RunCoordinator.swift:156-161).
  - Device changes then never abort the run.
  - A stalled device **hangs the run forever**: `reportStall` yields into the finished sink, and `waitUntilCaptured` has no other exit.
- No current CLI path reuses a backend, so this is still Info.

**Fix:** make the backend single-use (throw on a second `open` after `stop`), or recreate the stream and reset the per-open state in `open()`.

### IN-10: `--in-channel auto` ignores device changes while it probes (external: codex)

**File:** `Sources/SoundPingKit/Preflight/ChannelProbe.swift:141-145, 203-206, 235-251`

**Issue:**
- `ChannelProbe.run` never reads `backend.events`, and its `HitListener` gets `monitor: nil`.
- A sample-rate, stream-layout or buffer change that keeps callbacks running therefore does not stop the probe.
- Scores from before and after the change are ranked together, and a channel is chosen (and possibly saved into a setup).
- Only a full stall is caught, by the 60 s per-channel deadline.
- The probe measures nothing, so the damage is a wrong or flaky channel choice, not a wrong number.

**Fix:** race each channel's probe against the backend's events, as `RunCoordinator.supervise` does. Any non-overload event becomes the matching `deviceChanged` error.

### IN-11: `RunParameters.minValidFraction` is never validated (external: codex)

**File:** `Sources/SoundPingKit/Engine/RunRequest.swift:40-45`, `Sources/SoundPingKit/Engine/HitScheduler.swift:12-54`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:484`, `Sources/soundping/Render/ErrorReporting.swift:83`

**Issue:**
- `requiredValidHits` is `Int((minValidFraction * hits - 1e-9).rounded(.up))`. A NaN or infinite fraction traps there, after the whole run was measured (in `calibrationToStore` and `RunGate.check`).
- A negative or zero fraction disables the valid-hit gate, and a fraction above 1 makes it unpassable.
- The CLI cannot set it today (recipe default 0.5), but `RunRequest` is the public engine API the app will call. `HitScheduler.validate` already checks every other parameter for that reason.

**Fix:** in `HitScheduler.validate`, require `minValidFraction.isFinite && (0...1).contains(minValidFraction)` and a value above 0. Throw `invalidParameters` otherwise.

### IN-12: Simulation flags are not range-checked and can trap the process (external: codex)

**File:** `Sources/soundping/Commands/SimulationOptions.swift:104-119`, `Sources/SoundPingKit/Simulation/SimulatedBackend.swift:368, 467, 583-588`

**Issue:** `--sim-stamp-bias`, `--sim-latency`, `--sim-jitter`, `--sim-noise` and `--sim-drift-ppm` go into the `Scenario` unchecked.

- `--sim-stamp-bias 1e300` reaches `UInt64(Swift.max(0, (… + bias).rounded()))` (SimulatedBackend.swift:583) and traps.
- A huge or non-finite `--sim-latency` traps in `Int64(start.rounded(.up))` (line 467) and `Int64(middle.rounded(.up))` (line 368).
- These are developer and CI flags, but the CLI contract is "a named usage error, never a crash".

**Fix:** validate in `SimulationOptions.scenario`:
- every value finite;
- latency in `0...maxLatency`;
- jitter and noise at 0 or above;
- `|stamp bias|` and `|drift|` within a few thousand frames or ppm.

Throw `invalidParameters` naming the flag.

### IN-13: A side-file write failure after run.json turns a saved run into a reported failure (WR-02 residual)

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:447-464`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:71-83`

**Issue:** the WR-02 order now writes run.json first, then `calibrations.json`, then `clock-selftest.json`. When a side file fails (e.g. `calibrationsUnwritable`):

- run.json is on disk, saying `calibration.stored: true`, but no record exists.
- The self-test record is skipped too, because the throw happens before it.
- `.finished` is never emitted. The CLI prints no result and exits 64 or 70, although the run was saved and `runs list` shows it as a normal run.
- 01-REVIEW-FIX.md records the first point as accepted ("a smaller fault … but not zero"). The other two consequences are not mentioned there.

**Fix:** do one of the following:
- treat side-file failures as a warning on a finished run: emit `.finished`, keep the exit code for the run, and print `warning: calibration not stored: …`;
- or, on failure, rewrite run.json with `calibration.stored = false` before rethrowing.

Either way, attempt the self-test record even when the calibration write fails.

### IN-14: `recipes` output still disagrees with what a run uses

**File:** `Sources/soundping/Commands/RecipesCommand.swift:21-23, 52-53, 62-64`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:127-129`

**Issue:**
- **`defaults.templateId` is wrong for most runs.** It always reports `chirp-loopback`. Without `--template`, the band follows the listener (`LevelRamp.templateId(for:)`), so speaker, headphone and unknown runs use `chirp-speaker`.
  - An agent that copies the advertised default into `--template chirp-loopback` changes behaviour: `templateFollowsListener` becomes false. This is the same class as WR-09.
- **The WR-09 key rename has no version bump.** `startLevelDbfs` became `rampStartLevelDbfs`, but the envelope's `schemaVersion` stays 1, while run.json and calibrations.json were bumped for their own shape changes (WR-04).

**Fix:**
- Report the template as "follows the listener (chirp-loopback for a loop, chirp-speaker otherwise)", e.g. `templateId: null` plus `templateRule`.
- Bump the `recipes --json` envelope to `schemaVersion: 2`.

---

_Reviewed: 2026-11-12T17:38:50Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
