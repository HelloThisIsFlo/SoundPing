# Roadmap: SoundPing

## Overview

SoundPing grows one recipe at a time on a single shared engine. Every phase ends with something you can run.

- **Phase 1** proves the engine on one audio clock (click round trip from the CLI), then proves the host clock that every MIDI recipe depends on.
- **Phases 2-5** each add the recipe for one segment of the chain: the DAW (tool-sent MIDI), the output chain, the whole chain from a real key, and the MIDI transports.
- **Phase 6** wraps every recipe in the speed-test-style native app. **Phase 7** ships it to strangers.

Two gates are built into the order:

- **End of Phase 1:** the host-clock self-test (CAL-03) must pass before any MIDI work starts.
- **Start of Phase 5:** the iPad echo spike (TRAN-01) decides whether the echo test ships or real key presses carry the transport comparison.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Audio Round Trip** - Engine and CLI deliver the first trustworthy number: a saved, stats-backed audio round trip, closed by the host-clock gate and the licence choice
- [ ] **Phase 2: Tool-Sent MIDI** - MIDI note to DAW to sound, with mic and speaker delays cancelled by a reference click
- [ ] **Phase 3: Output Chain & Run Comparison** - What each output device or processing step adds, and whether a change between two runs is real
- [ ] **Phase 4: Real Key Press & Chain Breakdown** - The latency a player actually feels from a real key, split into the chain parts measured so far
- [ ] **Phase 5: Transport Comparison** - Bluetooth vs network vs cable MIDI side by side, opening with the iPad echo spike
- [ ] **Phase 6: Native App** - Speed-test-style macOS app over every recipe, installed locally for daily use
- [ ] **Phase 7: Open-Source Release** - Signed, notarised DMG, Homebrew cask, Sparkle updates and per-recipe docs for strangers

## Phase Details

### Phase 1: Audio Round Trip
**Goal**: Users can measure their audio round trip from the `soundping` CLI and get a trustworthy, saved number, on the engine every later recipe reuses
**Mode:** mvp
**Depends on**: Nothing (first phase)
**Requirements**: ENG-01, ENG-02, ENG-03, ENG-04, ENG-05, ENG-06, ENG-07, RES-01, RES-02, CAL-01, CAL-02, CAL-03, RUN-01
**Success Criteria** (what must be TRUE):
  1. User lists audio and MIDI devices by stable ID, picks an output and an input (loopback or mic), and runs the click round trip from the CLI, watching each hit land live; hits fire with randomised spacing and declared warm-up hits are discarded
  2. The result shows valid hits out of N, median, jitter (p5-p95), p95, max, a histogram and a per-hit timeline in samples and ms, with macOS/driver-reported latency next to the measured one and the segments covered and corrections applied (with their source) stated; repeat loopback runs agree within 1-2 samples
  3. Every run is saved with its metadata (devices, sample rate, buffer, recipe, date), a label and tags, and the round trip is stored as a calibration for that device pair, sample rate and buffer, labelled "round trip" and never applied as "mic delay"
  4. Broken setups stop with a named cause: missing mic permission (naming the terminal app that owns it), silent or clipping input, or a device that disappears or changes sample rate or buffer mid-run; `--simulate` runs the recipe with no gear, recovers the injected latency and jitter, and runs in CI
  5. Exit gates before Phase 2: the host-clock self-test passes (sample-count and host-clock paths agree within ~2 samples), and the repo carries its chosen open-source licence before any ported code lands (the licence part of REL-04)
**Plans**: 2/10 plans executed

Plans:
**Wave 1**
- [x] 01-01-PLAN.md — Licensed, buildable repo: PolyForm Shield LICENSE first, SwiftPM scaffold + CI, CLA (Flo picks fill-ins), CONTRIBUTING, README

**Wave 2** *(blocked on Wave 1 completion)*
- [x] 01-02-PLAN.md — Walking skeleton: `soundping run round-trip --simulate --json` → run.json, seeded spacing + warm-ups, CI on every push

**Wave 3** *(blocked on Wave 2 completion)*
- [ ] 01-04-PLAN.md — Detector and stats rigor: named rejections, first-peak/PSR/confidence, chirp bands + click + down-sweeps, numpy-matched stats
- [ ] 01-10-PLAN.md — Run store (wave 3, split from 01-02): labels/tags, collision-safe run folders, run lock, `runs list/show`, contract tests

