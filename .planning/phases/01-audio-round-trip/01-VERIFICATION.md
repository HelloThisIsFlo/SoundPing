---
phase: 01-audio-round-trip
verified: 2026-11-12T15:30:00Z
status: human_needed
score: 4/5 must-haves verified
covered_files:
  - .github/workflows/ci.yml
  - .planning/phases/01-audio-round-trip/01-01-PLAN.md
  - .planning/phases/01-audio-round-trip/01-01-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-02-PLAN.md
  - .planning/phases/01-audio-round-trip/01-02-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-03-PLAN.md
  - .planning/phases/01-audio-round-trip/01-03-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-04-PLAN.md
  - .planning/phases/01-audio-round-trip/01-04-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-05-PLAN.md
  - .planning/phases/01-audio-round-trip/01-05-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-06-PLAN.md
  - .planning/phases/01-audio-round-trip/01-06-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-07-PLAN.md
  - .planning/phases/01-audio-round-trip/01-07-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-08-PLAN.md
  - .planning/phases/01-audio-round-trip/01-08-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-09-PLAN.md
  - .planning/phases/01-audio-round-trip/01-09-SUMMARY.md
  - .planning/phases/01-audio-round-trip/01-10-PLAN.md
  - .planning/phases/01-audio-round-trip/01-10-SUMMARY.md
  - LICENSE
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
  - justfile
  - scripts/bench.sh
  - scripts/ci-sim.sh
  - scripts/cli.sh
  - scripts/test.sh
covered_digest: "v4:sha256:9c21efe624b482bfa92ed307bf5240752b727149f1dbb8d2b2c37f3216e9816d"
behavior_unverified: 1
overrides_applied: 0
behavior_unverified_items:
  - truth: "Broken setups stop with a named cause: missing mic permission naming the owning terminal app, and a device that disappears or changes sample rate or buffer mid-run (SC4 / ENG-03, ENG-07)"
    test: "Reset Ghostty's mic grant (`tccutil reset Microphone com.mitchellh.ghostty`) and run on real hardware; separately start a hardware run and change the sample rate in Audio MIDI Setup or unplug the interface"
    expected: "Mic denial stops before any hit with micPermissionDenied (exit 65) naming Ghostty; the device change aborts with a named code (deviceGone / sampleRateChanged / bufferSizeChanged), exit 75, and saves nothing"
    why_human: "The engine-level abort and the denial path are exercised by passing simulated tests (AbortTests, PreflightTests; reproduced here via --sim-permission denied -> exit 65, --sim-fault -> exit 75). The seam from real TCC state and real HAL property listeners into those events has no test; the listener registration is proven only by a hardware register/remove smoke"
