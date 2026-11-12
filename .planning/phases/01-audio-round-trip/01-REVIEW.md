---
phase: 01-audio-round-trip
reviewed: 2026-11-12T19:47:10Z
depth: standard
files_reviewed: 41
files_reviewed_list:
  - Package.resolved
  - Package.swift
  - Sources/SoundPingKit/Audio/AudioBackend.swift
  - Sources/SoundPingKit/Audio/DeviceListeners.swift
  - Sources/SoundPingKit/Audio/HALBackend.swift
  - Sources/SoundPingKit/Audio/HALProperty.swift
  - Sources/SoundPingKit/Audio/IOCycle.swift
  - Sources/SoundPingKit/Audio/RTState.swift
  - Sources/SoundPingKit/Clock/ClockSelfTest.swift
  - Sources/SoundPingKit/Clock/DeviceTimeline.swift
  - Sources/SoundPingKit/Engine/HitListener.swift
  - Sources/SoundPingKit/Engine/HitScheduler.swift
  - Sources/SoundPingKit/Engine/RunCoordinator.swift
  - Sources/SoundPingKit/Engine/SoundPingError.swift
  - Sources/SoundPingKit/Preflight/ChannelProbe.swift
  - Sources/SoundPingKit/Preflight/LevelRamp.swift
  - Sources/SoundPingKit/Preflight/Preflight.swift
  - Sources/SoundPingKit/Preflight/ProbePlayer.swift
  - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
  - Sources/SoundPingKit/Store/RunStore.swift
  - Sources/SoundPingKit/Store/Setups.swift
  - Sources/soundping/Commands/DevicesCommand.swift
  - Sources/soundping/Commands/RecipesCommand.swift
  - Sources/soundping/Commands/RunOptions.swift
  - Sources/soundping/Commands/RunsCommand.swift
  - Sources/soundping/Commands/SimulationOptions.swift
  - Sources/soundping/Render/ExitCodes.swift
  - Sources/soundping/Render/JSONRenderer.swift
  - Tests/SoundPingKitTests/AbortTests.swift
  - Tests/SoundPingKitTests/CalibrationStoreTests.swift
  - Tests/SoundPingKitTests/ChannelProbeTests.swift
  - Tests/SoundPingKitTests/ClockTests.swift
  - Tests/SoundPingKitTests/FaultRecordingTests.swift
  - Tests/SoundPingKitTests/HardwareRoundTripTests.swift
  - Tests/SoundPingKitTests/IOCycleTests.swift
  - Tests/SoundPingKitTests/LevelRampTests.swift
  - Tests/SoundPingKitTests/PreflightTests.swift
  - Tests/SoundPingKitTests/SchedulerTests.swift
  - Tests/SoundPingKitTests/SimulationRecoveryTests.swift
  - Tests/soundpingTests/RecipesCommandTests.swift
  - Tests/soundpingTests/SimulationOptionsTests.swift
findings:
  critical: 1
  warning: 2
  info: 7
  total: 10
  necessity: 1
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-11-12T19:47:10Z
**Depth:** standard
**Files Reviewed:** 41
**Status:** issues_found

## Summary

Regression re-review of `git diff 75bbabe HEAD` over the 41 listed files, each read in full context. It covers the 15 fixer commits and the quick-task redesign (261112-ql0: one stamp entry per callback, per-direction fault-interval rings). Callees outside the list were read where a finding depends on them: `Correlator.detect`, `DeviceCatalog` transport mapping, `VersionedFile`, `RunStore.write`, `Output.writeData`. Nothing was built, run or modified.

### ✅ Fix verification (the 18 previous findings)

