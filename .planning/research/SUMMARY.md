# Project Research Summary

**Project:** SoundPing
**Domain:** Open-source macOS audio/MIDI latency measurement for musicians (CoreAudio + CoreMIDI, CLI first, native SwiftUI speed-test app)
**Researched:** 2026-11-11
**Confidence:** MEDIUM (stack and structure are solid; CoreAudio/CoreMIDI timestamp semantics must be proven on the bench)

> PROJECT.md wins over the research files where they disagree.
> - UI is a **native SwiftUI app**. The web UI, Hummingbird, SSE and Svelte in ARCHITECTURE.md and FEATURES.md are superseded. STACK.md already reflects this.
> - Click calibration is a **round trip** (output + air + input). It is never subtracted as "mic delay". Recipes cancel unknowns inside one recording.
> - Transport comparison needs **real key presses or an external echo device**. Tool-sent MIDI on the same Mac never crosses BT, network or cable.
> - **Open source, for anyone.** Flo's setup is the first test bench, not the target.

## Executive Summary

SoundPing is a measurement instrument. It fires many timed stimuli (a click, a CoreMIDI note, or a real key press), records the result on a known clock, and reports median, jitter and a distribution for each segment of the playing chain. No existing tool does this on macOS. Existing tools each cover one segment: audio loopback (RTL Utility, MathAudio), MIDI loopback (Linux only), or acoustic round trip (mobile only). Nothing measures MIDI to DAW to sound, compares transports, or splits the chain. People do it by hand in Audacity.

The recommended approach is a single Swift repo. A SwiftPM package holds the engine library (`SoundPingKit`) and the CLI. An Xcode app target (SwiftUI + Swift Charts) consumes the same library. Audio uses raw CoreAudio HAL IOProcs, one per device, with no AVAudioEngine and no aggregate devices. MIDI uses raw CoreMIDI with our own send timestamps. Everything reconciles on the mach host clock. The engine exposes one `AsyncThrowingStream<RunEvent>`. The CLI and the app are thin consumers and never touch CoreAudio. Recipes are `Trigger x Listener x Detector x Corrections`, so new tests are new recipe definitions, not new tools. A simulation backend (fake audio/MIDI with injected latency and jitter) makes the engine testable without gear and in CI.

The main risks are measurement validity, not engineering.
- **Round trip is not mic delay.** Design recipes so unknowns cancel (reference click and note in the same recording; both onsets of a key press in one recording).
- **Driver-reported latency lies** exactly where SoundPing is needed (built-in mic DSP, SoundSource-style routers, wireless modules). Show reported vs measured and never subtract reported values silently.
- **Clock-domain mistakes** (mach ticks are not ns on Apple Silicon; per-device crystal drift; wrong timestamp edge) produce plausible garbage.
- **Tool-sent MIDI measures the tool's own jitter** unless the send is scheduled and a self-test floor is published.
- **macOS fails silently** (TCC denial returns zero buffers, not an error).

Mitigate with an explicit clock model proven on one device before MIDI is built, honest recipe labelling ("which segments does this recipe cover?"), randomised hit spacing, outliers kept in the stats, and preflight checks that name the cause of a failure.

## Key Findings

### Recommended Stack

Swift 6 end to end, with no FFI. The `swift build` / `swift test` / `swift run soundping` loop works with only the Command Line Tools. The app target needs Xcode for Info.plist, entitlements, signing and export. Details in `.planning/research/STACK.md`.