human_verification:
  - test: "Real mic denial names the owning app (ENG-03)"
    expected: "After `tccutil reset Microphone com.mitchellh.ghostty`, `soundping run round-trip` with a mic input stops with micPermissionDenied naming Ghostty and the System Settings fix; re-grant works"
    why_human: "Needs real TCC state; ResponsibleApp's process-tree walk and AVCaptureDevice status are only unit-tested against fakes"
  - test: "Terminal.app mic prompt or denial (RESEARCH Q3)"
    expected: "Run the CLI from Terminal.app (no NSMicrophoneUsageDescription in its Info.plist) and record whether macOS prompts or silently denies, and what SoundPing reports"
    why_human: "Unknown OS behaviour; cannot be driven from a non-interactive session. Package.swift embeds no Info.plist in the CLI (STACK.md recommends one), so the non-terminal-parent case is also unchecked"
  - test: "Unplug the interface / change sample rate or buffer mid-run on real hardware (ENG-07)"
    expected: "Named abort, exit 75, no run saved as a valid result"
    why_human: "Needs a physical device change"
  - test: "Listening check on MacBook speakers and on headphones"
    expected: "The level ramp (starts -48 dBFS; the ceiling comes from the output alone: built-in speakers -12 / headphones and Bluetooth -30 / everything else -18, loops included; the `--in-channel auto` probe uses the same ceilings) is comfortable and never painful. The bench saw the speaker ramp reach -12 dBFS three times before aborting"
    why_human: "Hearing comfort is a human judgement. Also exercise `--in-channel auto` with headphones plugged in, which must stay at the -30 dBFS headphone ceiling (review finding CR-02, fixed)"
  - test: "Ableton open at buffer 256 while SoundPing runs at 128 (RESEARCH A7)"
    expected: "SoundPing's per-process buffer holds at 128 and the run is valid; the reported SoundPing buffer matches what was applied"
    why_human: "Needs Ableton and a second audio client on the interface"
  - test: "Pretty TTY look"
    expected: "Per-hit lines, dimmed rejections, summary block, histogram and sparkline read well in Ghostty; NO_COLOR gives zero ANSI"
    why_human: "Visual appearance"
  - test: "A real microphone round trip (SC1 'loopback or mic')"
    expected: "At least one acoustic path (external mic, or a template tuned for the MacBook speakers -> built-in mic) produces valid hits and a number"
    why_human: "The only real mic attempt (MacBook speakers -> built-in mic) was refused by preflight with a named cause (inputClipping / nothingHeardAtCeiling, confidence ~0.35 against a 0.5 minimum) and produced no number, so the mic half of SC1 and CAL-01 is unproven on hardware. Whether that is acceptable for Phase 1 (loopback carries the exit gate) is a decision for Flo"
---

# Phase 1: Audio Round Trip Verification Report

**Phase Goal:** Users can measure their audio round trip from the `soundping` CLI and get a trustworthy, saved number, on the engine every later recipe reuses
**Verified:** 2026-11-12T15:30:00Z
**Status:** human_needed
**Re-verification:** No, initial verification

## Verdict

The goal is achieved on the evidence I could check without hardware interaction: a saved, stats-backed round-trip number exists, it was produced on real hardware (Scarlett loop, non-simulated run.json files), the exit gates pass, and the engine is shared by the simulator and the HAL backend. No must-have is FAILED. Status is `human_needed` because the open manual checks include real-TCC and real-device-change behaviour, and the mic half of SC1 has never produced a number on hardware.

