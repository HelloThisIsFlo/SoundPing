---
phase: 01-audio-round-trip
reviewed: 2026-11-12T20:41:40Z
depth: standard
files_reviewed: 23
files_reviewed_list:
  - AGENTS.md
  - README.md
  - Sources/SoundPingKit/Audio/AudioBackend.swift
  - Sources/SoundPingKit/Audio/DeviceListeners.swift
  - Sources/SoundPingKit/Audio/HALBackend.swift
  - Sources/SoundPingKit/Audio/IOCycle.swift
  - Sources/SoundPingKit/Audio/RTState.swift
  - Sources/SoundPingKit/Engine/HitListener.swift
  - Sources/SoundPingKit/Engine/RunCoordinator.swift
  - Sources/SoundPingKit/Engine/SoundPingError.swift
  - Sources/SoundPingKit/Preflight/ChannelProbe.swift
  - Sources/SoundPingKit/Preflight/LevelRamp.swift
  - Sources/SoundPingKit/Preflight/Preflight.swift
  - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
  - Sources/soundping/Commands/RunOptions.swift
  - Tests/SoundPingKitTests/AbortTests.swift
  - Tests/SoundPingKitTests/ChannelProbeTests.swift
  - Tests/SoundPingKitTests/FaultRecordingTests.swift
  - Tests/SoundPingKitTests/HardwareRoundTripTests.swift
  - Tests/SoundPingKitTests/IOCycleTests.swift
  - Tests/SoundPingKitTests/LevelRampTests.swift
  - Tests/SoundPingKitTests/LoudnessInvariantTests.swift
  - Tests/SoundPingKitTests/SimulationRecoveryTests.swift
findings:
  critical: 1
  warning: 2
  info: 1
  total: 4
  necessity: 0
status: issues_found
---

# Phase 01: Code Review Report

**Reviewed:** 2026-11-12T20:41:40Z
**Depth:** standard
**Files Reviewed:** 23
**Status:** issues_found

## Summary

Regression re-check of `git diff 184b8c2 HEAD` over the 23 listed paths, each read in full context. Callees outside the list were read where a finding depends on them: `ProbePlayer`, `RunCommand.probeChannels`, `DeviceCatalog.transportName`, `HALProperty.get`, `HitScheduler` constants. Nothing was built, run or modified.

### ✅ Fix verification (the 10 previous findings)

