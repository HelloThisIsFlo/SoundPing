---
phase: 01-audio-round-trip
fixed_at: 2026-11-12T20:30:13Z
review_path: .planning/phases/01-audio-round-trip/01-REVIEW.md
iteration: 4
findings_in_scope: 10
fixed: 10
skipped: 0
status: all_fixed
---

# Phase 01: Code Review Fix Report

**Fixed at:** 2026-11-12T20:30:13Z
**Source review:** .planning/phases/01-audio-round-trip/01-REVIEW.md
**Iteration:** 4

**Summary (iteration 4, against the third review, the regression pass):**
- Findings in scope: 10 (1 critical, 2 warning, 7 info, IN-21 being the one necessity finding; `fix_scope: all`, the maintainer asked for every finding)
- Fixed: 10, skipped: 0
- CR-04 and WR-13 were fixed together as one loudness model (`0d90368`), with its invariant test in its own commit (`b8f93dc`). WR-14 has a follow-up commit (`82c2f6f`) for a bug its own hardware test found. Every other finding is one commit.
- Ledger across all iterations: 39 findings fixed (11 in iterations 1 and 2, 15 in iteration 3, 3 in the planned change after it, 10 in iteration 4), 0 deferred.

**🔊 The loudness model (CR-04, WR-13), as it now stands:**
- **SoundPing works out the listener from the devices**, in this order:
  - headphones, -30 dBFS: any Bluetooth output, or a built-in output that does not report its speakers (`ispk`)
  - loopback, -6 dBFS: a loop it can see (a `Loop` input channel or a virtual input on the output's own device, or a virtual output into a virtual input)
  - speaker, -12 dBFS: the built-in output reporting `ispk`
  - unknown, -18 dBFS: everything else, including a virtual output heard by a physical microphone (CR-04)
  - `--in-channel auto` does not know the channel yet: headphones -30, else unknown -18
- **`--listener`** describes the setup when SoundPing cannot tell. It sets the reported listener and the chirp band, and can only lower the ceiling (the lower of the detected and the named listener's). It never raises it, so known headphones stay at -30 whatever it says.
- **`--max-level`** replaces the ceiling (louder or quieter) and is the only way to a louder test sound.
- **`--level`** fixes the level instead of the ramp and is still clamped to the ceiling, with a warning.
- Written down once at `LevelRamp.classify`, mirrored in the `--listener`, `--max-level` and `--level` help, the `nothingHeardAtCeiling` hint and a short README section.
- **Behaviour change to know:** `--listener loopback` on an interface the devices cannot identify as a loop (a cable loop on plain inputs) now stays at -18 dBFS; that case needs `--max-level -6`. The help and the error hint say so.

**Verification (iteration 4):**
- **Where it ran:** an isolated worktree (`.claude/worktrees/rf-01-91095-1794513766`, branch `gsd-reviewfix/01-91095`). `swift build`, `swift test` and `scripts/ci-sim.sh` ran before every commit. Main had not moved (base `9e69dbc`), so the 11 commits were fast-forwarded as they are; the hashes below are final.
- **Then once more in the main checkout** after the fast-forward: `swift build`, `swift test` (316 tests in the kit target, 44 in the CLI target) and `scripts/ci-sim.sh` (`ci-sim: OK`). `swift build` passing is also the proof that the IOProc path is still `@_noLocks` after IN-16 and IN-17.
- **Hardware:** `just hw-test` and `just bench` were NOT run and no sound was played. Four no-sound HAL tests ran with `SOUNDPING_HW=1` on this Mac's MacBook Pro Speakers and Microphone (open, listeners and stop only, no IO started): `theOutputRouteIsWatchedOnARealBuiltInOutput`, `deviceListenersRegisterOnARealDeviceAndComeOffAgain`, `anOpenOnAnOpenBackendStopsThePreviousOpen`, `aReopenedBackendHasALiveEventStream`. All pass. That run is what found the WR-14 follow-up.
- `.planning/config.json` and `.planning/state.json` were never staged.

**Summary (iteration 3, against the second full review):**
- Findings in scope: 18 (1 critical, 4 warning including IN-02 which was raised to Warning, 13 info; `fix_scope: all`, the maintainer asked for every finding)
- Fixed: 15 (CR-03, WR-12, IN-02, IN-01, IN-03..IN-07, IN-09..IN-14), one commit each
- Skipped in iteration 3: 3 (WR-01, WR-03, IN-08), deferred to a planned change (maintainer decision) because all three rework the real-time stamp and glitch recording in the IOProc. **They were fixed afterwards in that planned change (quick task 261112-ql0)**: WR-03 in `836f3db`, WR-01 in `e9a3149`, IN-08 in both (stamp half and gap half). So `fixed` above counts them and nothing is skipped.
- Ledger across all iterations: 29 findings fixed (11 in iterations 1 and 2: CR-01, CR-02, WR-02, WR-04..WR-11; 15 in iteration 3; 3 in the planned change: WR-01, WR-03, IN-08), 0 deferred.

**Verification (iteration 3):**
- **Where it ran:** an isolated worktree (`.claude/worktrees/rf-01-7932-1794509161`, branch `gsd-reviewfix/01-7932`). `swift build`, `swift test` and `scripts/ci-sim.sh` ran before every commit. Main had not moved (base `7d43c0e`), so the 15 commits were fast-forwarded as they are; the hashes below are final.
- **Then once more in the main checkout** after the fast-forward: `swift build`, `swift test` (269 tests in the kit target, 44 in the CLI target) and `scripts/ci-sim.sh` (`ci-sim: OK`).
- **Hardware:** `just hw-test` and `just bench` were NOT run, and no sound was played. One hardware test was added for IN-09 and run against the real HAL on this Mac (MacBook Pro speakers and microphone, `open` and `stop` only, no IO started): it fails without the fix and passes with it. Everything else on the HAL side (IN-03 stream formats, IN-05 refused listeners, the real device classification behind CR-03 and WR-12) is covered by the simulator, unit tests of the pure logic, or not at all, so those entries are marked "requires human verification".
- `.planning/config.json` and `.planning/state.json` were never staged.

**Verification (planned change, quick task 261112-ql0):**
- `swift build`, `swift test` (291 tests in the kit target) and `scripts/ci-sim.sh` (`ci-sim: OK`) ran before each of the two commits, in an isolated worktree. `swift build` passing is also the proof that the IOProc path is still `@_noLocks`.
- **Hardware:** `just hw-test` and `just bench` were NOT run and no sound was played. Everything that needs a real loop is marked "requires human verification" below.

## Fixed Issues

**Iteration 4**

### CR-04: A virtual output is now a "loopback" whatever the input: a mic run through a monitored virtual device can ramp to -6 dBFS (regression from the CR-03 fix)

**Status:** fixed: requires human verification (hearing-safety ceiling logic; every combination is unit tested and simulated, but real virtual devices such as Loopback "Monitors" and BlackHole need a check)
**Files modified:** `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Sources/SoundPingKit/Preflight/Preflight.swift`, `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Sources/soundping/Commands/RunOptions.swift`, `README.md`, `Tests/SoundPingKitTests/LevelRampTests.swift`, `Tests/SoundPingKitTests/ChannelProbeTests.swift`, `Tests/SoundPingKitTests/LoudnessInvariantTests.swift` (new)
**Commit:** 0d90368 (model, with WR-13), b8f93dc (invariant test)
**Applied fix:**
- A two-device route is a loop only when both ends are virtual: `classify` uses `(sameDevice && (looped || inputVirtual)) || bothVirtual`. A virtual output with a built-in or USB microphone is now `unknown` (-18 dBFS) again, not `loopback` (-6).
- The test that pinned the regression now expects `unknown` (Mac microphone and USB input), and a new one covers virtual into virtual on two UIDs (`loopback`).
- Fixed as one model with WR-13, written down once in the `classify` doc comment (see the model at the top of this report).
- **Invariant test (`b8f93dc`):** `LoudnessInvariantTests` restates the documented table on its own, then walks 13 output kinds (built-in `ispk`, `hdpn`, no data source, other data source, built-in catalog miss, Bluetooth, Bluetooth catalog miss, USB, Thunderbolt, aggregate, AirPlay, other, virtual) × 6 input kinds (built-in mic, separate interface, plain channel and `Loop 1` on the output's own device, `Loop 1` on another device, another virtual device) × 5 `--listener` values × 3 `--max-level` values (absent, -40, -3) on both the run and the channel-probe path. It asserts the ceiling equals the model, `--listener` never raises it, known headphones never exceed -30 dBFS without `--max-level`, and the probe never exceeds -18. Two parameterized simulator tests drive `RunCoordinator` and `ChannelProbe` and check the loudest gain actually scheduled. Reintroducing the CR-04 rule or the WR-13 override makes it fail (checked).

### WR-13: `--listener` lifts the headphone and Bluetooth ceiling without `--max-level`, though the help says `--max-level` is the only way

**Status:** fixed: requires human verification (hearing-safety logic; behaviour change for `--listener` users)
**Files modified:** same as CR-04
**Commit:** 0d90368 (model, with CR-04), b8f93dc (invariant test)
**Applied fix:**
- One rule for both paths, `LevelRamp.loudness(detected:options:)`: `--max-level` replaces the ceiling; otherwise the ceiling is the lower of the detected listener's and the `--listener` one's. `runLoudness` (classify) and `probeLoudness` (headphones or unknown) feed it, and `RunCoordinator` and `ChannelProbe` call nothing else. `resolveCeiling` and `ChannelProbe.listenerKind` are gone, so the override can no longer be wired around the clamp.
- Maintainer decision applied: known headphones and Bluetooth are lifted only by `--max-level`. Taken one step further for one simple rule: `--listener` never raises any detected ceiling, so `--max-level` is literally the only way up. Cost: `--listener loopback` on an unidentified interface loop stays at -18 dBFS and needs `--max-level -6`.
- `--listener` still picks the reported listener and the chirp band. When it named a louder listener than the devices allow, the run adds a preflight warning ("--listener loopback does not raise the -30 dBFS ceiling of a headphones output; only --max-level allows a louder test sound").
- User-facing strings checked and aligned: the `--listener`, `--max-level` and `--level` help; the `--level` above-ceiling warning; the `nothingHeardAtCeiling` detail and hint, which now name what set the ceiling (devices, `--listener`, `--max-level`) and point at `--max-level` for headphones, speakers and unknown outputs (not for a detected loop, where it is a routing problem). The error context gained `detectedListener` and `ceilingSource`. README got a short "Test-sound loudness" section.
- Tests: the unit rule (raise, lower, unknown to loop), `--listener loopback/speaker/unknown` on a Bluetooth output in a run (never above -30, warning present), the same on the channel probe, and the hint variants.

### WR-14: A headphone plug-in during a run is not watched: a built-in output locked at the speaker level keeps playing into the ears

**Status:** fixed: requires human verification (what the data source and jack of a real built-in output report when headphones go in, especially on Intel Macs, needs hardware; nothing was plugged in during testing)
**Files modified:** `Sources/SoundPingKit/Audio/DeviceListeners.swift`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Audio/AudioBackend.swift`, `Sources/SoundPingKit/Engine/SoundPingError.swift`, `Tests/SoundPingKitTests/AbortTests.swift`, `Tests/SoundPingKitTests/HardwareRoundTripTests.swift`
**Commit:** 6cb2c7c, 82c2f6f (follow-up)
**Applied fix:**
- A playing device's output scope is watched for `kAudioDevicePropertyDataSource` (`'ssrc'`) and `kAudioDevicePropertyJackIsConnected` (`'jack'`), each only where `AudioObjectHasProperty` says it exists, so a device without them is not counted as a refused registration.
- The data source is compared with the one the loudness was classified with (`DeviceInfo.output.dataSource`, passed in from `open`), and checked once right after registering, so a switch between the device read in `open` and the listener is caught too. A jack state is compared with its value at registration.
- A difference yields the new `DeviceEvent.outputRouteChanged(uid:property:from:to:)`, which maps to `deviceChanged` / `outputRouteChanged` and ends a run or a channel probe like any other device change.
- Follow-up `82c2f6f`: with no classified data source (none could be read, which on a built-in output already means -30 dBFS), the value read at registration is the baseline. Without it, the existing no-sound listener hardware test reported a spurious `none → ispk` route change on this Mac's speakers.
- Tests: the event mapping, a run and a channel probe that see the event during the ramp (abort, nothing saved), the selector list, and a no-sound hardware test on the real built-in output (`ispk`): silent while the classified source matches, an immediate `outputRouteChanged` when it does not.

### IN-15: The stack documentation still lists swift-log as a shipped, always-used dependency (IN-05 residual)

**Status:** fixed
**Files modified:** `AGENTS.md`, `.planning/research/STACK.md`
**Commit:** facddc7
**Applied fix:** maintainer decision applied (keep swift-log removed). `CLAUDE.md` is a symlink to `AGENTS.md`, and its stack section is generated from `.planning/research/STACK.md`, so both were edited identically. The Supporting Libraries row now says "Not used yet. Removed in Phase 1 (IN-05) because nothing used it; add it back when structured logging is actually needed". The licence table lists swift-log on its own row as not shipped ("no, not a dependency today", OK if added back). The `Package.swift` sketch in STACK.md drops it with the same note. The sources line (where version 1.17.0 was checked) is unchanged.

### IN-16: A wrapped ring's "forgotten" range is bounded by retained lower bounds, and the oldest slot can be read torn

**Status:** fixed: requires human verification (memory-ordering logic; covered by a concurrent stress test, not by a proof)
**Files modified:** `Sources/SoundPingKit/Audio/RTState.swift`, `Tests/SoundPingKitTests/FaultRecordingTests.swift`
**Commit:** 130ffc6
**Applied fix:**
- `FaultRing.append` folds the upper bound of each interval it is about to overwrite into an `Atomic<Int>` running maximum (`forgottenUpper`), as suggested. `scan` reports `logOverwritten` over `query ∩ (-∞, forgottenUpper)`, so a long gap pushed out by later short faults still rejects the hits inside it.
- Torn reads, adapted from the suggestion: re-loading `written` after the copy cannot see a write that is in flight (it publishes only at the end), so both rings now also announce a write before touching a slot (`started` with a release store, then a release fence; seqlock style). `FaultRing.retained`, `StampRing.snapshot` and `StampRing.entry(at:)` re-check `started` after their copy (acquire fence) and drop any slot a write may have been overwriting. A dropped fault slot is already folded into `forgottenUpper`, so dropping it fails safe.
- RT cost per append: one store and one fence, plus a load and a store when the ring has wrapped. No locks or allocation; `@_noLocks` compiles.
- Tests: the long-interval case from the review; the existing wrap test now expects the tighter forgotten range (`0..<110`, the overwritten uppers, instead of `0..<200`); a writer thread wrapping 4-slot rings 200 000 times while readers copy them. Without the re-check the stress test finds 20 to 50 torn copies per run (checked); with it, none in repeated runs.

### IN-17: A backward sample-time jump moves the published label backwards and poisons everything below the old position

**Status:** fixed: requires human verification (whether and when the HAL resets sample time mid-IO needs hardware; the IOProc logic is unit tested, the HAL wait-loop wiring is not)
**Files modified:** `Sources/SoundPingKit/Audio/RTState.swift`, `Sources/SoundPingKit/Audio/IOCycle.swift`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Audio/AudioBackend.swift`, `Sources/SoundPingKit/Engine/SoundPingError.swift`, `Tests/SoundPingKitTests/FaultRecordingTests.swift`, `Tests/SoundPingKitTests/IOCycleTests.swift`
**Commit:** 4961d8c
**Applied fix:**
- A callback whose sample time is more than half a frame behind the expected label sets `inputClockWentBack` or `outputClockWentBack` (one atomic store), does not publish the lower label, and captures or mixes nothing more in that direction (output buffers stay zeroed). No fault interval is recorded: it is a restart, not a gap. A forward jump is a lost-frames fault as before.
- `HALBackend.waitUntilCaptured` checks both flags on every poll, yields the new `DeviceEvent.sampleClockReset(uid:)` once and throws `deviceChanged` / `sampleClockReset`, so the run ends as a device change instead of rejecting every later hit or waiting for the labels to climb back. Labels never fall, which the `faults` completeness contract and `readCapture` assume.
- Any backward step beyond the half-frame tolerance counts, also a small one, since a sample clock should never repeat frames.
- Tests: input and output resets keep their labels, later callbacks on the new clock are ignored, captured audio stays readable, the half-frame tolerance table, and the error mapping. The old backward-jump test (which pinned the fault-interval behaviour) was replaced.

### IN-18: The overload interval and the settle are sized from the buffer requested at open, not the one the device settled on

**Status:** fixed: requires human verification (how late `'over'` arrives on a real device is still unmeasured)
**Files modified:** `Sources/SoundPingKit/Audio/DeviceListeners.swift`, `Sources/SoundPingKit/Engine/HitListener.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Tests/SoundPingKitTests/AbortTests.swift`
**Commit:** a20918a
**Applied fix:**
- The `'over'` handler reads the buffer size from `BufferBaselines`, the same Mutex `adoptSettledBuffers` updates, and computes the lookback (two buffers, at least 20 ms) and the forward margin (one buffer) from it on each notification.
- `HitListener` sizes its settle from the started (settled) info: two of the larger buffer, at least `faultSettleMs` (20 ms), and explicitly capped at `maxFaultSettleMs` = spacing margin - 5 ms (45 ms). This is the "validate, not assume" part: the cap guarantees the wait ends inside the 50 ms slack, and a test checks it over 44.1/48/96 kHz and 16 to 4096 frames. At 1024 frames and 48 kHz the settle is now 2048 frames (42.7 ms), up from 960.
- When the cap bites (above about 1080 frames at 48 kHz), the run says so in its preflight warnings (the settle is shorter than two buffers, so a late `'over'` may let a glitched hit through). I chose a warning over refusing large buffers.

### IN-19: The channel probe treats a glitched probe as heard and climbs 12 dB on it (IN-01 residual)

**Status:** fixed: requires human verification (probe logic around real-time faults; simulated only)
**Files modified:** `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Tests/SoundPingKitTests/ChannelProbeTests.swift`
**Commit:** a52cae8
**Applied fix:** mirrors `lockLevel`. A glitched probe is replayed at the same level, at most `LevelRamp.maxGlitchRetries` times per level, and never sets `heardSomething` or the best confidence. After the replays the climb goes on, never above the ceiling. A channel left unjudged by glitches keeps the probe from reporting `inputDigitalSilence` (it was not "only zeros"). Tests: two glitches replay at -48 dBFS and then give exactly the clean climb and score; endless glitches stay bounded (4 plays per level) and end in `nothingHeardAtCeiling` at -18; dead channels with a glitch are `inputDigitalSilence` again.

### IN-20: Reopen is fixed for HAL open → stop → open only: the simulator's stream stays finished, and open → open leaks running IOProcs (IN-09 residual)

**Status:** fixed: requires human verification (the HAL open-on-open path ran on real devices without IO; a full probe or run on a reused backend with sound was not run)
**Files modified:** `Sources/SoundPingKit/Simulation/SimulatedBackend.swift`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Audio/AudioBackend.swift`, `Tests/SoundPingKitTests/SimulationRecoveryTests.swift`, `Tests/SoundPingKitTests/HardwareRoundTripTests.swift`
**Commit:** 704271d
**Applied fix:**
- `SimulatedBackend` keeps its stream behind a Mutex like `HALBackend`: `stop()` finishes it, the next `open()` makes a fresh one, and `events` is read per open.
- On both backends an `open()` on a backend that is still open stops the previous open first (HAL: the `stop()` body, so its IOProcs, listeners and stream go; simulator: its stream). I chose this over throwing `alreadyOpen`, so a caller that reopens gets a clean backend instead of an error. The protocol's `open` doc states it.
- Tests: a sample-rate change after open, stop and reopen still aborts the run with `sampleRateChanged`; open on open finishes the previous stream on the simulator; and the same on the real HAL (open only, no IO, no sound), which passes.

### IN-21: Already-defended-elsewhere: the label loads in `RTState.faults` are discarded and add no ordering

**Status:** fixed
**Files modified:** `Sources/SoundPingKit/Audio/RTState.swift`
**Commit:** 62032fb
**Applied fix:** removed the two discarded acquiring loads, as the review recommends. The doc comment now says what really provides visibility and completeness: the rings' own release/acquire counts, and the caller having waited past the window (`waitUntilCaptured` acquire-loads the input label).

**Iteration 3**

### CR-03: A virtual or "Loop" input overrides the headphone ceiling: the ramp can reach -6 dBFS in headphones (external: codex)

**Status:** fixed: requires human verification (hearing-safety ceiling logic; the pure classification is unit tested, the real device combinations need hardware)
**Files modified:** `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Tests/SoundPingKitTests/LevelRampTests.swift`
**Commit:** c0736f5
**Applied fix:**
- `LevelRamp.classify` checks the output first: `outputIsHeadphones` (built-in headphones, any Bluetooth output) returns `.headphones` (-30 dBFS) whatever the input is. `.loopback` is returned only when the output feeds the input: the same device with a `Loop` channel or a virtual input, or a virtual output. A built-in speaker output with a virtual input or a `Loop` channel on another device now gets -12 dBFS, not -6. A USB interface output next to a virtual input on another device is `.unknown` (-18).
- The review's snippet was applied as suggested. The doc table in the `classify` comment now lists headphones first and says why.
- Tests: headphones, Bluetooth and speakers each combined with a virtual input and with a `Loop` channel on another device; a virtual output; the recorded-transport fallback; and an end-to-end ramp with a Bluetooth output and a virtual input (channel named "Loop 1") that never goes above -30 dBFS.

### WR-12: A built-in output without a readable `hdpn` data source gets the speaker ceiling: the classifier fails open

**Status:** fixed: requires human verification (safety ceiling classification; what the headphone jack reports on Apple Silicon is still a hardware question)
**Files modified:** `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Sources/SoundPingKit/Preflight/Preflight.swift`, `Sources/soundping/Commands/RunOptions.swift`, `Tests/SoundPingKitTests/LevelRampTests.swift`
**Commit:** f4b8604
**Applied fix:**
- `outputIsHeadphones` now proves "speaker" instead of "headphones": Bluetooth is headphones, and a built-in output is headphones unless its data source is `ispk`. A nil, unreadable or other data source (and a catalog miss with only a recorded `builtIn` transport) gets -30 dBFS. This also decides the `--in-channel auto` probe ceiling, which uses the same function.
- Updated the ceiling table in the `classify` doc comment, the `--max-level` help text, the channel-probe doc comment, and the `nothingHeardAtCeiling` hint on a headphone listener (it now names built-in outputs that do not report their speakers as well as Bluetooth).
- Tests: built-in output with `dataSource: nil`, with another source, with no device info at all, and the `ispk` case that keeps the speaker ceiling. The cost on this machine is nil: the built-in speakers report `ispk`.

### IN-02: The same-device window has no pre-roll, so a near-zero path is rejected as `outsideWindow`

**Status:** fixed: requires human verification (window logic; the exact label offset of a real software loop such as Rogue Amoeba Loopback needs a bench run)
**Files modified:** `Sources/SoundPingKit/Engine/HitListener.swift`, `Tests/SoundPingKitTests/LevelRampTests.swift`
**Commit:** 857e395
**Applied fix:**
- A same-device window now starts one pre-roll (5 ms) before the output frame, like the two-device window, clamped at frame 0. The reported latency is still `frame - outputFrame`, so nothing else changes. Level probes and the channel probe go through the same `listen`, so a zero-delay loop no longer fails the whole preflight with `nothingHeardAtCeiling`.
- **Decision on a negative path:** it is kept as measured, not rejected. A driver that labels input slightly early gives a negative number, and the number is what the labels say; rejecting it would hide a real finding. The reasoning is in the `listen` comment. No flag is added to the result.
- Tests: a 0-frame path measures about 0 (20 of 20 valid), and a -24-frame path is measured as -24 with no `outsideWindow` rejections. Both fail without the change (checked).
- Not touched: the overload check in `listen` (WR-01).

### IN-01: A probe rejected for an overload or a discontinuity counts as "not heard", so the ramp climbs 6 dB

**Status:** fixed: requires human verification (ramp logic around a real-time fault)
**Files modified:** `Sources/SoundPingKit/Preflight/ProbePlayer.swift`, `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Tests/SoundPingKitTests/LevelRampTests.swift`
**Commit:** 4f4815f
**Applied fix:**
- `ProbePlayer.Played` gained `glitched` (an overload, or a detection rejected as `.discontinuity`). `lockLevel` replays a glitched probe at the same level, at most `LevelRamp.maxGlitchRetries` (3) times per level, before the ramp takes the answer as it is. The counter resets when the ramp steps. The level never exceeds the ceiling either way. Every replay is still listed in the probe events and the report.
- The channel probe is unchanged: it keeps its own loop and is not part of this finding's files.
- Tests use a small forwarding backend that makes the first N listening windows report lost frames: two glitched probes then a clean one stay at -48 dBFS, and an endless run of glitches still ends in `nothingHeardAtCeiling` after exactly 8 levels x 4 plays, none above the ceiling.

### IN-03: `requireFloat32` checks only the first stream of a scope

**Status:** fixed: requires human verification (HAL path, no simulator coverage)
**Files modified:** `Sources/SoundPingKit/Audio/HALBackend.swift`
**Commit:** 62edfb9
**Applied fix:** `requireFloat32` takes the buffers (streams) the selected channels sit in (every output slot's, and the input slot's) and checks each one's `kAudioStreamPropertyVirtualFormat`. A stream whose format cannot be read, or that does not exist at that index, is refused as `unsupportedStreamFormat` instead of passing silently. The stream index in the channel list and the index into `kAudioDevicePropertyStreams` come from the same stream order. No unit test is possible without a device; the hardware tests compile against it. The risk to confirm on hardware is a device whose streams cannot be read at all, which is now refused where it used to be let through.

### IN-04: Doc comments contradict the code

**Status:** fixed
**Files modified:** `Sources/SoundPingKit/Audio/HALProperty.swift`, `Sources/SoundPingKit/Store/RunStore.swift`, `.planning/phases/01-audio-round-trip/01-SECURITY.md`
**Commit:** 1a5839d
**Applied fix:** the `HALProperty` header now says nothing in that file sets a property and names `HALBackend.applyBuffer` as the one place SoundPing sets one (its own buffer size). `RunStore.runFile` says an id is resolved under `runs/` only and an absolute path is read where it points. The T-01-19 and T-01-34 rows in the security audit say the same.

### IN-05: Dead code and an unused dependency

**Status:** fixed: requires human verification (the refused-listener warning comes from the HAL path)
**Files modified:** `Package.swift`, `Package.resolved`, `Sources/SoundPingKit/Audio/AudioBackend.swift`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Audio/HALProperty.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Sources/soundping/Render/ExitCodes.swift`, `Tests/SoundPingKitTests/PreflightTests.swift`, `.planning/phases/01-audio-round-trip/01-SECURITY.md`
**Commit:** 8364a6c
**Applied fix:**
- Dropped `swift-log` from `Package.swift` and `Package.resolved` (nothing imported `Logging`), `ExitCodes.exitCode(for:)` (and its now-unused `ArgumentParser` import) and `HALProperty.has`. The T-01-SC row in the security audit follows.
- `BackendInfo` gained `warnings`. The HAL backend fills it when `DeviceListeners.refused > 0` ("the HAL refused N device-change notification(s), so a device change during this run may not abort it"), and the coordinator puts it into the preflight warnings, which the CLI prints as `Preflight: ...`. A test pushes a backend warning through a run into `result.preflight.warnings`.
- **Left as it is:** `AGENTS.md` (and so the `CLAUDE.md` stack section generated from it) still lists swift-log as a recommended library ("Structured logs ... Always"). That is the stack decision record, not code, so it is for the maintainer to keep or amend.

### IN-06: Duplicated logic

**Status:** fixed
**Files modified:** `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Store/Setups.swift`
**Commit:** dcdc409
**Applied fix:** removed `HALBackend`'s private `preflight` helper in favour of `SoundPingError.preflight`. `Setups.load` and `Setups.save` now go through `VersionedFile`, so setups decode with `RunJSON.decoder()` like the other stores. The error codes (`setupsUnreadable`, `setupsUnwritable`) are unchanged; two message texts differ slightly (the "not valid JSON of the expected shape" wording and "cannot write the saved setups file"). The existing resolver tests for unreadable setups still pass.

### IN-07: Several stdout writes bypass `Output`'s guarded write

**Status:** fixed
**Files modified:** `Sources/soundping/Render/JSONRenderer.swift`, `Sources/soundping/Commands/DevicesCommand.swift`, `Sources/soundping/Commands/RunsCommand.swift`
**Commit:** 9ae47ec
**Applied fix:** `JSONRenderer.write`, `writeJSONLine` (`devices`), `runs list --json` and `runs show --json` use `Output.writeData`. Checked by hand: piping each of `run --simulate --json`, `devices --json`, `runs list --json` and `runs show --json` into `head -c1` exits 0.

### IN-09: `HALBackend` is not reusable after `stop()`, though ChannelProbe reopens it

**Status:** fixed: requires human verification (the hardware test below ran, but only open and stop; a full probe or run on a reused backend was not run)
**Files modified:** `Sources/SoundPingKit/Audio/HALBackend.swift`, `Tests/SoundPingKitTests/HardwareRoundTripTests.swift`
**Commit:** 573b480
**Applied fix:** the event stream and its sink live in the backend's state now. `open()` calls `beginOpen()`: after a `stop()` it makes a fresh stream (so `events`, read after `open`, is live again), and every open resets `gapsReported` and `stallReported` and clears `stopped`. A first open keeps the stream made at `init`. The backend stays reusable instead of single-use because `ChannelProbe` reopens it per channel. New hardware test `aReopenedBackendHasALiveEventStream` (open, stop, open on a real device, no IO started, no sound): fails without the fix, passes with it, both checked on this Mac.
- Touches `surfaceGaps` and `reportStall` only in that they read the sink through the state now; the gap recording itself is untouched (WR-01).

### IN-10: `--in-channel auto` ignores device changes while it probes (external: codex)

**Status:** fixed: requires human verification (logic; the HAL events themselves need a real device change)
**Files modified:** `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Sources/SoundPingKit/Engine/SoundPingError.swift`, `Tests/SoundPingKitTests/ChannelProbeTests.swift`
**Commit:** 53b8d90
**Applied fix:** each channel's probe now races the backend's `events` as well as the 60 s deadline. Any non-overload event ends the probe with the matching `deviceChanged` error. The event-to-error mapping the run supervisor used moved to `SoundPingError.forDeviceEvent`, so the run and the probe share it. The stream is the per-open one from IN-09, so the second channel's probe is watched too. A test announces a sample-rate change while the first channel waits for samples and expects `deviceChanged` / `sampleRateChanged`.

### IN-11: `RunParameters.minValidFraction` is never validated (external: codex)

**Status:** fixed
**Files modified:** `Sources/SoundPingKit/Engine/HitScheduler.swift`, `Tests/SoundPingKitTests/SchedulerTests.swift`
**Commit:** d4bf094
**Applied fix:** `HitScheduler.validate` requires `minValidFraction` finite, above 0 and at most 1, and throws `invalidParameters` naming `minValidFraction` otherwise. NaN, infinity, 0, negatives and 1.5 are refused before anything plays; 0.01, 0.5 and 1.0 pass.

### IN-12: Simulation flags are not range-checked and can trap the process (external: codex)

**Status:** fixed
**Files modified:** `Sources/soundping/Commands/SimulationOptions.swift`, `Tests/soundpingTests/SimulationOptionsTests.swift` (new)
**Commit:** 15a88ac
**Applied fix:** `SimulationOptions.scenario` requires every numeric flag finite and in range, or throws `invalidParameters` naming the flag: `--sim-latency` -48000...480000 frames, `--sim-jitter` 0...48000 frames, `--sim-noise` 0...1, `--sim-gain-db` -300...300, `--sim-drift-ppm` and `--sim-stamp-bias` within +-10000. The bounds are my picks, wide enough for any real test and far inside what traps; a small negative latency stays allowed because IN-02 makes it meaningful. Confirmed on the CLI: `--sim-stamp-bias 1e300` prints the error envelope and `--sim-latency inf` exits 64.

### IN-13: A side-file write failure after run.json turns a saved run into a reported failure (WR-02 residual)

**Status:** fixed: requires human verification (behaviour choice: the review offered two designs)
**Files modified:** `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Tests/SoundPingKitTests/CalibrationStoreTests.swift`
**Commit:** 5e93ac7
**Applied fix:** I took the first design (a warning on a finished run). Once run.json is written, the calibration write and the self-test write are each tried on their own; a failure becomes a warning ("calibration not stored: ...", "clock self-test record not stored: ...") in `result.preflight.warnings`, `.finished` is still emitted, and the exit code stays the run's. A failed calibration write also sets `calibration.stored = false`, and run.json is then rewritten once so it tells the truth (best effort: if that second write fails too, the first stays as the saved run). The self-test record is attempted even when the calibration write failed. The CLI prints the warning in its `Preflight:` line, not as a separate `warning:` line, because that is where the result carries warnings today. A test makes the store root read-only and checks both warnings, `stored: false` in memory and in run.json, and one listed run.

### IN-14: `recipes` output still disagrees with what a run uses

**Status:** fixed
**Files modified:** `Sources/soundping/Commands/RecipesCommand.swift`, `Sources/SoundPingKit/Preflight/LevelRamp.swift`, `Tests/soundpingTests/RecipesCommandTests.swift` (new)
**Commit:** 4f097f8
**Applied fix:** `defaults.templateId` is now explicitly `null`, next to a new `defaults.templateRule` ("follows the listener unless --template is given (chirp-loopback for a loop, chirp-speaker otherwise)"), so copying the advertised default into `--template` can no longer change behaviour. The `recipes --json` envelope is `schemaVersion` 2. The text listing says the rule too. This is a JSON contract change. The command's types are internal now so a test can encode them.

**Planned change after iteration 3 (quick task 261112-ql0)**

### WR-03: The stamp log pairs input and output by array index, and the 2^21-entry ring wraps on long runs

**Status:** fixed: requires human verification (real-time stamping on a physical loop: the duplex I/O offset and `appRoundTrip` of a real interface must match a run recorded before the change)
**Files modified:** `Sources/SoundPingKit/Audio/RTState.swift`, `Sources/SoundPingKit/Audio/IOCycle.swift`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Clock/DeviceTimeline.swift`, `Sources/SoundPingKit/Clock/ClockSelfTest.swift`, `Sources/SoundPingKit/Simulation/SimulatedBackend.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Tests/SoundPingKitTests/IOCycleTests.swift`, `Tests/SoundPingKitTests/ClockTests.swift`
**Commit:** 836f3db
**Applied fix:**
- One stamp-ring entry per duplex callback: the entry holds the input side and the output side of that callback, and a side that was skipped or untimestamped leaves its half empty. `StampLog.ioOffsetFrames` is built from entries that have both sides, and `RunCoordinator` reads it for the I/O offset and `appRoundTrip` instead of zipping the two lists.
- No ordinal pairing across two devices: an input device and a separate output device each write their own ring, `callbackStamps(covering:)` walks the input ring only and returns output fields of 0 when its entry has no output side, and `ioOffsetFrames` is empty on two devices.
- The ring stays at 2^21 entries. `calloc` keeps untouched pages virtual, so a bigger ring is not the fix. Instead `ClockSelfTest.evaluate` judges only hits inside `DeviceTimeline.coveredSamples` (the callbacks the log still holds) and never extrapolates; when it judged fewer hits than were valid, `finish` adds a warning to the run's preflight warnings, so run.json says so. Chosen over resizing the ring from the run length because it is correct for any run length, with no tuning.
- `ioCycle` is the single `@_noLocks` IOProc entry point; the HAL block calls only it. The two cycle helpers return their side and no longer append stamps.
- Tests: a skipped output side (invalid time, zero-channel buffer) leaves 9 exact offsets of 10 callbacks; two devices never pair; a wrapped ring of 8 holds 8 exact offsets and refuses overwritten ordinals; a self-test over half a wrapped log judges exactly the hits inside it.
- **Still needs hardware:** the unchanged duplex I/O offset median and `appRoundTrip` on a real interface, and `soundping selftest clock` passing with no self-test warning on a normal-length run.

### WR-01: Overload rejection is racy and checks a single frame, not the lost interval

**Status:** fixed: requires human verification (how late the HAL `'over'` notification arrives after a glitch, and the medians of surviving hits under forced overloads, need a physical loop)
**Files modified:** `Sources/SoundPingKit/Audio/RTState.swift`, `Sources/SoundPingKit/Audio/IOCycle.swift`, `Sources/SoundPingKit/Audio/AudioBackend.swift`, `Sources/SoundPingKit/Audio/HALBackend.swift`, `Sources/SoundPingKit/Audio/DeviceListeners.swift`, `Sources/SoundPingKit/Simulation/SimulatedBackend.swift`, `Sources/SoundPingKit/Engine/HitListener.swift`, `Sources/SoundPingKit/Engine/RunCoordinator.swift`, `Sources/SoundPingKit/Engine/SoundPingError.swift`, `Sources/SoundPingKit/Preflight/ChannelProbe.swift`, `Sources/SoundPingKit/Preflight/ProbePlayer.swift`, `Tests/SoundPingKitTests/FaultRecordingTests.swift` (new), `Tests/SoundPingKitTests/IOCycleTests.swift`, and the five forwarding test backends
**Commit:** e9a3149
**Applied fix:**
- Faults are intervals in the label space of the direction they hit, kept in four preallocated single-writer rings (input and output written by the IOProc, input and output overloads written only from the listeners' serial queue). Each gap, invalid-timestamp callback and overload is its own entry; nothing is merged. The IOProc appends a fault before the label store that follows it.
- `AudioBackend.faults(overlappingInput:output:)` has no default implementation: an empty default would fail open. The HAL and simulated backends answer it, and the test backends forward it. A hit is rejected when any fault overlaps its input window or its played output frames (overlap, not containment).
- The ring fails safe: once a ring has wrapped, a query reaching below its oldest entry gets one `logOverwritten` fault for that stretch, so overflow rejects hits rather than passing them.
- The overload `DeviceEvent` and the stream-fed `FaultMonitor` are gone. `HitListener.listen` waits for the window plus a 20 ms settle margin (`faultSettleMs`, well under the 50 ms hit spacing), then queries the backend directly. No event-stream hop sits between a glitch and the reject decision.
- The `'over'` handler calls `RTState.noteOverload`, which records `[next - lookback, next + buffer)` with a lookback of at least two buffers or 20 ms (`overloadLookbackMs`), in the labels of the device's own directions. An output device's overload lands in output labels, never on the input position (WR-01 item 4).
- The output direction got the same label-continuity check as the input, so an output that skipped frames is a recorded fault too.
- Tests: forward, repeated and backward jumps; invalid-timestamp faults in both directions; output jumps; overload mapping for capturing and output-only devices; overlap versus touching edges; the wrapped-ring fail-safe; and `HitListener` over a wrapper backend with a silent event stream (input fault, output fault, and a fault outside both ranges). The existing `overload@12` case still gives exactly one `discontinuity` rejection.
- **Residual, accepted (T-ql0-06):** the primary, race-free signal is the IOProc's own label-continuity check. An overload that loses no frames leaves the labels intact and is only caught through the `'over'` notification, which needs the 20 ms margins to hold. **Still needs hardware:** measure how late `'over'` arrives on a real device; if it exceeds the margins, raise both constants.

### IN-08: The IOProc stamps `mHostTime` and `mSampleTime` without checking `mFlags`

**Status:** fixed: requires human verification (real driver flags; the tests use synthetic timestamps)
**Files modified:** `Sources/SoundPingKit/Audio/IOCycle.swift`, `Sources/SoundPingKit/Audio/RTState.swift`, `Tests/SoundPingKitTests/IOCycleTests.swift`, `Tests/SoundPingKitTests/FaultRecordingTests.swift`
**Commit:** 836f3db (stamp half), e9a3149 (gap half)
**Applied fix:**
- Stamp half: `mFlags` is read as raw bits (`sampleTimeValid` 1, `hostTimeValid` 2, `rateScalarValid` 4), not through `OptionSet.contains`, which `@_noLocks` may refuse. An input without `sampleTimeValid` captures nothing (its frames come back as a gap at the next valid callback); an output without it mixes nothing and moves no label. A side without `hostTimeValid` is captured or mixed and its label advances, but it is never logged, so a host time of 0 cannot reach `DeviceTimeline` or the self-test. Without `rateScalarValid` the side is logged with rate scalar 0, which `DeviceTimeline` already treats as 1.
- Gap half: a callback with `sampleTimeValid` but no `hostTimeValid` records an `invalidTimestamp` fault for its frames in its own direction, so no hit is measured across a callback that cannot be timestamped.
- Tests: the flag combinations on input and output through `ioCycle`, and the invalid-timestamp faults in both directions.

**Iterations 1 and 2**

These 11 entries are kept as they were so the disposition ledger carries over. Notes on what iteration 3 changed about them are marked "Since:".

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
- Since: CR-03 fixed the same ordering problem in `classify` itself, and WR-12 made `outputIsHeadphones` fail safe for a built-in output that does not report `ispk`.

### WR-02: Calibration and self-test records are written before run.json, so a failed write orphans them

**Status:** fixed: requires human verification (ordering)
**Files modified:** `Sources/SoundPingKit/Engine/RunCoordinator.swift`
**Commit:** 709047d
**Applied fix:** `storeCalibration` became `calibrationToStore`, which only decides and returns the `CalibrationRef` plus the record. `finish` now writes run.json first, then the calibration record, then the self-test record. If run.json cannot be encoded or written, no side file is touched. If a side-file write fails after run.json is written, the run exists with `calibration.stored == true` and no calibration entry; that is a smaller fault than an orphan record, but not zero.
- Since: IN-13 closed that residual (a side-file failure is now a warning on a finished run, run.json is corrected, and the self-test record is still attempted).

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
- Since: IN-14 bumped the `recipes --json` envelope to `schemaVersion` 2 for this rename and for the template default.

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
- Since: "a loopback input is still classed as loopback first" was the CR-03 hole; the output's ceiling now wins first.

## Skipped Issues

None.

---

_Fixed: 2026-11-12T20:30:13Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 4_