The code review (2 critical, 11 warning) does not make the loopback number untrustworthy. Several findings do weaken the trust story at the edges, and two are hearing-safety defects. See "Code review weighed against the goal".

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | List devices by stable ID, pick output + input (loopback or mic), run the click round trip from the CLI, hits land live, randomised spacing, warm-ups discarded | VERIFIED (loopback). Mic half see human item | `soundping devices` ran: 11 real devices with UID, transport, channels, latency/safety/buffer, MIDI listed separately; selectors resolve by UID/name/substring and refuse ambiguity (ResolverTests). `run round-trip --simulate` prints one live line per hit. `HitScheduler.schedule` draws gaps from a seeded SplitMix64 uniform in [450, 750] ms; run.json hits show the first 5 as `phase: warmup`, and `measured` stats cover only the valid measure hits (25 hits -> valid 20/20). Click template exists (`--template click`) and was benched on hardware (100/100). Real hardware runs confirmed from raw bench run.json files (`setup.simulated` false, Scarlett 16i16, 100/100) |
| 2 | Result shows valid/N, median, jitter p5-p95, p95, max, histogram, per-hit timeline in samples and ms; reported next to measured; segments and corrections stated; repeat loopback runs agree within 1-2 samples | VERIFIED | Pretty output rendered: valid 20/20, median/jitter/p95/max in frames and ms, 21-bin Unicode histogram, sparkline timeline, "macOS reports ..." beside each figure, "Segments: Audio output -> Cable or air -> Audio input", "Corrections: none (raw measurement)". Stats recover injected values: `--sim-latency 777.25 --sim-jitter 1` -> median 777.33. Real repeatability from raw JSON: two 100-hit runs median 27.0000001 vs 27.0000001 (second session 26.0000001 vs 26.0000001); one frame between sessions, within the 2-frame limit. Caveat: the loop is the Scarlett's internal digital `Loop 1`, jitter exactly 0, so repeatability is easy there; cable-through-converters was not benched |
| 3 | Every run saved with metadata (devices, sample rate, buffer, recipe, date), label, tags; round trip stored as calibration per device pair, rate, buffer, labelled "round trip", never "mic delay" | VERIFIED | run.json keys: setup (input/output uid+name+transport, sampleRate 48000, bufferFrames 128, channels), recipe {round-trip, 1}, createdAt, label "my test", tags [a, b], runId, toolVersion, os, seed in parameters. `runs list` shows it. CalibrationKey = output UID, out channels, input UID, in channel, rate, buffer; `CalibrationKind` has the single case `roundTrip`, label "round trip"; no "mic delay" anywhere in Sources. Corrections stay `[]`: a stored calibration never alters a measurement (test `nothingCorrectsAMeasurementWithAStoredCalibration`). ci-sim asserts `--json` stdout is byte-identical to the saved run.json |
| 4 | Broken setups stop with a named cause: mic permission naming the terminal app, silent or clipping input, device that disappears or changes rate/buffer; `--simulate` recovers latency and jitter and runs in CI | PRESENT_BEHAVIOR_UNVERIFIED for the real-hardware parts; VERIFIED for everything simulated | Reproduced in simulation: `--sim-permission denied` -> `micPermissionDenied: Microphone access is denied for Ghostty`, fix line, exit 65; `--sim-input-zeros` -> inputDigitalSilence; `--sim-muted` -> outputMuted; `--sim-fault sampleRateChange@30 / deviceGone@10 / bufferChange@12` -> named codes, exit 75; `--sim-miss 8,15 --sim-xrun 25` keeps all hits, rejects with named reasons (discontinuity 1, lowConfidence 2), stats over 27/30. Real code paths exist and are wired: `AVCaptureDevice.authorizationStatus` in HALBackend, `ProcessTreeResolver` walk to the owning `.app`, HAL listeners for `livn / nsrt / fsiz / over` in DeviceListeners, `HALBackend()` selected whenever not `--simulate`. CI runs `scripts/ci-sim.sh` after `swift test`. Real TCC denial and a real device change are unexercised (open manual checks) |
| 5 | Exit gates: host-clock self-test passes on hardware; repo carries PolyForm Shield 1.0.0 before ported code | VERIFIED | `selftest clock` on the Scarlett: median delta -0.00003 frames, p95 0.014 (01-BENCH.md; in-run `selfTest.pass: true` in every raw bench run.json I read; `clock-selftest.json` holds passing Scarlett entries at buffers 64/128/256). Negative control: `selftest clock --simulate --sim-stamp-bias 5` exits 3. LICENSE lines 1-89 hash to the recorded sha256 `56328093...a893a91`, followed by `Required Notice: Copyright 2026 Flo Kempenich`. No ported code exists (no OboeTester or other port in Sources). README and CONTRIBUTING state PolyForm Shield |