| ID | Verdict | Note |
|---|---|---|
| CR-04 | ✅ holds | A virtual output heard by a physical input is `unknown` (-18) again, on both paths, and the test now expects that. **But the replacement rule (`bothVirtual`, which last review's fix proposed) counts two unrelated virtual devices as a loop → CR-05.** |
| WR-13 | ✅ holds | One rule, `LevelRamp.loudness(detected:options:)`: `--max-level` replaces, otherwise `min(detected, named)`. `RunCoordinator` and `ChannelProbe` call nothing else; `resolveCeiling` and `ChannelProbe.listenerKind` are gone, so nothing can wire around the clamp. |
| WR-14 | ✅ holds for runs | `'ssrc'` is compared with the exact value the loudness was classified with (`outInfo.output?.dataSource`, same scope/element as the catalog read), re-checked right after registration, so the open → register gap is closed. No false-abort path found: only the output scope of a playing device is watched, and every notification is compared, not trusted. **The channel probe re-baselines on every reopen while keeping the first open's ceiling → WR-15.** |
| IN-15 | ✅ holds | `AGENTS.md` (and `CLAUDE.md`, a symlink to it) mark swift-log "not used yet" in both tables. |
| IN-16 | ✅ holds | See the real-time section below. |
| IN-17 | ✅ holds | Label never falls; the direction goes quiet; `waitUntilCaptured` throws `sampleClockReset` (and yields it once). The ±0.5-frame tolerance cannot fire on rounding alone: `sampleTime_next − expected = sampleTime_prev − round(sampleTime_prev) ∈ [−0.5, 0.5]`. |
| IN-18 | ✅ holds | `'over'` reads the adopted size from `BufferBaselines` at notification time; the settle is `max(20 ms, 2 × settled buffer)`, capped at 45 ms with a run warning; both `RunCoordinator` and `ChannelProbe` build `HitListener` from `start()`'s info. |
| IN-19 | ✅ holds | A glitched probe is replayed up to 3 times at the same level, never counts as heard, and an all-glitched channel can no longer produce `inputDigitalSilence`. |
| IN-20 | ✅ holds | HAL: open on an open backend calls `stop()` first, which finishes the old stream and destroys the IOProcs. Simulator: per-open stream, finished on reopen and on stop. |
| IN-21 | ✅ holds | The discarded loads are gone; the comment now credits the ring counts and the caller's wait. |

### 🔊 Hearing-safety model (main focus)

- **Code vs the approved rule**
  - Headphones/Bluetooth/built-in-not-`ispk` → -30, checked first: ✅.
  - Built-in `ispk` → -12: ✅.
  - "A loop SoundPing can see" → -6: ❌ for two distinct virtual devices (CR-05). Same-device virtual and same-device `Loop` channel are fine.
  - Anything else → -18: ✅.
  - `--listener` only lowers, for any device: ✅ (`fromFlag < fromDevices`).
  - `--max-level` the only way up: ✅.
  - `--level` clamped: ✅ (`LevelRamp.firstLevel`, warning when above). The failure message misreports the clamped level → WR-16.
- **Channel probe**: headphones -30, else -18, `--listener` lowers, `--max-level` replaces: ✅. Route watching gap between channels → WR-15.
- **Help, README, hints**: `--listener`, `--max-level`, `--level` help and the README section say the same thing as the code, including the `--listener` behaviour change. They faithfully describe the CR-05 rule too ("a virtual output into a virtual input"), so they need the same correction.
- **`LoudnessInvariantTests`**
  - The expectation table is restated independently (its own ceiling numbers and detection order), so a changed number or order in `LevelRamp` fails it. The e2e tests check the loudest gain actually scheduled, not a reported number.
  - It walks `--listener` and `--max-level` on both paths.
  - **It pins the CR-05 rule** (`.virtualOtherDevice where output == .virtual → .loopback`), so fixing CR-05 needs the table changed with it.
  - It cannot catch a drift in the transport strings the classifier depends on → IN-22.
  - `--level` clamping is not in this suite but is guarded end to end by `LevelRampTests.aChosenLevelIsConfirmedByOneProbeAndCappedByTheCeiling`.

### ⏱️ Real-time safety (IN-16 / IN-17)

- **Lock- and allocation-free.**
  - New IOProc work is `Atomic` loads/stores, `atomicMemoryFence`, and plain stores into `calloc`'d columns.
  - `FaultRing.append` and `StampRing.append` stay `@_noLocks`.
  - `swift build` passing is the compiler's proof (per the fix report).
- **Single writer holds.**
  - `forgottenUpper` and `started` are written only by each ring's own writer.
  - The overload rings' writer is the one serial listener queue of the current open; IN-20 guarantees one open at a time.
- **Ordering is the standard seqlock shape.**
  - Writer: `started = n+1` (release), release fence, slot stores, `written = n+1` (release).
  - Reader: copy, acquire fence, `started` load.
  - A copy that saw any byte of write `k+capacity` therefore sees `started ≥ k+capacity+1` and drops ordinal `k`. The `intact = begun − capacity` arithmetic is exact (write ordinal `m` sets `started = m+1` and overwrites ordinal `m − capacity`).
  - `forgottenUpper` is folded *before* the `started` release, so a reader that drops a slot is guaranteed to see that slot's upper bound. "Dropping fails safe" holds.
  - Caveat, not a finding: the slot columns are non-atomic, so this is formally a data race under the Swift/C++ model. It is the same pattern `readCapture` already uses, and it works on arm64/x86 because the fences are also compiler barriers.
- **Clock reset (IN-17)**
  - Both sides check the flag before touching the capture ring or mixing, and the output buffers are zeroed before the early return, so a reset device plays silence.

### 📋 Necessity

The rubric (`necessity-review.md`) was read. The two `noLoudness` guards in `ChannelProbe.run` (lines 126-129, 159-161) are provably unreachable: `loudness` is set or the call throws at position 0, and `channels` is non-empty. They are a one-line cost, so no necessity finding was raised.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-05: Two unrelated virtual devices count as "a loop SoundPing can see": a monitored virtual output can ramp to -6 dBFS into headphones

**File:** `Sources/SoundPingKit/Preflight/LevelRamp.swift:95-101` (also the doc table at `:51`, `:53`, `:76-78`), `Sources/soundping/Commands/RunOptions.swift:27`, `Tests/SoundPingKitTests/LoudnessInvariantTests.swift:163-164`, `Tests/SoundPingKitTests/LevelRampTests.swift:142-153`

**Issue:**
- **What the code does.**
  - `let bothVirtual = outputTransport == "virtual" && inputTransport == "virtual"` makes any virtual output with *any* virtual input on another UID a `.loopback`, with a -6 dBFS ceiling.
- **What SoundPing can actually see on two UIDs.**
  - It sees nothing that ties the two devices together. Whether device A feeds device B depends on a router (Loopback, Audio Hijack, a DAW) that SoundPing cannot read.
  - The approved rule and the README say "a loop it can see". This is a guess, not a visible loop.
- **The file's own reasoning already covers the hazard** (`:76-78`): "a virtual device that monitors to headphones or speakers".
  - Monitoring is a property of the *output* device, so it does not stop because the input is also virtual.
  - The suite also already accepts virtual inputs that "carry other audio (not silent)" (`LevelRampTests.aBluetoothOutputWithAVirtualInputStillRamps…`).
- **The failure path.**
  - Output: a Rogue Amoeba Loopback device with Pass-Thru, monitored to headphones or AirPods.
  - Input: a second virtual device carrying a mic or app audio, so the input is never exact zeros and `inputDigitalSilence` does not stop the ramp.
  - The ramp climbs -48 → … → **-6 dBFS into the monitor headphones**. That is 24 dB above the headphone ceiling, with no `--max-level` given, and ends in `nothingHeardAtCeiling`.
  - The same as CR-04, narrowed from "any input" to "any virtual input".
- **Not affected:** the same-device virtual case (`sameDevice && inputTransport == "virtual"`).
  - BlackHole, or a Loopback device with Pass-Thru, returns the chirp digitally, so the ramp locks at -48.
  - A device without Pass-Thru does not play SoundPing's output anywhere.
- **Provenance.** `bothVirtual` was this review's own proposed fix for CR-04 (01-REVIEW at 184b8c2), and the fixer applied it as written. That proposal was wrong for the same reason CR-04 was.
- **Pinned by the tests.** `LoudnessInvariantTests.documentedRunListener` and `LevelRampTests.aVirtualOutputIntoAVirtualInputIsALoopback` both assert `.loopback` for this route, so the invariant suite enforces the hazard instead of guarding against it.

**Fix:** a loop only counts on one device. Two virtual devices fall through to `unknown`, and a real virtual-to-virtual route is served by `--max-level -6`, which the help already offers for unidentified cable loops:
```swift
let sameDevice = setup.output.uid == setup.input.uid
let looped = setup.inChannelName?.lowercased().hasPrefix("loop") == true
// A loop SoundPing can see is on one device: an interface loop channel or a virtual duplex.
// Two devices, virtual or not, may be joined by a router SoundPing cannot read (CR-05).
if sameDevice && (looped || inputTransport == "virtual") { return .loopback }
```
Then:
- Change `LoudnessInvariantTests.documentedRunListener` to drop the `.virtualOtherDevice where output == .virtual` line.
- Flip `LevelRampTests.aVirtualOutputIntoAVirtualInputIsALoopback` to expect `.unknown` on two UIDs; keep its same-UID `recorded` case as `.loopback`.
- Remove "or a virtual output into a virtual input" from the `classify` table (`:51`), the `--max-level` help (`RunOptions.swift:27`), and the fix report's model summary.
- Add "two virtual devices" to the unknown row and the `--max-level -6` example.

## Warnings

### WR-15: The channel probe keeps the first channel's ceiling but re-baselines route watching on every reopen, so a route change between channels is never reported

**File:** `Sources/SoundPingKit/Preflight/ChannelProbe.swift:117-125, 143-147`, `Sources/SoundPingKit/Audio/HALBackend.swift:91-92, 187-189`, `Sources/SoundPingKit/Audio/DeviceListeners.swift:87-92, 217`

**Issue:**
- **The contract.** `Watched.outputDataSource` is documented as "the output data source the run's loudness was decided with".
  - On the run path that holds: one open, and the classification and the baseline come from the same `outInfo`.
- **The probe breaks it.**
  - The probe decides its loudness once, from channel 1's open (`if position == 0 { loudness = … }`).
  - It then stops and reopens the backend for every channel.
  - Each reopen reads a fresh `HALDeviceCatalog().listing()` and passes *that* data source as the baseline.
- **The miss.**
  - The output switches route (Intel built-in `ispk` → `hdpn`) after channel N's watcher stopped consuming and before channel N+1's listing. That window covers:
    - the tail after `withDeadline` returns;
    - `stop()`, where `DeviceListeners.remove()` drops in-flight notifications via `stopped.isSet`;
    - the next `open`.
  - Channel N+1's listener then compares against `hdpn` and stays silent, while the probe keeps channel 1's ceiling.
  - Concretely: built-in `ispk` → probe ceiling -18 (unknown). After the switch it keeps climbing to -18 into headphones, 12 dB above the -30 ceiling, for every remaining channel of a multi-channel input.
- **Size.** The window per channel boundary is milliseconds to tens of milliseconds (HAL notification latency), so it is narrow. It is still a structural miss of exactly the event WR-14 exists for, and WR-14's design (compare with the classified value, not with whatever is current) was not carried over to the reopen loop.

**Fix:** carry the classification across reopens. Either pass the first open's data source into every later open, or, simpler and backend-agnostic, re-derive the loudness after each open and abort when it differs:
```swift
let info = try await backend.open(channelSetup, templates: [nominal])
let now = try LevelRamp.probeLoudness(setup: channelSetup, output: info.outputDevice, options: options)
if let first = loudness {
  let before = firstOutputDataSource            // saved at position 0
  let after = info.outputDevice?.output?.dataSource
  if now != first || after != before {
    await backend.stop()
    throw SoundPingError.forDeviceEvent(
      .outputRouteChanged(uid: setup.output.uid, property: "dataSource",
                          from: before ?? "none", to: after ?? "none"))
  }
} else {
  loudness = now
  firstOutputDataSource = info.outputDevice?.output?.dataSource
}
```
- Add a simulator test: a backend whose second `open` reports `hdpn` for an output whose first open reported `ispk` must end the probe with `outputRouteChanged`.

### WR-16: A `--level` above the ceiling that hears nothing reports the requested level, not the clamped level that was played

**File:** `Sources/SoundPingKit/Engine/RunCoordinator.swift:278-287, 318-321`, `Sources/SoundPingKit/Preflight/Preflight.swift:105-106`

**Issue:**
- **Wrong number in the error.** `lockLevel` passes `chosenLevel: fixed` (the raw `--level`), but the probe was played at `ramp.firstLevel = min(fixed, ceiling)`.
  - With `--level -3` on a headphone output, the probe plays at -30 dBFS.
  - The error then says "Nothing was heard at the chosen level of -3 dBFS".
- **The correction is lost.** The "--level … is above the ceiling, so -30 dBFS is used" warning only lives in `PreflightReport`, which a failed run never produces.
- **Why it matters for safety.** The user is told the sound was already at -3 dBFS and inaudible. The natural reactions are to turn the system volume up or reach for `--max-level 0`. The hint then even says the ceiling is the limit, contradicting the -3 the detail claims was played.
- **Not covered.** `nothingHeardOnAHeadphoneListenerPointsAtMaxLevelForASpeaker` only covers `chosenLevel: nil`.

**Fix:**
- Pass the level actually played, and say when it was clamped:
```swift
case .fail(.nothingHeard):
  throw Preflight.nothingHeardError(
    loudness: plan.loudness, probes: probes.count, chosenLevel: fixed.map { _ in level },
    requestedLevel: fixed, terminalApp: plan.permission.app.name)
```
- In `nothingHeardError`, when `requestedLevel > chosenLevel`, write: "Nothing was heard at -30 dBFS (--level -3 was lowered to the -30 dBFS ceiling, set by …)".
- Add `"playedLevelDbfs"` to the context.
- Add a test: `--level -3` on a Bluetooth output with a deaf path → the detail names -30, not -3.

## Info

### IN-22: The loudness invariant cannot catch a drift in the transport strings the classifier keys on

**File:** `Sources/SoundPingKit/Audio/DeviceCatalog.swift:136-152`, `Sources/SoundPingKit/Preflight/LevelRamp.swift:91-113`, `Tests/SoundPingKitTests/LoudnessInvariantTests.swift:97-136`

**Issue:**
- **Three places, no shared constant.**
  - `classify` and `outputIsHeadphones` branch on the string literals `"bluetooth"`, `"builtIn"` and `"virtual"`.
  - `DeviceCatalog.transportName` produces those strings from the HAL transport type.
  - The invariant suite builds its `DeviceInfo`s from hand-written literals.
- **What slips through.** A change on the catalog side keeps every test green while the guarantee drops. Examples:
  - mapping `kAudioDeviceTransportTypeBluetoothLE` to its own `"bluetoothLE"`;
  - renaming `"builtIn"`;
  - the HAL reporting a new transport type that falls into `"other"`.
- **The result.** BLE headphones go from -30 to -18, or the built-in jack fail-safe vanishes, and nothing fails.
- **Why Info.** It needs a future edit to bite. But the suite was written as "the guard against the next hearing-safety regression", and this is the one input to the rule it does not hold.

**Fix:**
- Make the transport an enum (or `static let` constants) shared by `DeviceCatalog`, `LevelRamp` and the tests.
- Add one test that runs `DeviceCatalog`'s mapping over every `kAudioDeviceTransportType*` constant and asserts that the Bluetooth and BLE types classify as headphones and the built-in type follows the `ispk` rule (`transportName` needs to become `internal` for that).

---

_Reviewed: 2026-11-12T20:41:40Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
