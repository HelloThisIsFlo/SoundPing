# SoundPing

## What This Is

SoundPing is a personal tool for Flo that measures where the latency in his music setup comes from. It runs named tests, each a "recipe" made of a trigger (a click, a MIDI note sent by the tool, a real key press) and a listener (the MacBook mic or a loopback into the audio interface). Each test fires many hits and shows a speed-test-style result: median, jitter and a graph.

## Core Value

Trustworthy, comparable latency numbers for each segment of the chain (MIDI transport, Ableton, output processing, speakers/headphones), so a laggy feel can be traced to its cause instead of guessed at.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Measurement engine: fires N hits, detects onsets in the recording, reports median, jitter (spread) and a distribution graph
- [ ] Calibration recipe: tool plays a click and records it back (mic or loopback) on the same audio clock, giving the input-path delay that later mic tests subtract
- [ ] Tool-sent MIDI recipe: tool sends a MIDI note → Ableton → sound → mic, with the MIDI send time aligned to the audio clock and the mic delay subtracted
- [ ] Real key press recipe: Flo presses a key on a real controller; the mic hears the key's mechanical click and then the sound; the gap between the two onsets is the latency
- [ ] Transport comparison: the same test over Bluetooth MIDI, network MIDI and cable MIDI, side by side
- [ ] Output chain recipe: loopback (headphone amp / output → interface input) to measure what the surround headphone processing and the wireless speaker module add
- [ ] Labelled, saved runs (e.g. "BT MIDI, buffer 128") so setups can be compared over time
- [ ] CLI to run any recipe and print the stats (first interface)
- [ ] Speed-test-style local web UI: pick a test, hit Go, watch hits land live, see a result card with median, jitter and graph

### Out of Scope

- Injected Mac keypress as a trigger (the original README idea) — deferred: tool-sent MIDI measures the same segment with cleaner timing; revisit only if a keyboard-to-MIDI path itself needs measuring
- Sharing or publishing results / multi-user use — personal tool for Flo's own setup
- Automatically fixing or tuning the setup (buffer sizes, routing) — SoundPing measures; Flo decides

## Context

- **What set it off:** a laggy feel when playing, eventually traced to SoundSource (a macOS audio routing app). Finding it was painful with no measurement tool. That problem is solved; SoundPing exists so the next one is quick to pin down.
- **The chain being measured:** trigger → MIDI transport (Bluetooth / network / cable) → Ableton (buffer, plugins, project chain) → audio interface out → output processing (surround headphone processing, SoundSource-style apps) → speakers / headphones (including a dedicated non-Bluetooth wireless speaker module) → ear.
- **Each recipe covers a different segment** of that chain; comparing recipes isolates segments.
- **Gear available:** audio interface with a spare input (loopback possible), a Bluetooth MIDI controller, a cable MIDI controller (USB/DIN), a network MIDI (rtpMIDI) setup, and plenty more.
- **Timing insight from questioning:**
  - Click → record back keeps start and arrival on one audio clock, so it's sample-accurate. It's the foundation and the calibration.
  - Tool-sent MIDI needs the MIDI send time (system clock) aligned to the audio input clock, e.g. via CoreAudio host timestamps.
  - Every mic measurement includes the mic's own input delay (converter + input buffer). The calibration measures it so it can be subtracted.
  - With headphones, the sound must reach the mic (ear cup held to the MacBook) or go through loopback.
- **Platform:** macOS (MacBook built-in mic), Ableton Live.

## Constraints

- **Platform**: macOS only — it's Flo's machine, and CoreAudio/CoreMIDI timing is the point
- **Accuracy**: timing must be traceable to the audio sample clock; a number that hides an uncorrected offset (e.g. mic delay) is worse than no number
- **Evolvability**: start as a quick CLI but built around a shared engine, so new recipes and the web UI plug in without rewrites
- **Best-practice stats**: many hits per run, median + jitter, not a single sample

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Tests are "recipes" (trigger + listener) on one shared engine | "All of it, in different tests": new tests should be new recipes, not new tools | — Pending |
| Phase order: engine + click calibration first, then tool-sent MIDI | Same-clock click is sample-accurate and measures the mic delay that every later mic test must subtract; debugging clock alignment before anything is proven is painful | — Pending |
| CLI first, speed-test web UI later in milestone 1 | Quick to get numbers; web UI is wanted within the first milestone but not as phase 1 | — Pending |
| Report median + jitter + graph over N hits | Best practice; jitter matters as much as the average for playing feel | — Pending |
| Defer injected Mac keypress trigger | Tool-sent MIDI measures the same segment with cleaner timing | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-11-11 after initialization*