**Score:** 4/5 truths verified (1 present, behavior-unverified)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `LICENSE` | PolyForm Shield 1.0.0 verbatim + Required Notice | VERIFIED | hash matches |
| `Package.swift`, `justfile`, `scripts/*`, `.github/workflows/ci.yml` | Buildable repo, CI | VERIFIED | `just test` passes; ci.yml runs build, test, ci-sim |
| `Sources/SoundPingKit/Audio/HALBackend.swift`, `IOCycle.swift`, `RTState.swift` | Raw HAL IOProc, `@_noLocks`, preallocated buffers | VERIFIED | `@_noLocks` on IOCycle/RTState; `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` present; exercised on hardware |
| `Sources/SoundPingKit/Engine/*` | Shared run engine emitting events | VERIFIED | `RunCoordinator` consumes either backend and yields the event stream the three renderers use |
| `Sources/SoundPingKit/Detection/Correlator.swift`, `Stats/Stats.swift` | Rigorous detection and stats | VERIFIED | CorrelatorTests, StatsTests (numpy-matched) pass |
| `Sources/SoundPingKit/Clock/*` | Per-device timelines, self-test | VERIFIED | ClockTests pass incl. 50 ppm drift; hardware self-test passes |
| `Sources/SoundPingKit/Store/*` | Run store, calibrations, self-test store, run lock | VERIFIED | RunStoreTests; `.run.lock` present |
| `Sources/SoundPingKit/Preflight/*` | Permission, ramp, channel probe | VERIFIED in code and simulation; see CR-01/CR-02 |
| `Sources/soundping/Commands/*`, `Render/*` | CLI surface and renderers | VERIFIED | help, devices, recipes, paths, run, runs list/show, selftest all executed |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `RunOptions.makeBackend` | `HALBackend` / `SimulatedBackend` | `guard simulation.simulate else { HALBackend() }` | WIRED | RunOptions.swift:133-138 |
| `DeviceListeners` | `RunCoordinator.abortError` | `AudioEvent` stream -> `deviceChanged` -> exit 75 | WIRED (sim), real device unexercised | AbortTests + ci-sim |
| `RunCoordinator.finish` | `RunStore` / `CalibrationStore` / `ClockSelfTestStore` | writes after the run | WIRED, but ordering flaw WR-02 | run.json written last |
| `Preflight` | `ResponsibleApp` | process-tree walk | WIRED | message names Ghostty |
| `RunCommand` | renderers | `--json`, `--ndjson`, pretty | WIRED | ci-sim asserts ndjson ordering and `finished == run.json` |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| Pretty/JSON result | `measured.path`, `appRoundTrip` | IOProc stamps -> Correlator -> Stats | Yes (non-simulated bench run.json: 27.0000001 frames, 100/100) | FLOWING |
| `reported` block | HAL device/stream latency, safety, buffer | `DeviceCatalog` HAL property reads | Yes (`devices` shows real values; bench: reported 57 vs measured 27) | FLOWING |
| `runs list` | BUFFER / PATH / TOTAL | run.json | Yes | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full suite | `just test` | 238 tests in 21 suites passed, `ci-sim: OK` | PASS |
| Simulated round trip + label/tags | `run round-trip --simulate --label "my test" --tag a --tag b --store <tmp>` | 20/20 valid, saved, listed | PASS |
| Latency/jitter recovery | `--sim-latency 777.25 --sim-jitter 1 --hits 100` | median 777.33, p5-p95 775.2-778.4 | PASS |
| Named failures | `--sim-permission denied`, `--sim-input-zeros`, `--sim-muted`, `--sim-fault ...` | named codes, exits 65 / 75 | PASS |
| Misses and xrun kept, rejected by name | `--sim-miss 8,15 --sim-xrun 25` | 27/30 valid, reasons counted | PASS |
| Clock gate negative control | `selftest clock --simulate --sim-stamp-bias 5` | exit 3 | PASS |
| Real devices | `soundping devices` | 11 devices incl. Scarlett, Loopback, built-ins | PASS |
| CR-01 reproduction | `run round-trip --simulate --level nan` | probe plays "nan dBFS", fails inputClipping (ceiling bypassed) | CONFIRMED defect |
| CR-01 / WR-02 reproduction | `run round-trip --simulate --level inf --json` | `internal: EncodingError ... inf`, run lost; temp store still holds calibrations.json and clock-selftest.json | CONFIRMED defect |

### Probe Execution

SKIPPED: no `scripts/*/tests/probe-*.sh` and no probes declared in any PLAN. `scripts/ci-sim.sh` ran as part of `just test`.

### Requirements Coverage

All 13 IDs claimed across the 10 plans are the 13 IDs ROADMAP and REQUIREMENTS.md map to Phase 1. No orphans. REL-04 is correctly Phase 7 with only its licence part pulled into Phase 1.

