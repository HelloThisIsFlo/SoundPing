# Requirements: SoundPing

**Defined:** 2026-11-11
**Core Value:** Trustworthy, comparable latency numbers for each segment of the chain (MIDI transport, DAW, output processing, speakers/headphones), so a laggy feel can be traced to its cause instead of guessed at.

## v1 Requirements

Requirements for milestone 1. Each maps to roadmap phases.

### Engine & Devices

- [ ] **ENG-01**: User can list audio and MIDI devices and select them by stable ID (nothing hard-wired to one setup)
- [ ] **ENG-02**: User can run any recipe from the `soundping` CLI and see each hit live as it lands
- [x] **ENG-03**: Preflight blocks a run and names the cause: missing mic permission (all-zero input; for the CLI, names the terminal app that owns the permission), silent input, clipping input
- [ ] **ENG-07**: A running test aborts with a clear reason if a device disappears or its sample rate or buffer size changes mid-run
- [ ] **ENG-04**: Hits fire with randomised spacing; declared warm-up hits are discarded
- [x] **ENG-05**: User can run any recipe with `--simulate` against fake hardware with injected latency and jitter (no gear needed; used by CI)
- [x] **ENG-06**: Every result states which chain segments its recipe covers and which corrections it applied, with each correction's source (measured, HAL-reported, or none)

### Results

- [ ] **RES-01**: Each run reports valid hits out of N, median, jitter (p5–p95 spread), p95, max, a histogram and a per-hit timeline; outliers are kept
- [x] **RES-02**: User sees reported (macOS/driver) latency next to measured latency
- [ ] **RES-03**: User sees a verdict band ("great / fine / noticeable") next to each result, citing the source of the thresholds
- [ ] **RES-04**: User sees an intuitive latency breakdown of the chain (MIDI transport / DAW / output chain) that can be drilled into: each part names the recipe it came from and its uncertainty, and parts with no measurement are not shown (no invented numbers); the formula for each part is defined in its phase
- [ ] **RES-05**: Corrected numbers show raw, correction and corrected values, and flag stale or missing calibration

### Calibration

- [ ] **CAL-01**: User can measure round-trip latency by playing a click and recording it back (loopback or mic), in samples and ms, repeatable within 1–2 samples on loopback
- [x] **CAL-02**: Calibrations are stored per device pair, sample rate and buffer size, labelled round trip, and never applied as "mic delay"
- [ ] **CAL-03**: A host-clock self-test confirms the sample-count and host-clock paths agree within ~2 samples; until it passes, MIDI results are marked "unverified clock"
- [ ] **CAL-04**: Recipes that span two audio devices check clock drift during the run and flag results when drift exceeds a stated threshold

### Tool-sent MIDI

- [ ] **MIDI-01**: User can measure tool-sent MIDI note → DAW → sound with a mic or loopback listener, in any app that plays a MIDI note; mic runs use the reference click (MIDI-02) by default, and a plain mic run is labelled "includes mic input delay"
- [ ] **MIDI-02**: A reference-click variant puts click and note in one recording so mic and speaker delays cancel
- [ ] **MIDI-03**: Every MIDI result shows the tool's own dispatch-jitter floor, measured by a self-test
- [ ] **MIDI-04**: User can follow setup guides for Ableton and for "any app that plays a MIDI note", with a bundled click sample

### Real Key Press

- [ ] **KEY-01**: User can press a real controller key and get the latency from its mechanical click to the sound, from one mic recording
- [ ] **KEY-02**: Ambiguous click/sound pairs are rejected and counted; the result states its few-ms uncertainty (key action, velocity) and shows mic placement guidance
- [ ] **KEY-03**: User enters the key→mic and speaker→mic distances; the result shows raw and air-time-corrected latency (~2.9 ms per metre), and preflight checks that the key click is audible at the mic

### Transport Comparison

- [ ] **TRAN-01**: The transport phase starts with an echo spike: a cable echo through the iPad companion measures the companion's own jitter; the echo test ships only if that floor is small next to transport differences, otherwise key press carries the transport comparison
- [ ] **TRAN-04**: If the spike passes, user can run an echo test: the Mac sends MIDI to an iPad companion page (in a Web MIDI browser app) that bounces it straight back, giving transport round trip and jitter with no audio involved
- [ ] **TRAN-02**: The echo test works over Bluetooth MIDI (e.g. via MIDImittr), network MIDI and cable MIDI, and reports the companion floor as the jitter of the cable echo
- [ ] **TRAN-03**: User can view BT vs network vs cable side by side; echo runs are labelled "transport round trip via iPad" and key-press runs "real controller", never mixed into one number

### Runs

- [ ] **RUN-01**: Every run is saved with metadata (devices, sample rate, buffer, recipe, date) plus a label and tags
- [ ] **RUN-02**: User can list past runs and compare two, with overlaid histograms and a "real difference vs within noise" verdict (bootstrap confidence interval)
- [ ] **RUN-03**: Raw audio snippets per hit are kept so runs can be re-analysed, within a configurable storage cap (default 250 MB, oldest deleted first)
- [ ] **RUN-04**: User can export runs as JSON and CSV

### Output Chain