| ID | Verdict | Note |
|---|---|---|
| CR-03 | ✅ holds | The headphone check runs first; a Loop channel or virtual input only counts on the same device. **But the fix added a new rule (a virtual output always counts as a loop), and that rule is a regression → CR-04.** This review's previous suggested fix contained the same rule. |
| WR-01 | ✅ holds | Intervals, not points; a direct `backend.faults(...)` query after a 20 ms settle; output glitches land in output labels; the two gaps are never merged. Residuals → IN-16, IN-18. |
| WR-03 | ✅ holds | One ring entry per callback carries both sides; `ioOffsetFrames` comes from single entries; there is no `zip` left; the self-test judges only `coveredSamples`. |
| WR-12 | ✅ holds | `dataSource != "ispk"` → headphones. Related new gap → WR-14. |
| IN-01 | ✅ holds | Bounded replay at the same level (`maxGlitchRetries = 3`). The channel probe was not covered → IN-19. |
| IN-02 | ✅ holds | The same-device window has a pre-roll. `Correlator.detect` returns an absolute frame (`windowStartFrame + first + offset`), so the pre-roll cannot shift the latency. |
| IN-03 | ✅ holds | Every selected stream is checked; an unreadable format is refused. |
| IN-04 | ✅ holds | Both comments now match the code. The security-audit wording is outside this scope and was not checked. |
| IN-05 | ✅ holds | The dependency and the helpers are gone; refused listeners become a run warning. `AGENTS.md` still advertises swift-log → IN-15. |
| IN-06 | ✅ holds | Setups go through `VersionedFile`; HALBackend uses `SoundPingError.preflight`. |
| IN-07 | ✅ holds | `FileHandle.standardOutput.write` no longer appears in `Sources/`. |
| IN-08 | ✅ holds | `mFlags` is checked as raw bits. A side without a host time logs no stamp and becomes an `invalidTimestamp` fault. |
| IN-09 | ✅ holds (HAL, open → stop → open) | Simulator and open → open are not covered → IN-20. |
| IN-10 | ✅ holds | `withDeadline` races each channel against `backend.events`. |
| IN-11 | ✅ holds | `0 < minValidFraction <= 1`, finite. |
| IN-12 | ✅ holds | Every `--sim-*` double is range-checked; the bounds leave the simulator's `Int64`/`UInt64` conversions safe. |
| IN-13 | ✅ holds | Side-file failures become warnings on a finished run; run.json is rewritten best effort with `stored: false`. |
| IN-14 | ✅ holds | `templateId: null` plus `templateRule`; envelope `schemaVersion: 2`. |

### ⏱️ Real-time safety and accuracy (the focus areas)

- **IOProc path is clean.**
  - The path is `ioCycle` → `captureSide` / `playSide` → `StampRing.append` / `FaultRing.append`. Every function on it is `@_noLocks` and uses only preallocated pointers and `Atomic`s. No allocation, no ObjC/Swift runtime calls, no async.
- **One writer per ring holds.**
  - The input IOProc writes `inputFaults` and `inputDeviceStamps`.
  - The output IOProc writes `outputFaults` and `outputDeviceStamps`.
  - The overload rings are written only from the single `DeviceListeners` serial queue.
  - On a duplex device, one IOProc writes both rings.
- **Memory ordering holds.**
  - Each entry is written before its count is published with a releasing store, and readers load the count with an acquiring load.
  - The stamp and the faults are appended before the label store, so a reader that sees a label also finds that callback's records.
  - Residual torn-read window on wrapped rings → IN-16.
- **No hidden offset found.**
  - Same-device path = detected absolute frame − output label.
  - Δio = per-entry output − input sample time.
  - Two-device path = per-direction timelines fitted from the retained log.
  - None of these can shift by a callback any more.
- **Hearing safety: two gaps and one regression.**
  - CR-04: a virtual output with a physical input is now a "loopback" (-6 dBFS); it was "unknown" (-18 dBFS) before.
  - WR-13: `--listener` lifts the -30 dBFS ceiling without `--max-level`.
  - WR-14: a data-source change (headphones plugged into the built-in output) during a run is not watched.
- **swift-log removal is complete in the build.**
  - `Package.swift` and `Package.resolved` are both clean, and nothing imports `Logging`.
  - Only the stack documentation lags (IN-15).

### 📋 Necessity

The rubric (`necessity-review.md`) was read. One Info finding (IN-21): label loads whose result is discarded in `RTState.faults`.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-04: A virtual output is now a "loopback" whatever the input: a mic run through a monitored virtual device can ramp to -6 dBFS (regression from the CR-03 fix)

**File:** `Sources/SoundPingKit/Preflight/LevelRamp.swift:125-133`, `Tests/SoundPingKitTests/LevelRampTests.swift:130-139`

**Issue:** the CR-03 fix (`c0736f5`) added `|| outputTransport == "virtual"` to the loopback rule:

```swift
if (sameDevice && (looped || inputTransport == "virtual")) || outputTransport == "virtual" {
  return .loopback   // -6 dBFS
}
```

- **Before the fix**, a virtual output with a separate physical input (built-in mic, USB mic) was `.unknown`, ceiling -18 dBFS. **Now it is `.loopback`, ceiling -6 dBFS: 12 dB louder.**
- **No digital loop is possible on that route.**
  - The chirp goes into a virtual device, and a physical microphone can only hear it acoustically.
  - That happens when the virtual device forwards to a physical output: Rogue Amoeba Loopback "Monitors" (installed on this machine), Audio Hijack, a DAW monitoring the device.
  - The doc comment states the principle itself: "a loop needs the output to feed the input". A virtual device cannot feed a microphone.