| Requirement | Source Plans | Description | Status | Evidence |
|-------------|--------------|-------------|--------|----------|
| ENG-01 | 01-05 | List devices, select by stable ID | SATISFIED | `devices`, resolver, ResolverTests |
| ENG-02 | 01-02, 01-03, 01-07 | Run recipe from CLI, see each hit live | SATISFIED | pretty + ndjson live lines; hardware runs |
| ENG-03 | 01-08 | Preflight names mic permission (owning app), silent, clipping | SATISFIED in sim; real TCC check open | sim denial names Ghostty; bench: inputClipping / nothingHeardAtCeiling named on real mic path |
| ENG-04 | 01-02, 01-10 | Randomised spacing, warm-ups discarded | SATISFIED | SchedulerTests, run.json phases |
| ENG-05 | 01-01, 01-02, 01-04, 01-08 | `--simulate`, used by CI | SATISFIED | ci.yml runs ci-sim |
| ENG-06 | 01-02, 01-06, 01-10 | Segments covered and corrections with source stated | SATISFIED | `segments`, `corrections: []`, "Corrections: none (raw measurement)" |
| ENG-07 | 01-07 | Abort on device disappear / rate / buffer change | SATISFIED in sim; real device check open | AbortTests, exit 75 reproduced |
| RES-01 | 01-02, 01-03, 01-04 | valid/N, median, p5-p95, p95, max, histogram, timeline, outliers kept | SATISFIED | all rendered; rejected hits stay in `hits[]` |
| RES-02 | 01-05, 01-06 | Reported next to measured | SATISFIED | "macOS reports ..." beside path, buffer and total |
| CAL-01 | 01-04, 01-07, 01-09 | Click round trip, samples and ms, repeatable within 1-2 samples on loopback | SATISFIED on loopback | raw bench JSON, 0 to 1 frame; mic path unproven |
| CAL-02 | 01-06 | Stored per device pair, rate, buffer; labelled round trip; never mic delay | SATISFIED | CalibrationStore |
| CAL-03 | 01-06, 01-09 | Host-clock self-test within ~2 samples; "unverified clock" until it passes | SATISFIED | hardware pass; negative control exits 3 |
| RUN-01 | 01-02, 01-10 | Saved with metadata, label, tags | SATISFIED | run.json, collision-safe folders, 48-char slug cap |

Bookkeeping drift: `.planning/REQUIREMENTS.md` still shows ENG-01, ENG-02, ENG-04, ENG-07, RES-01, CAL-01, CAL-03 and RUN-01 as unchecked / Pending (ENG-03/05/06, RES-02, CAL-02 are ticked). `ROADMAP.md` still shows Phase 1 unchecked and "In Progress" with 10/10 plans. Update at phase close.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (all of Sources, Tests, scripts, README, CI) | - | TBD / FIXME / XXX / TODO / HACK / PLACEHOLDER | none | No debt markers found |
| `Sources/SoundPingKit/Store/RunStore.swift:113` | - | `--store /private/...` fails after the audio ran (deferred-items.md) | Warning | Known, logged, avoidable |
| `Package.swift` | 11-12, 19 | `swift-log` linked but never imported (review IN-05) | Info | Dead dependency |
| `run` and `selftest clock` with `--simulate` | - | Write to the user's real default store (runs, calibrations.json, clock-selftest.json) | Warning | Simulated records mix with real ones (distinct UID `soundping-sim-duplex`, `setup.simulated: true`, so lookups stay correct, but `runs list` and the self-test store gain clutter). See side effect below |

### Code review weighed against the goal (01-REVIEW.md, all dispositions open)

"Trustworthy number" is the goal. Findings by effect on it:

