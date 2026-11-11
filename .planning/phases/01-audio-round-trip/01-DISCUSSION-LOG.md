# Phase 1: Audio Round Trip - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-11-11
**Phase:** 01-audio-round-trip
**Areas discussed:** CLI flow & live output, Device & channel picking, Test sound & loudness, Licence
**Mode:** advisor (a research table per area)

Flo's framing: the CLI is temporary; mostly an agent will drive it, or he'll wait for the native app. Still worth deciding.

---

## CLI flow & live output (+ storage, self-test trigger)

| Option | Description | Selected |
|--------|-------------|----------|
| Recommended bundle | `run <recipe>`, pretty + `--json` + `--ndjson`, 100/5, self-test in loopback runs + `selftest clock`, Application Support | ✓ |
| Bundle + `calibrate` alias | Same, plus a `calibrate` alias | |
| Lighter | Pretty + `--json` only | |

**User's choice:** Recommended bundle.

---

## Device & channel picking

| Option | Description | Selected |
|--------|-------------|----------|
| UID/name + setups | Resolver + named setups + explicit channels with a one-shot auto-detect; no implicit defaults | ✓ |
| UID/name, no setups | Resolver + explicit channels only | |
| UID only | Copy UIDs from `devices --json` | |

**User's choice:** Recommended, provisionally.
**Notes:** "After using, I may need to tweak it."

---

## Test sound & loudness

| Option | Description | Selected |
|--------|-------------|----------|
| Chirp + auto-ramp | ~30 ms chirp, matched filter, click A/B control; ramp from −48 dBFS, capped, locked | ✓ (research) |
| Click + auto-ramp | Familiar tick, louder, may trip mic DSP | |
| Chirp + fixed levels | Fixed dBFS defaults, ramp later | |

**User's choice:** "I have zero idea about this one, so I'm just going to let the research decide."

---

## Licence

| Option | Description | Selected |
|--------|-------------|----------|
| Apache-2.0 | Research pick: matches the Oboe port, patent grant, closed forks allowed | |
| MIT | Shortest; mixed licences if Oboe is ported | |
| GPL-3.0-or-later | No closed forks | |
| MPL-2.0 | File-level copyleft | |
| PolyForm Shield 1.0.0 | Source-available; no competing products; relax later with a CLA | ✓ |

**User's choice:** PolyForm Shield 1.0.0. Flo decided it after a separate discussion with another agent.
**Notes:**
- Wants something very restrictive now, so it can be relaxed later.
- Claude flagged:
  - Shield bans competing products, not profit in general.
  - Verify the "Licensor Line of Business" field against the real text.
  - CLA/non-OSI deters some contributors.
  - Build the CLA from a template.
  - The "open source" wording is spread across more docs than listed.
- README line iterated. Flo cut a clause that only restated the licence. Final: "The licence is deliberately strict for now and may be relaxed to a more open one later."
- The CLA bot was explained. It's installed before the repo goes public, by Flo.

---

## Claude's Discretion

- Stimulus, detector and level-ramp parameters
- Pretty-output layout, exit-code numbering, JSON field names
- Setups config format and location

## Deferred Ideas

- Adaptive stopping
- Multi-sine precision mode
- `calibrate` alias