- **The CR-03 failure mode comes back on this route.** The monitor goes to headphones, so the mic hears only room noise: not exact zeros, so no `inputDigitalSilence`. The ramp then climbs -48 → … → **-6 dBFS into the headphones**, 24 dB above the headphone ceiling, and ends in `nothingHeardAtCeiling`.
  - Monitored to the built-in speakers, it still exceeds the -12 dBFS speaker ceiling by 6 dB.
- **The test pins the regression.** `aVirtualOutputIsALoopbackWhateverItsInput` asserts `.loopback` for `output: duplex, input: macMicrophone`.
- **Provenance.** This rule was in the fix this review proposed last time (01-REVIEW at 75bbabe, CR-03 Fix block). The proposal was wrong, and the fixer applied it as written.

**Fix:** a two-device route is a loop only when both ends are digital. A virtual output into a physical input is acoustic, so it falls through to the normal classification:
```swift
let bothVirtual = outputTransport == "virtual" && inputTransport == "virtual"
if (sameDevice && (looped || inputTransport == "virtual")) || bothVirtual {
  return .loopback
}
```
Then:
- Change the test to expect `.unknown` for virtual output + Mac microphone.
- Add a case for virtual output + virtual input on two devices (`.loopback`).
- Update the ceiling table in the `classify` doc comment ("or a virtual output" → "or a virtual output into a virtual input").

## Warnings