**Wave 4** *(blocked on Wave 3 completion)*
- [ ] 01-03-PLAN.md — Live output for agents and humans: `--ndjson`, pretty TTY (hits, histogram, sparkline), error envelope + exit codes
- [ ] 01-05-PLAN.md — Devices and selection: `devices`/`recipes`/`paths`, one resolver + named setups, no implicit defaults, reported-latency math

**Wave 5** *(blocked on Wave 4 completion)*
- [ ] 01-06-PLAN.md — The trustworthy number (simulated): host-clock self-test + `selftest clock`, measured vs reported, two-device host path, calibrations

**Wave 6** *(blocked on Wave 5 completion)*
- [ ] 01-07-PLAN.md — Real hardware round trip: raw HAL IOProc (`@_noLocks`), per-process buffer, abort on device change

**Wave 7** *(blocked on Wave 6 completion)*
- [ ] 01-08-PLAN.md — Preflight: mic permission naming the owning app, level ramp + lock, silent/clipping/ceiling/muted causes, `--in-channel auto`

**Wave 8** *(blocked on Wave 7 completion)*
- [ ] 01-09-PLAN.md — Bench exit gate: repeatability + clock self-test on the Scarlett, Flo picks the headline value, licence wording sweep

**Notes**: Research flag: HAL timestamp edge, safety-offset arithmetic and real-time safety need on-hardware spikes. Drift checks for two-device recipes arrive in Phase 3 (CAL-04).

### Phase 2: Tool-Sent MIDI
**Goal**: Users can measure how long their DAW takes to turn a MIDI note into sound, in any app that plays a note, with mic and speaker delays cancelled rather than guessed
**Mode:** mvp
**Depends on**: Phase 1 (host-clock self-test passed)
**Requirements**: MIDI-01, MIDI-02, MIDI-03, MIDI-04, RES-03, RES-05
**Success Criteria** (what must be TRUE):
  1. User sends MIDI notes from the tool into Ableton (or any app that plays a MIDI note) and gets note-to-sound latency through a mic or loopback listener; a plain mic run is labelled "includes mic input delay"
  2. Mic runs use the reference click by default (click and note in one recording), and swapping speakers or moving the mic leaves the result stable within its stated uncertainty
  3. Every MIDI result shows the tool's own dispatch-jitter floor from a self-test, and is marked "unverified clock" on any setup where the host-clock self-test has not passed
  4. Corrected numbers show raw, correction and corrected values and flag a stale or missing calibration instead of using it silently; each result carries a "great / fine / noticeable" verdict band citing the source of its thresholds
  5. A newcomer follows the Ableton guide or the "any app that plays a MIDI note" guide, with the bundled click sample, and gets a valid run
**Plans**: TBD
**Notes**: Defines the formula for the DAW part of the chain breakdown (RES-04 lands in Phase 4). Research flag: CoreMIDI future-timestamp behaviour per destination (virtual port, IAC, DAW) and onset detection for arbitrary instrument sounds.

### Phase 3: Output Chain & Run Comparison
**Goal**: Users can find out what each output device or processing step adds (the SoundSource-style problem that started SoundPing), and tell whether a change between two runs made a real difference
**Mode:** mvp
**Depends on**: Phase 2
**Requirements**: OUT-01, OUT-02, CAL-04, RUN-02, RUN-03, RUN-04
**Success Criteria** (what must be TRUE):
  1. User measures what an output device or processing step adds with an A/B loopback (path through the device minus bypass) and gets the difference with its combined uncertainty
  2. Output-chain results show reported vs measured latency for that device; runs spanning two audio devices check clock drift during the run and are flagged when it exceeds the stated threshold
  3. User lists past runs and compares any two, with overlaid histograms and a "real difference vs within noise" verdict from a bootstrap confidence interval
  4. Raw audio snippets are kept per hit so a saved run can be re-analysed, within a configurable storage cap (default 250 MB, oldest deleted first), and runs export as JSON and CSV
**Plans**: TBD
**Notes**: Defines the formula for the output-chain part of the chain breakdown. Standard method (RTINGS-style differential loop); reuses the host-clock path proven in Phase 1.

