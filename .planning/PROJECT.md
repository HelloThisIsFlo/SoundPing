# SoundPing

## What This Is

SoundPing is an open-source tool for musicians and audio tinkerers that measures where the latency in their music setup comes from. It started from Flo's own setup, which remains the first test bench. It runs named tests, each a "recipe" made of a trigger (a click, a MIDI note sent by the tool, a real key press) and a listener (the MacBook mic or a loopback into the audio interface). Each test fires many hits and shows a speed-test-style result: median, jitter and a graph.

## Core Value

Trustworthy, comparable latency numbers for each segment of the chain (MIDI transport, Ableton, output processing, speakers/headphones), so a laggy feel can be traced to its cause instead of guessed at.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Measurement engine: fires N hits, detects onsets in the recording, reports median, jitter (spread) and a distribution graph
- [ ] Calibration recipe: tool plays a click and records it back (mic or loopback) on the same audio clock, giving the round-trip latency (output + air + input) for that device pair, sample rate and buffer size. It cannot split input from output, so it is never subtracted as "mic delay"
- [ ] Tool-sent MIDI recipe: tool sends a MIDI note → Ableton → sound → mic, with the MIDI send time aligned to the audio clock; unknown terms (mic delay, speaker path) cancel by design, e.g. a reference click and the note in the same recording
- [ ] Real key press recipe: Flo presses a key on a real controller; the mic hears the key's mechanical click and then the sound; the gap between the two onsets is the latency
- [ ] Transport comparison: the same test over Bluetooth MIDI, network MIDI and cable MIDI, side by side. Built on real key presses (or an external echo device), because tool-sent MIDI on the same Mac never crosses these transports
- [ ] Output chain recipe: loopback (headphone amp / output → interface input) to measure what the surround headphone processing and the wireless speaker module add
- [ ] Labelled, saved runs (e.g. "BT MIDI, buffer 128") so setups can be compared over time
- [ ] CLI to run any recipe and print the stats (first interface)
- [ ] Speed-test-style native macOS app: pick a test, hit Go, watch hits land live, see a result card with median, jitter and graph

### Out of Scope

- Injected Mac keypress as a trigger (the original README idea) — deferred: tool-sent MIDI measures the same segment with cleaner timing; revisit only if a keyboard-to-MIDI path itself needs measuring
- Hosted service, accounts or online result sharing — SoundPing runs locally on the user's own machine; results stay local (exporting them is fine)
- Automatically fixing or tuning the setup (buffer sizes, routing) — SoundPing measures; Flo decides

## Context

- **What set it off:** a laggy feel when playing, eventually traced to SoundSource (a macOS audio routing app). Finding it was painful with no measurement tool. That problem is solved; SoundPing exists so the next one is quick to pin down.
- **The chain being measured:** trigger → MIDI transport (Bluetooth / network / cable) → Ableton (buffer, plugins, project chain) → audio interface out → output processing (surround headphone processing, SoundSource-style apps) → speakers / headphones (including a dedicated non-Bluetooth wireless speaker module) → ear.
- **Each recipe covers a different segment** of that chain; comparing recipes isolates segments.
- **Gear available:** audio interface with a spare input (loopback possible), a Bluetooth MIDI controller, a cable MIDI controller (USB/DIN), a network MIDI (rtpMIDI) setup, and plenty more.
- **Timing insight from questioning:**
  - Click → record back keeps start and arrival on one audio clock, so it's sample-accurate. It's the foundation and the calibration.
  - Tool-sent MIDI needs the MIDI send time (system clock) aligned to the audio input clock, e.g. via CoreAudio host timestamps.
  - Every mic measurement includes the mic's own input delay (converter + input buffer, plus undocumented built-in mic processing on Apple Silicon). A click round trip can't isolate it, so recipes are designed so it cancels: both onsets in one recording (key press; reference click + note).
  - Tool-sent MIDI on the same Mac never crosses Bluetooth, network or cable MIDI; comparing transports needs real key presses or an external echo device.
  - With headphones, the sound must reach the mic (ear cup held to the MacBook) or go through loopback.
- **Platform:** macOS (MacBook built-in mic), Ableton Live.
- **Audience:** open source, for anyone who wants to measure their latency. Flo's setup is the first test bench, not the only target, so nothing is hard-wired to his gear (device names, Ableton set, ports).

## Constraints

- **Platform**: macOS first — CoreAudio/CoreMIDI timing is the point; other OSes aren't ruled out, but not in milestone 1
- **Open source**: usable by strangers. Devices, MIDI ports and the DAW (Ableton is the reference, not a requirement) are configurable; installing and running it is documented; licence chosen before the first public release
- **DAW-agnostic**: tool-sent MIDI tests work with any app that turns a MIDI note into sound
- **Accuracy**: timing must be traceable to the audio sample clock; a number that hides an uncorrected offset (e.g. mic delay) is worse than no number
- **Evolvability**: start as a quick CLI but built around a shared engine that emits hits as live events, so new recipes and the native app plug in without rewrites
- **Distribution**: the native app is signed and notarised (Flo has an Apple Developer account), so strangers can install it without security workarounds
- **Best-practice stats**: many hits per run, median + jitter, not a single sample

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Tests are "recipes" (trigger + listener) on one shared engine | "All of it, in different tests": new tests should be new recipes, not new tools | — Pending |
| Phase order: engine + click calibration first, then tool-sent MIDI | Same-clock click is sample-accurate and proves the engine (round trip, not mic delay); debugging clock alignment before anything is proven is painful | — Pending |
| CLI first, speed-test native macOS app later in milestone 1 (replaces the web UI idea) | macOS-first; Swift engine plugs straight into SwiftUI + Swift Charts; an app bundle owns its mic permission (a CLI inherits the terminal's); no localhost server to secure. Costs: notarisation (developer account available), no browser access from other devices | — Pending |
| Calibration = round trip, never subtracted as "mic delay"; recipes cancel unknowns in one recording | Research: a click round trip can't split input from output; subtracting it double-counts output + air | — Pending |
| Report median + jitter + graph over N hits | Best practice; jitter matters as much as the average for playing feel | — Pending |
| Defer injected Mac keypress trigger | Tool-sent MIDI measures the same segment with cleaner timing | — Pending |
| Open source, for anyone, not just Flo | Flo's call: no reason it should only serve his setup | — Pending |

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