### WR-13: `--listener` lifts the headphone and Bluetooth ceiling without `--max-level`, though the help says `--max-level` is the only way

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:121-126`, `Sources/SoundPingKit/Preflight/ChannelProbe.swift:95`, `Sources/soundping/Commands/RunOptions.swift:24-35`

**Issue:**
- **The override replaces the classification outright.**
  - `listener = request.preflight.listener ?? LevelRamp.classify(...)`, and the ceiling comes from that kind.
  - So `--listener loopback` on AirPods or the built-in headphone output gives -6 dBFS, and `--listener speaker` gives -12, with no `--max-level`.
  - The channel probe does the same (`if let override = options.listener { return override }`).
- **The CLI contradicts this.** The `--max-level` help says it is "The only way to go louder than that, for example for a Bluetooth speaker", and the `--listener` help only says it "sets the ceiling".
  - A user who reads `--listener loopback` as "I am testing a loop" while the output is a headset gets a 24 dB louder ceiling. That breaks the T-01-28 invariant this phase was asked to keep: headphones and Bluetooth never above -30 dBFS without an explicit `--max-level`.
- **There is a legitimate case:** a headphone jack cabled into an interface input. It can still be served by `--max-level`.

**Fix:** let `--listener` pick the chirp band and the kind, but never raise the ceiling above the output's own headphone ceiling:
```swift
var ceiling = try LevelRamp.resolveCeiling(kind: listener, maxLevelDbfs: request.preflight.maxLevelDbfs)
if request.preflight.maxLevelDbfs == nil,
   LevelRamp.outputIsHeadphones(setup: request.setup, output: info.outputDevice) {
  ceiling = Swift.min(ceiling, LevelRamp.ceilingDbfs(for: .headphones))
}
```
- Apply the same clamp in `ChannelProbe.run`.
- Add a test: `--listener loopback` on a Bluetooth output ramps no higher than -30 dBFS.
- Alternatively, keep the behaviour and correct both help texts. That is weaker: the invariant would then rest on the user reading them.

### WR-14: A headphone plug-in during a run is not watched: a built-in output locked at the speaker level keeps playing into the ears

**File:** `Sources/SoundPingKit/Audio/DeviceListeners.swift:58-65`, `Sources/SoundPingKit/Preflight/LevelRamp.swift:142-147`, `Sources/SoundPingKit/Engine/RunCoordinator.swift:121-124`

**Issue:**
- **The ceiling is decided once, from the data source read at `open`.**
  - `info.outputDevice.output.dataSource == "ispk"` → speaker, -12 dBFS.
  - `DeviceListeners` watches `livn`, `nsrt`, `fsiz`, `slay`, `over` and `stpd`, but not `kAudioDevicePropertyDataSource` (`'ssrc'`) or `kAudioDevicePropertyJackIsConnected` (`'jack'`).
- **A built-in output that switches data source moves the sound from the speakers to the ears with no event.**
  - The macOS 15+ floor still includes Intel Macs, whose built-in output switches `ispk` → `hdpn` on one device when headphones go in.
  - The level ramp and up to 10 000 hits continue at up to -12 dBFS, 18 dB above the headphone ceiling.
  - This also holds for a plug-in between `open` and the first probe.
- **The WR-12 rationale assumes a data source fixed for the whole run.** On Apple Silicon the jack is believed to be a separate device, so it is unaffected. The Intel behaviour needs hardware to confirm.

**Fix:**
- Register `'ssrc'` (output scope) and, where implemented, `'jack'` on the output device.
- When the data source differs from the one the run classified with, yield a `deviceChanged` event (for example `.dataSourceChanged(uid:)` → `"outputDataSourceChanged"`), so the run aborts like any other device change.
- Add a hardware test next to `deviceListenersRegisterOnARealDeviceAndComeOffAgain`, and a unit test that the new event maps to a `deviceChanged` error.

## Info

### IN-15: The stack documentation still lists swift-log as a shipped, always-used dependency (IN-05 residual)

**File:** `AGENTS.md:75, 178`

**Issue:** IN-05 removed swift-log from `Package.swift` and `Package.resolved`. But the Supporting Libraries table still says "swift-log | 1.17.0 | … | Always", and the licence table lists it as shipped ("yes"). `CLAUDE.md` mirrors the same stack section. An agent following the "Always" row may re-add the dependency.

**Fix:** mark swift-log as "not used yet (dropped in Phase 1, IN-05)" in both tables, or move it to "Not chosen".

### IN-16: A wrapped ring's "forgotten" range is bounded by retained lower bounds, and the oldest slot can be read torn

**File:** `Sources/SoundPingKit/Audio/RTState.swift:183-193, 493-528, 131-138`

**Issue:**
- **Wrong bound.**
  - `scan` reports `logOverwritten` only for `query.lowerBound < oldest`, where `oldest` is the smallest *lower* bound still retained.
  - An overwritten interval can end above that, for example a long lost-frames gap followed by more than 4096 short faults.
  - A query inside it but at or above `oldest` then passes with no fault. The fail-safe promise ("overflow rejects a hit instead of letting it through") assumes intervals ordered by both ends.
- **Torn reads.**
  - `retained()` and `StampRing.snapshot()` copy slot `first = n - capacity` with no re-check, while the writer may be overwriting that same slot with entry `n`.
  - The copy can mix the `lower` of one interval with the `upper` of another, or one stamp's sample time with another's host time.
  - `readCapture` already guards the same race with an after-load.
- Both need a wrapped ring (4096 faults, or 2^21 callbacks), so this is Info.

**Fix:**
- In `FaultRing.append`, before overwriting a slot (`n >= capacity`), fold `uppers[i]` into an `Atomic<Int>` `forgottenUpper` with a running max. This is RT-safe: one load and one store.
- In `scan`, report `logOverwritten` over `query ∩ (-∞, forgottenUpper)`.
- In both `retained()` and `snapshot()`, re-load `written` after the copy and drop ordinals below `after - capacity`.

### IN-17: A backward sample-time jump moves the published label backwards and poisons everything below the old position

**File:** `Sources/SoundPingKit/Audio/IOCycle.swift:150-153, 168, 229-234`, `Sources/SoundPingKit/Audio/HALBackend.swift:499-511`, `Sources/SoundPingKit/Audio/RTState.swift:374-380`

**Issue:** suppose the sample time goes back, for example because an IO restart resets it.
- `captureSide` records `[label, expected)` and then publishes `label + frames`, which is below the label already published.
- **The consequences:**
  - Every later hit whose labels fall below the old position is rejected, because it overlaps the big interval. A reset after hours of device uptime rejects every hit of the run.
  - `waitUntilCaptured` sees the label move and never reports a stall, so it waits for the labels to climb back. That can take as long as the device had been running.
  - The "complete below the last `waitUntilCaptured` target" contract in `AudioBackend.faults` assumes labels never fall.
  - A `capture` that races the jump throws `captureBeyondProcessed`, an internal failure instead of a device change.
- **What is new and what is not.** The label regression predates this diff. The redesign turns its result from one rejected point into a range that blocks the whole run. Whether and when the HAL resets sample time mid-IO needs hardware to confirm.

**Fix:** treat a backward jump as a device restart, not a fault:
- Set an `Atomic<Bool>` `clockWentBack` in the IOProc and do not publish the lower label.
- Have `waitUntilCaptured`'s poll loop surface it as `.ioStopped` (or a new `.clockReset`) on the event stream.
- That ends the run with a `deviceChanged` error.

### IN-18: The overload interval and the settle are sized from the buffer requested at open, not the one the device settled on

**File:** `Sources/SoundPingKit/Audio/HALBackend.swift:178-188`, `Sources/SoundPingKit/Audio/DeviceListeners.swift:150-158`, `Sources/SoundPingKit/Engine/HitListener.swift:25, 80-81`

**Issue:**
- **Stale buffer size.**
  - `DeviceListeners.Watched.bufferFrames` is `outBuffer` / `inBuffer` from `open`. `start()` later adopts the settled sizes, but only into `BufferBaselines`.
  - The `'over'` handler captured `lookback = max(2 * bufferFrames, 20 ms)` and `bufferFrames` at init.
  - A driver that settles on a larger buffer once IO runs, which is the case `adoptSettledBuffers` exists for, gets a lookback and a forward margin sized for the smaller buffer.
- **Fixed settle.** `faultSettleMs = 20` does not scale with the buffer either. At 1024 frames and 48 kHz, one callback is already 21 ms.
- **Effect.** A late `'over'` lands outside the window, or after the query, and a glitched hit passes. The quick task already lists the notification delay as needing hardware verification.

**Fix:**
- Hold the overload sizes in the same `Mutex` as the baselines, updated by `adoptSettledBuffers`.
- Compute the settle as `max(faultSettleMs, 2 × settled buffer)` from `info.inputBufferFrames` / `outputBufferFrames`.
- Keep it below the 50 ms spacing margin by validating, not by assuming.

### IN-19: The channel probe treats a glitched probe as heard and climbs 12 dB on it (IN-01 residual)

**File:** `Sources/SoundPingKit/Preflight/ChannelProbe.swift:214-229`, `Sources/SoundPingKit/Preflight/ProbePlayer.swift:52-55`

**Issue:** `ChannelProbe.probe` ignores `played.glitched`.
- A faulted probe has confidence 0 and `peakDbfs -200`, and is not `silent` (`!heard.faulted && …`).
- So it sets `heardSomething = true` and steps the level up 12 dB. Bounded by the ceiling.
- Results:
  - A channel can be scored lower than it hears.
  - A probe of only dead channels can end in `nothingHeard` instead of the more accurate silence error.

**Fix:** mirror `lockLevel`. On `played.glitched`, replay at the same level up to `LevelRamp.maxGlitchRetries`, and do not count the probe toward `heardSomething`.

### IN-20: Reopen is fixed for HAL open → stop → open only: the simulator's stream stays finished, and open → open leaks running IOProcs (IN-09 residual)

**File:** `Sources/SoundPingKit/Simulation/SimulatedBackend.swift:255-259, 562-565`, `Sources/SoundPingKit/Audio/HALBackend.swift:66-72, 203-215`

**Issue:**
- **Simulator.** `SimulatedBackend.events` is created once in `init`, and `stop()` finishes it for good.
  - On `--simulate --in-channel auto`, every channel after the first gets a finished stream: `withDeadline`'s watcher drops straight to its 24 h sleep.
  - A device event there would surface only as the 60 s "no audio arrived" deadline, with the wrong code.
  - Today no probe can trigger one, because sim faults key on hit indices ≥ 0. So the gap is latent, and the protocol behaves differently per backend.
- **HAL.** A second `open` without `stop` keeps the old stream (`beginOpen` renews it only `if stopped`) and overwrites `state.devices` and `state.listeners`.
  - The previous IOProcs keep running and are never destroyed.
  - The old listeners keep yielding into the shared sink.
  - No current caller does this; the app might.

**Fix:**
- Give `SimulatedBackend` the same per-open stream as `HALBackend`: recreate it in `open` when the last one was finished.
- In `HALBackend.open`, either throw `internalFailure("alreadyOpen")` when devices are present, or call the `stop()` body first.

### IN-21: Already-defended-elsewhere: the label loads in `RTState.faults` are discarded and add no ordering

**File:** `Sources/SoundPingKit/Audio/RTState.swift:483-485`
**Category:** necessity

**Issue:**
- **The two loads do nothing.** `_ = inputNextLabel.load(ordering: .acquiring)` and `_ = outputNextLabel.load(ordering: .acquiring)` are documented as what makes "every fault below those labels" visible.
- **The visibility is already provided.**
  - Each ring publishes its count with a releasing store (`RTState.swift:179`) and `retained()` reads it with an acquiring load (`:184`).
  - The caller (`HitListener.listen`) has already acquire-loaded the input label in `waitUntilCaptured` before this call.
- **Why Info.** Neither load's value is used, so the comment credits ordering to code that contributes nothing. It rests on memory-model reasoning, not on a test.

**Fix:** drop the two loads, and reword the comment: the ring counts are release/acquire, and the caller's wait is what bounds completeness.

---

_Reviewed: 2026-11-12T19:47:10Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