- [ ] **OUT-01**: User can measure what an output device or processing step adds via A/B loopback (path through the device minus bypass), with combined uncertainty
- [ ] **OUT-02**: Output-chain results show reported vs measured for that device

### Native App

- [ ] **APP-01**: User can open the native macOS app, pick a recipe and devices, and hit Go
- [ ] **APP-02**: User watches hits land live and gets a result card with median, jitter, verdict and graph
- [ ] **APP-03**: User can browse and compare saved runs and see the segment waterfall in the app
- [ ] **APP-04**: The app requests mic permission with a clear reason and explains how to fix a denial
- [ ] **APP-05**: Flo can build and install the app locally (one command, stable signing so mic permission sticks) and use it day to day before any public release

### Release

- [ ] **REL-01**: User can download a signed, notarised DMG from GitHub Releases, built by GitHub Actions on each tag
- [ ] **REL-02**: User can install with `brew install --cask` from the SoundPing tap; the CLI is linked too
- [ ] **REL-03**: The app checks for and installs updates via Sparkle from the first release
- [ ] **REL-04**: The repo has a source-available licence (PolyForm Shield 1.0.0, chosen in the first phase, before any ported code lands), NOTICE attributions, and a README with per-recipe setup guides and stated accuracy per recipe

## v2 Requirements

Deferred to a future milestone. Tracked but not in the current roadmap.

- **V2-01**: Shareable result card (image export to post yourself)
- **V2-02**: Second tested DAW guide (e.g. Logic or GarageBand) — Flo's todo
- **V2-03**: iPhone/iOS listener app: phone placed next to the keys and speaker records both key-press onsets in one recording (no cross-device clock sync needed)
- **V2-04**: User-written recipe files
- **V2-05**: Guided buffer-size sweep
- **V2-06**: DAW-output capture via Core Audio process taps (isolates DAW latency from speakers and air)
- **V2-07**: Other operating systems
- **V2-08**: Ableton Driver Error Compensation hint

## Out of Scope

| Feature | Reason |
|---------|--------|
| Hosted leaderboard, accounts, online sharing | Runs locally; results stay on the user's machine (export is fine) |
| Auto-tuning the setup (buffers, routing) | SoundPing measures; the user decides |
| Mean-only or single-shot results | Hides jitter, which matters as much as the average |
| VST/AU plug-in edition | Different product; plug-ins can't measure the whole chain |
| Telemetry | Source-available tool for strangers; no data leaves the machine |
| Always-on latency monitor | Measurement is a deliberate test run |
| Injected Mac keypress trigger | Tool-sent MIDI measures the same segment with cleaner timing |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| ENG-01 | Phase 1 | Pending |
| ENG-02 | Phase 1 | Pending |
| ENG-03 | Phase 1 | Complete |
| ENG-07 | Phase 1 | Pending |
| ENG-04 | Phase 1 | Pending |
| ENG-05 | Phase 1 | Complete |
| ENG-06 | Phase 1 | Complete |
| RES-01 | Phase 1 | Pending |
| RES-02 | Phase 1 | Complete |
| RES-03 | Phase 2 | Pending |
| RES-04 | Phase 4 | Pending |
| RES-05 | Phase 2 | Pending |
| CAL-01 | Phase 1 | Pending |
| CAL-02 | Phase 1 | Complete |
| CAL-03 | Phase 1 | Pending |
| CAL-04 | Phase 3 | Pending |
| MIDI-01 | Phase 2 | Pending |
| MIDI-02 | Phase 2 | Pending |
| MIDI-03 | Phase 2 | Pending |
| MIDI-04 | Phase 2 | Pending |
| KEY-01 | Phase 4 | Pending |
| KEY-02 | Phase 4 | Pending |
| KEY-03 | Phase 4 | Pending |
| TRAN-01 | Phase 5 | Pending |
| TRAN-04 | Phase 5 | Pending |
| TRAN-02 | Phase 5 | Pending |
| TRAN-03 | Phase 5 | Pending |
| RUN-01 | Phase 1 | Pending |
| RUN-02 | Phase 3 | Pending |
| RUN-03 | Phase 3 | Pending |
| RUN-04 | Phase 3 | Pending |
| OUT-01 | Phase 3 | Pending |
| OUT-02 | Phase 3 | Pending |
| APP-01 | Phase 6 | Pending |
| APP-02 | Phase 6 | Pending |
| APP-03 | Phase 6 | Pending |
| APP-04 | Phase 6 | Pending |
| APP-05 | Phase 6 | Pending |
| REL-01 | Phase 7 | Pending |
| REL-02 | Phase 7 | Pending |
| REL-03 | Phase 7 | Pending |
| REL-04 | Phase 7 | Pending |

**Notes:**
- REL-04: the licence is chosen in Phase 1 (exit gate, before any ported code lands); NOTICE, README and per-recipe guides complete in Phase 7
- TRAN-04, TRAN-02: ship only if the TRAN-01 spike passes; otherwise they move to Out of Scope with the measured floor as the reason

**Coverage:**
- v1 requirements: 42 total
- Mapped to phases: 42
- Unmapped: 0

---
*Requirements defined: 2026-11-11*
*Last updated: 2026-11-11 after roadmap creation*