- **Could produce or hide a wrong number, only in edge cases**
  - **WR-03** (stamp log pairs input/output by index; 2^21-entry ring wraps on very long runs): a skipped stamp shifts every later pair by a callback and moves the stored app-round-trip and calibration by a whole buffer; a 10 000-hit run could write a false FAIL into `clock-selftest.json`. The default 100-hit run at 128 frames is nowhere near the wrap and the bench shows Δio exactly `2 x buffer + safeties` at three buffers, so the normal path is sound.
  - **WR-01** (overload rejection racy, single-frame check): a glitch can slip through as a valid hit on the HAL `'over'` path. The stamp-discontinuity backstop (what AbortTests actually exercises) still catches sample-time jumps.
  - **WR-04** (two-device runs record only the input buffer): reported figures and calibration key can be wrong when the two buffers differ. No two-device hardware run has produced a number yet.
  - **WR-02** (side files written before run.json): confirmed by me with `--level inf`. A failed write leaves `calibrations.json` and `clock-selftest.json` entries pointing at a runId that does not exist. Phase 2 reads `clock-selftest.json` as its gate evidence, so this one deserves a fix before Phase 2 relies on that file.
  - **WR-05** (a buffer that settles only at IO start aborts the run) is a false abort, not a false number.
- **Hearing safety (not the number, but a plan promise: "never above the listener's ceiling")**
  - **CR-01**: reproduced here. `--level nan` skips the ceiling clamp and the probe plays "nan dBFS"; on real hardware a NaN float sample reaches the driver. `--level inf` loses the finished run.
  - **CR-02**: not reproducible without headphones; by code reading `--in-channel auto` probes at the -18 dBFS "unknown" ceiling instead of -30 for known headphones. WR-08 (Bluetooth outputs treated as unknown, -18) is the same class.
  - 01-SECURITY.md reports `threats_open: 0` and treats T-01-28 (the level ceiling) as closed; CR-01 and CR-02 show it is bypassable. The security verdict should be revisited.
- **Not goal-relevant:** WR-06, WR-07, WR-09, WR-10, WR-11 and IN-01 to IN-09.

Judgement: none of this turns a PASS into a FAIL for Phase 1, because the saved loopback number is repeatable, consistent with the buffer arithmetic and clock-checked. I recommend fixing CR-01, CR-02, WR-02, WR-03 (and WR-08) before Phase 2 builds on this engine, since Phase 2 reuses the stamp log, the self-test store and the level ramp unchanged.

### Human Verification Required

See frontmatter `human_verification` (7 items). In short: real mic denial naming Ghostty, Terminal.app prompt, unplug / sample-rate change mid-run, listening on speakers and headphones, Ableton open at buffer 256, the pretty TTY look, and a decision on the unproven real-mic path (SC1 / CAL-01 "loopback or mic").

### Gaps Summary

No FAILED truths and no blocking gaps. Four things keep this from a clean `passed`:

1. Open human-only checks, two of which (real TCC denial, real device change) are the real-hardware halves of SC4. They are the single `behavior_unverified` truth.
2. The mic half of SC1 has never produced a number: the MacBook speakers to built-in mic path is refused by preflight (confidence ~0.35 vs 0.5 minimum). Refusing with a named cause is the trustworthy behaviour, but no acoustic number exists yet, and the bench says so itself ("No speakers -> mic number exists yet").
3. Review findings CR-01, CR-02, WR-02, WR-03 are open and touch safety or the evidence Phase 2 will rely on.
4. Bookkeeping: REQUIREMENTS.md checkboxes and the ROADMAP phase status are stale.

Flo's headline decision (no single headline; hardware path, SoundPing buffer and total side by side, `runs list` BUFFER / PATH / TOTAL) is implemented as described and observed in the pretty output and `runs list`.

### Verifier side effect to be aware of

While probing `selftest clock --simulate` I did not pass `--store`, so it wrote into Flo's real store at `~/Library/Application Support/SoundPing/`: one run folder `runs/20261112T150636Z-round-trip`, one `soundping-sim-duplex` entry in `calibrations.json`, and one in `clock-selftest.json`. My attempt to remove them was blocked by the permission system, so they are still there. They are harmless to real lookups (simulated UID) and safe to delete by hand. All other probes used throwaway `SOUNDPING_HOME` or `--store` folders.

---

_Verified: 2026-11-12T15:30:00Z_
_Verifier: Claude (gsd-verifier)_