**Core technologies:**
- **Swift 6.4 / Xcode 27.2** (26.6 works for dev; `swift-tools-version: 6.2`, macOS 15+): engine, CLI, app. Strict concurrency polices the real-time boundary.
- **CoreAudio HAL IOProc, one per device**: gives `mSampleTime` and `mHostTime` for every buffer. Not AVAudioEngine, not aggregate devices.
- **Raw CoreMIDI** (`MIDISendEventList`, `MIDIInputPortCreateWithProtocol`): the only way to choose the send timestamp. Do not use swift-midi, whose `send(event:)` stamps "now" internally.
- **mach host ticks as the common clock**, with a per-device sample-to-host fit (local interpolation, not one global fit).
- **Accelerate/vDSP, hand-rolled detectors**: matched filter for tool-played sounds, envelope onset for unknown sounds. Avoid aubio/Essentia (GPL/AGPL).
- **swift-argument-parser 1.8.2, swift-log, `Synchronization.Atomic`**: CLI, logging, lock-free IOProc handoff.
- **SwiftUI + Observation + Swift Charts**: the app. Engine emits `RunEvent`s only; decimate waveforms before charting.
- **Not sandboxed.** Hardened runtime plus `com.apple.security.device.audio-input`, Developer ID signed and notarised. The CLI ships inside the app bundle.
- **Release:** GitHub Actions builds, signs, notarises and staples a DMG per tag (App Store Connect API key for `notarytool`). A Homebrew cask in our own tap installs the app and links the CLI.
- **Dev only:** just, Swift Testing, BlackHole (GPL, never bundled), uv + numpy for offline cross-checks.

### Expected Features

Details in `.planning/research/FEATURES.md` (ignore its web-UI items; read them as the native app).

