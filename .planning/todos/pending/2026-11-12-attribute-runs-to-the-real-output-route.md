---
created: 2026-11-12T14:47:25.335Z
title: Attribute runs to the real output route
area: general
severity: major
files:
  - Sources/SoundPingKit/Store/Setups.swift
  - Sources/SoundPingKit/Engine/SetupResolver.swift
  - Sources/soundping/Commands/RunOptions.swift
---

## Problem

For Phase 3 (Output Chain & Run Comparison). The same device and channel can carry very different physical routes, and SoundPing can't see what's downstream:

- Scarlett Out 3/4 → wired speakers one day, → wireless monitor another day (or something else re-plugged into 3/4)
- Loopback (virtual device) → Scarlett vs → Bluetooth headphones/speaker

SoundPing sees only device + channel (Out 1/2 vs 3/4 *are* distinguishable; Bluetooth headphones connected directly are their own device). It cannot see what is plugged into a jack, or where Loopback forwards audio: CoreAudio doesn't expose it, and Loopback's own config files are undocumented. So two very different routes can be saved under the same setup, and their latencies get mixed up. Flo needs to be able to tell SoundPing (or an agent) "I'm doing X" and have results attributed to that route.

## Solution

Three layers, simplest first (from a discussion with Flo, 2026-11-12):

1. **Route note on the named setup.** A flag like `--route "Out 3/4 → JBL wireless"`, stored on the setup and saved with every run. Builds on Phase 1's named setups (01-05) and run labels/tags (01-10).
2. **Confirmation at run start.** "Out 3/4 → JBL wireless — still right?", with `--yes` for agents once they've confirmed with the user.
3. **History-based mismatch warning.** If a run's latency doesn't match the setup's history (e.g. usual ~22 ms, now 180 ms), warn "doesn't look like your usual JBL wireless — did the route change?" This catches a stale route note.

Refinement (2026-11-12, from the Phase 1 code review, WR-08): let the route note also say what is listening (headphones vs speakers/monitors), so the level ramp picks the matching loudness ceiling (headphones -30 dBFS, speakers a speaker cap) instead of guessing "unknown" (-18 dBFS) for any audio-interface output. macOS can't tell what's plugged into an interface jack, and interfaces often mirror Out 1/2 to their headphone jack. Today only the built-in headphone jack and (after WR-08) Bluetooth outputs get the headphone cap; `--max-level` is the manual override. Code: `Sources/SoundPingKit/Preflight/LevelRamp.swift` (`classify`, `ceilingDbfs`).

Related: don't try to detect Loopback's routing. Measure what it adds with Phase 3's A/B method (through-device minus bypass). The Phase 1 bench already showed the virtual "Loopback: Ableton Out" device reports 0 but measures 768 frames (16 ms).