### Phase 4: Real Key Press & Chain Breakdown
**Goal**: Users can press a real controller key, get the latency they actually feel, and see it split into the chain parts measured so far
**Mode:** mvp
**Depends on**: Phase 3 (breakdown needs the DAW and output-chain parts)
**Requirements**: KEY-01, KEY-02, KEY-03, RES-04
**Success Criteria** (what must be TRUE):
  1. User presses keys on a real controller and gets the latency from each key's mechanical click to the sound, from one mic recording, with no calibration needed
  2. Ambiguous click/sound pairs are rejected and counted, and the result states its few-ms uncertainty (key action, velocity) and shows mic placement guidance
  3. User enters key-to-mic and speaker-to-mic distances and gets raw and air-time-corrected latency (~2.9 ms per metre); preflight checks that the key click is audible at the mic before the run starts
  4. User sees a latency breakdown of the chain (MIDI transport / DAW / output chain) and can drill into each part to see the recipe it came from and its uncertainty; parts with no measurement are left out, never estimated
**Plans**: TBD
**Notes**: Defines the formula for the transport part from key-press runs. Research flag: double-onset detection (quiet mechanical click before a loud sound), pairing rules, built-in mic noise reduction eating transients.

### Phase 5: Transport Comparison
**Goal**: Users can compare Bluetooth, network and cable MIDI side by side; the phase opens with the TRAN-01 echo spike, which decides whether the iPad echo test ships or real key presses carry the comparison
**Mode:** mvp
**Depends on**: Phase 4 (key-press runs are the fallback and the "real controller" side of the comparison)
**Requirements**: TRAN-01, TRAN-04, TRAN-02, TRAN-03
**Success Criteria** (what must be TRUE):
  1. Spike first, before any echo-test build work: a cable echo through the iPad companion measures the companion's own jitter floor, and the go/no-go call (is that floor small next to the transport differences?) is recorded with its numbers
  2. If the spike passes: user runs the echo test (Mac sends MIDI to the iPad companion page in a Web MIDI browser app, which bounces it straight back) over Bluetooth MIDI (e.g. via MIDImittr), network MIDI and cable MIDI, and gets transport round trip and jitter with the companion floor reported as the jitter of the cable echo
  3. If the spike fails: TRAN-04 and TRAN-02 move to Out of Scope with the measured floor as the reason, and key-press runs on each transport carry the comparison
  4. User sees BT vs network vs cable side by side; echo runs are labelled "transport round trip via iPad" and key-press runs "real controller", never mixed into one number
**Plans**: TBD
**UI hint**: yes
**Notes**: TRAN-04 and TRAN-02 depend on the spike outcome. Research flag: BLE MIDI and rtpMIDI behaviour. The UI hint covers the small iPad companion page.

### Phase 6: Native App
**Goal**: Users can run any recipe from a speed-test-style macOS app (pick a test, hit Go, watch hits land), and Flo uses it day to day before any public release
**Mode:** mvp
**Depends on**: Phase 5 (every CLI recipe exists)
**Requirements**: APP-01, APP-02, APP-03, APP-04, APP-05
**Success Criteria** (what must be TRUE):
  1. User opens the app, picks a recipe and devices, hits Go, watches hits land live, and gets a result card with median, jitter, verdict and graph
  2. User browses and compares saved runs (the same runs the CLI saves) and sees the segment waterfall in the app
  3. The app asks for mic permission with a clear reason, and after a denial explains how to fix it
  4. Flo builds and installs the app locally with one command, mic permission survives rebuilds (stable signing), and the app is his daily tool before any public release
**Plans**: TBD
**UI hint**: yes

### Phase 7: Open-Source Release
**Goal**: Strangers can install SoundPing without security workarounds, keep it updated, and set up every recipe from the docs
**Mode:** mvp
**Depends on**: Phase 6
**Requirements**: REL-01, REL-02, REL-03, REL-04
**Success Criteria** (what must be TRUE):
  1. Pushing a tag makes GitHub Actions build, sign, notarise and staple a DMG and publish it on GitHub Releases, and it opens on a clean Mac without security warnings
  2. `brew install --cask` from the SoundPing tap installs the app and links the `soundping` CLI
  3. The first public release checks for and installs updates via Sparkle
  4. The repo has the licence chosen in Phase 1, NOTICE attributions, and a README with per-recipe setup guides and each recipe's accuracy as measured in Phases 1-5
**Plans**: TBD
**Notes**: Research flag: Xcode version on GitHub-hosted runners, notarisation and cask audit details.

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Audio Round Trip | 2/10 | In Progress | - |
| 2. Tool-Sent MIDI | 0/TBD | Not started | - |
| 3. Output Chain & Run Comparison | 0/TBD | Not started | - |
| 4. Real Key Press & Chain Breakdown | 0/TBD | Not started | - |
| 5. Transport Comparison | 0/TBD | Not started | - |
| 6. Native App | 0/TBD | Not started | - |
| 7. Open-Source Release | 0/TBD | Not started | - |