**Must have (table stakes):**
- Device listing and selection by UID (nothing hard-wired to Flo's gear)
- Loopback round-trip calibration, reported in samples and ms, repeatable within 1-2 samples
- N hits per run with median, jitter, valid count (e.g. 48/50), histogram and per-hit timeline
- Randomised hit spacing
- Preflight checks (mic permission, level, clipping, sample rate, "nothing heard")
- Transparent corrections: raw, minus calibration, corrected, with staleness flags
- Automatic run metadata; labelled saved runs, list, compare two; JSON and CSV export
- Per-recipe setup guides, DAW guide, bundled sharp-attack click sample, safe default level, stated accuracy per recipe
- Easy install for strangers (signed and notarised)

**Should have (differentiators, and the reason SoundPing exists):**
- Tool-sent MIDI to any DAW to sound, with reference click so unknowns cancel
- Real key press two-onset gap (self-cancelling mic path)
- Output-chain differential loops (path through device minus bypass, the RTINGS method)
- Transport comparison (BT / network / cable) built on key presses or an external echo
- Speed-test-style native app: Go button, hits landing live, result card
- Reported vs measured side by side (cheap, and nothing else offers it)

**Defer (post-milestone-1, v1.x/v2+):**
- Segment waterfall, verdict bands with cited sources, drift flag, shareable result card, Ableton DEC hint
- User-written recipe files, guided buffer sweep, DAW-output process tap, other OSes, optional hardware listener
- Never: hosted leaderboard, auto-tuning, mean-only result, VST/AU edition, telemetry, always-on monitor

### Architecture Approach

Front-ends depend on the engine, the engine depends on hardware adapters, and nothing points back up except the `RunEvent` stream. Detectors, corrections and stats are pure functions over samples and a timeline, so they carry most of the testable logic. Two measurement domains stay explicit: the **sample domain** (same device, same recording, sample-accurate; click calibration and key press) and the **host domain** (crosses clocks; tool-sent MIDI, two-device output chain). Every stimulus is scheduled ahead, so the send time is a fact and not a racy `now()`. Detection uses a window `[fire, fire + max]` and misses are explicit. Every result carries an audit trail of corrections (`measured | halReported | userEntered`), and a missing or stale calibration either refuses or labels the number "uncorrected". Runs are stored as one folder per run (`run.json` plus per-hit WAV snippets, schema-versioned, device UIDs not names). Raw audio is kept by default so detection can be re-run; raw export is opt-in.

**Major components:**
1. **AudioIO / MIDIIO** — HAL IOProc per device (RT-safe: preallocated buffer, atomic index, no locks); CoreMIDI timed send and timestamped receive
2. **Clock / Timeline** — mach timebase conversion, per-device sample-to-host mapping, drift and gap checks
3. **Triggers / Listeners / Detectors** — click, MIDI note, human; mic vs loopback; correlation, onset, double-onset
4. **Corrections + Calibration store** — audit-trailed corrections keyed by `(device UID, channel, rate, buffer)`
5. **Stats** — median, IQR/p5-p95 jitter, p95/p99, max, histogram, misses; outliers kept, detection failures counted
6. **RunCoordinator + Recipe registry** — actor, one run at a time, warm-up, randomised spacing, emits `RunEvent`s, persists runs
7. **Simulation backend** — fake IO with injected latency/jitter/drift for gear-free tests and `--simulate`
8. **CLI and SwiftUI app** — both pure consumers of the event stream

### Critical Pitfalls

Full list of 13 in `.planning/research/PITFALLS.md`.

1. **Round trip treated as mic delay** — Label calibration RTL, keyed to the device pair, rate and buffer. Use cancelling recipes: reference click through the same output beside the MIDI note; both onsets of a key press in one recording. Verify by swapping speakers: the result must stay stable.
2. **Trusting driver-reported latency** — Log all four terms per direction (device, stream, safety offset, buffer). Show reported vs measured. Treat HAL figures as a prior, never a subtraction.
3. **Mixed clock domains** — Convert via `mach_timebase_info` (125/3 on Apple Silicon). Use local sample-to-host interpolation. Unit-test both timebases. Gate the MIDI work on a self-test: one device's round trip by sample count must match the host-time path within a sample or two.
4. **Tool jitter reported as system jitter, and transport never traversed** — Schedule MIDI ahead (about 2-10 ms) and publish a dispatch-jitter floor with every MIDI result. Every recipe declares which segments it covers, shown with the result. Transport comparison uses key presses or an external echo.
5. **Biased onset detection, silent macOS failures, and hidden-jitter stats** — Correlate against the known waveform for tool sounds; use a documented reference sound for DAW tests. Reject and count ambiguous pairs. Preflight must catch all-zero buffers (TCC) and name the responsible app. Randomise spacing, discard declared warm-ups, minimum N about 30 (default 100), keep outliers in.

## Implications for Roadmap

The research agrees on the core order: prove the engine on the sample domain, prove the host clock, then add MIDI. The 8 phases below reconcile the build order in ARCHITECTURE.md with PROJECT.md's decisions (native app last in milestone 1, open-source release as its own phase). PITFALLS.md's phase numbers assume an older order; use the mapping here.

### Phase 1: Engine foundation and device layer
**Rationale:** Everything rests on correct HAL capture, the timestamp log and the event contract. Getting these wrong poisons all later numbers.
**Delivers:** SwiftPM package (`SoundPingKit` + `soundping` CLI), `devices` and `record` commands, HAL IOProc capture with timestamp log, host clock module, simulation backend, `RunEvent`/`Recipe`/`RunCoordinator` skeleton, stats module, preflight checks, run-store skeleton, licence chosen.
**Addresses:** device listing and selection by UID, preflight, run metadata, safe level.
**Avoids:** clock-domain bugs (#3), silent TCC zeros (#7), shared device state (#11: never change rate or buffer, abort on change), hard-coded rate, xruns, GPL deps.

### Phase 2: Click calibration (round trip) and the first trustworthy number
**Rationale:** Same-clock loopback is sample-accurate, proves the engine, and is the RTL Utility parity test. It also forces the "never subtract as mic delay" semantics into the design.
**Delivers:** correlation detector, randomised scheduler with warm-up, median/jitter/valid-N, histogram and timeline in the CLI, saved runs with raw audio, calibration store keyed to the device pair, reported-vs-measured display, host-time self-test (sample-count vs host-path round trip).
**Addresses:** loopback round trip, N hits plus stats, randomised spacing, transparent corrections, export.
**Avoids:** #1 (RTL labelling), #2 (reported vs measured), #8 (phase-locked hits), #9 (stats).

### Phase 3: Tool-sent MIDI recipe
**Rationale:** The headline differentiator, and the riskiest step (MIDI host time mapped onto the audio timeline). It only starts once Phase 2's host-time gate passes.
**Delivers:** MIDIIO with scheduled `MIDISendEventList`, onset detector for unknown DAW sounds, reference-click differential variant (note and click in one recording), loopback listener variant, MIDI dispatch self-test with a published jitter floor, DAW setup guide plus bundled click sample, recipe segment declaration.
**Addresses:** tool-sent MIDI to DAW to sound.
**Avoids:** #4 (tool jitter), #6 (onset bias; two-volume test), #13 (DAW dependence; document a second DAW).

### Phase 4: Real key press recipe
**Rationale:** Needs no calibration (both onsets in one recording) and no cross-clock math. It is also the only way to measure BT / network / cable transports honestly. It could run in parallel with Phase 3.
**Delivers:** double-onset detector and pairing with plausibility window, "press now" pacing, rejection counting, distance logging with optional air-time correction, optional controller MIDI-in arrival stamps.
**Addresses:** real key press gap.
**Avoids:** #6 (mispairing, clipping), #10 (air time and key mechanics).

### Phase 5: Labelled runs, compare, and transport comparison
**Rationale:** Transport comparison is a UI and query layer over saved key-press runs, so it comes after Phase 4. Compare needs trustworthy metadata, which the earlier phases already store.
**Delivers:** labels and structured tags, list, compare two runs with bootstrap CI ("no meaningful difference" badge), overlaid histograms, BT/network/cable comparison on key-press runs, warm-up and Wi-Fi state logging, external-echo design if feasible.
**Addresses:** labelled saved runs, transport comparison.
**Avoids:** #5 (a recipe labelled with a transport must traverse it), #9 (CI on comparisons), #12 (BLE/rtpMIDI specifics).

### Phase 6: Output-chain differential recipe
**Rationale:** Solves the problem that started SoundPing (SoundSource-style processing). It reuses the two-device host path proven in Phase 2 and the compare machinery from Phase 5.
**Delivers:** A/B loopback pair (through-device minus bypass) with combined uncertainty, two-device host reconciliation, reported-vs-measured for the output chain.
**Addresses:** output chain recipe, differential A/B.
**Avoids:** #2 and #11 (BT HFP profile switch when a BT headset mic is opened).

### Phase 7: Native speed-test app
**Rationale:** Per PROJECT.md it comes after the CLI recipes. The `RunEvent` stream has existed since Phase 1, so this is a pure consumer, and it can show every recipe and the compare view.
**Delivers:** Xcode app target on the local package, recipe picker, Go button, live hit landing, result card (median, jitter, graph), in-app mic permission flow (`NSMicrophoneUsageDescription`, `AVAudioApplication`), optional BT pairing window, bundled CLI copy.
**Uses:** SwiftUI, Observation, Swift Charts, folder-synchronized Xcode groups.
**Avoids:** UI stalls from pushing every buffer, stale permission (stable Debug signing identity).

### Phase 8: Open-source release and distribution
**Rationale:** "Usable by strangers" is a constraint of the project, not polish.
**Delivers:** CI release workflow (archive, `exportArchive` developer-id, DMG, notarise, staple, spctl), Homebrew tap cask, README and per-recipe and per-DAW guides, stated accuracy per recipe, contributor path with no Apple account, licence and NOTICE attribution, `just release-local` fallback.
**Avoids:** `codesign --deep`, sandbox, GPL bundling, unsigned cask.

### Phase Ordering Rationale

- **Dependencies:** engine, then sample domain, then host domain, then MIDI. Key press has no calibration dependency. Compare needs saved runs. Transport comparison needs key-press runs. The app needs the event stream and the recipes.
- **Grouping:** detectors, corrections and stats are built once in Phases 1-2. Later phases are mostly recipe definitions plus one new detector each.
- **Pitfall avoidance:** the riskiest assumption (clock alignment) is gated before MIDI. Statistical honesty and the audit trail are built into the first recipe so no later recipe can bypass them.
- **Roadmap decision to confirm:** the app comes at Phase 7 per PROJECT.md. A thin app spike after Phase 2 would give early feedback on the `RunEvent` contract at low cost. Consider it, but do not move the full app up.
- **Quick-mode conflict:** a low-N quick mode must still show spread and valid count.

### Research Flags

Phases likely needing deeper research (`/gsd-plan-phase --research-phase <N>`):
- **Phase 1:** HAL timestamp semantics, safety-offset arithmetic, Swift real-time safety (consider a tiny C target). On-hardware spikes.
- **Phase 2:** the host-time self-test design, and whether the HAL-reported-minus-measured residual is meaningful on Flo's interface vs the built-in device.
- **Phase 3:** CoreMIDI future-timestamp behaviour per destination (virtual port vs IAC vs DAW), Ableton's handling of timestamps, onset detection for arbitrary instrument sounds.
- **Phase 4:** double-onset detection (quiet mechanical click before a loud sound), pairing rules, built-in mic noise reduction eating transients.
- **Phase 5:** BLE/rtpMIDI behaviour, and whether an external echo design is worth building.
- **Phase 8:** GitHub runner Xcode version, notarisation and cask audit details.

Phases with standard patterns (skip research-phase):
- **Phase 6:** reuses proven machinery; the method is established (RTINGS).
- **Phase 7:** standard SwiftUI/Charts over an `@Observable` model.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM-HIGH | Versions and licences verified on GitHub, xcodereleases and the local toolchain. CoreAudio stamp semantics and signing details are MEDIUM. |
| Features | MEDIUM | Competitor features are well sourced. "Nothing on macOS does this" is LOW-MEDIUM (absence of evidence). |
| Architecture | MEDIUM | Structure is standard and sound. Timestamp semantics rest on Apple mailing-list consensus; HAL latency arithmetic is disputed. Web-UI parts are superseded. |
| Pitfalls | MEDIUM | Clock, stats and onset mechanics are HIGH. Apple Silicon built-in mic DSP and TCC behaviour are LOW (forum reports only). |

**Overall confidence:** MEDIUM. The approach is sound. The unproven part is whether host-time alignment and CoreMIDI scheduling reach sub-millisecond trust, and only bench work answers that.

### Gaps to Address

- **HAL input/output timestamp edge and safety offset:** sources disagree. Treat HAL figures as a prior and prove with the Phase 2 self-test on real hardware.
- **Does CoreMIDI honour future timestamps for the destination in use** (virtual port, IAC, Ableton)? Test in Phase 3, and log the immediate-send variant once.
- **Built-in mic DSP on Apple Silicon** (reported ~30 ms unreported delay, transient suppression): only a bench test settles it. Label built-in-mic runs and recommend an interface plus external mic for serious runs.
- **External echo device for transport comparison:** unspecified. Decide in Phase 5 whether to ship key press only, or design an echo.
- **Licence:** not chosen yet. Must be settled in Phase 1 (before any ported code such as OboeTester's Apache-2.0 LatencyAnalyzer needs NOTICE attribution).
- **Accuracy numbers per recipe** (loopback about +-1 sample, mic about 0.5-1 ms, key press a few ms) are estimates until measured; do not print them as guarantees before Phase 2-4 data exists.
- **FEATURES.md and ARCHITECTURE.md still contain web-UI content.** Planners must read those as the native app and ignore Hummingbird, SSE and the SPA.
- **Xcode 27.x availability on GitHub-hosted runners** must be verified when writing the release workflow.

## Sources

### Primary (HIGH confidence)
- GitHub releases and licence APIs, xcodereleases.com, local toolchain (2026-11-11): versions and licences (swift-argument-parser, swift-log, BlackHole GPL-3.0, aubio GPL-3, Essentia AGPL-3, Sparkle, XcodeGen)
- `swift-midi-io` source: confirms `send(event:)` stamps "now" internally
- Apple Audio MIDI Setup docs: aggregate device behaviour
- Engineering fundamentals: mach timebase (125/3 on Apple Silicon), crystal drift, buffer-phase aliasing

### Secondary (MEDIUM confidence)
- Apple docs: MIDISendEventList, MIDITimeStamp, microphone entitlement; coreaudio-api list archives (HAL timestamps, safety offset, MIDI timestamps)
- NIME 2016 and 2019 papers (action-sound latency; BLE MIDI and rtpMIDI measurements); Jack et al. 2018 (jitter perception)
- Ableton manual and Driver Error Compensation FAQ; RTINGS latency method; RTL Utility, MathAudio, Superpowered, OboeTester, jack_delay documentation
- Homebrew Cask Cookbook; signing and notarisation in GitHub Actions guides
- Swift Charts and WWDC24 vectorized plots

### Tertiary (LOW confidence, validate on the bench)
- Apple dev forum and JUCE forum reports on built-in mic processing and M1 internal latency
- "2000 buffers of nothing" (silent TCC zeros); CME vendor article on Bluetooth MIDI
- KVR and Gearspace threads (no MIDI-to-DAW tool exists); Apple forum thread on AVAudioEngine tap timestamps

---
*Research completed: 2026-11-11*
*Ready for roadmap: yes*
