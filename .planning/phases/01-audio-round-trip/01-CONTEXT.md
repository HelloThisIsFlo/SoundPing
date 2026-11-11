# Phase 1: Audio Round Trip - Context

**Gathered:** 2026-11-11
**Status:** Ready for planning

<domain>
## 🎯 Phase Boundary

The `soundping` CLI + `SoundPingKit` engine deliver the first trustworthy number: a click (chirp) round trip, recorded back via loopback or mic, with full stats, saved as a run and stored as a round-trip calibration.

- **Requirements:** ENG-01..07, RES-01, RES-02, CAL-01, CAL-02, CAL-03, RUN-01
- **Exit gates before Phase 2:**
  - Host-clock self-test passes on real hardware
  - Licence files land before any ported code

</domain>

<decisions>
## ✅ Implementation Decisions

### 🤖 Who the CLI is for
- **D-01:** The CLI is a temporary/secondary interface. Its main consumers are an **AI agent that Flo tells to run tests**, and Flo himself until the native app (Phase 6) exists. Optimise for machine-readable, deterministic use first; human-pretty output second.

### 🖥️ CLI flow & output
- **D-02:** Command shape is **recipe-generic**: `soundping run <recipe>` plus utility verbs:
  - `devices` (with `--json`)
  - `recipes` (with `--json`)
  - `runs list/show`
  - `selftest`
  - Phases 2–5 add recipe ids, not commands. Shared run flags live in one `@OptionGroup`. No `calibrate` alias.
- **D-03:** Output modes:
  - **Default:** pretty TTY.
    - One line per hit as it lands; rejected hits dimmed, with their reason
    - Summary block, Unicode-bar histogram, sparkline timeline
    - Honours `NO_COLOR`
  - **`--json`:** one final object. Contents:
    - summary stats
    - segments covered
    - corrections with their source
    - reported vs measured
    - `runId`
    - **absolute run path**
  - **`--ndjson`:** the live `RunEvent` stream.
  - **Streams:** data → stdout, progress/logs → stderr. Never print progress to stdout in JSON modes.
  - **Failures:** preflight and abort failures come out as structured JSON errors (e.g. `{"type":"error","code":"micPermissionDenied","terminalApp":"Ghostty"}`), with **distinct exit codes per class**: usage, preflight, device-change abort, gate fail.
  - One Codable schema (`RunEvent`/`RunResult`, with `schemaVersion`) feeds all three renderers. `--json` output = `run.json` = what the app reads later.
- **D-04:** Default **N = 100 hits, 5 warm-ups**, declared in the recipe's defaults. `--hits` / `--warmup` override. Fixed N, no adaptive stop. The numbers are to be sanity-checked on Flo's hardware.
- **D-05:** Host-clock self-test (CAL-03) runs **both ways**, from one shared engine function:
  - **Automatic:** computed inside every same-device round-trip run (Δ samples reported in the result); each such run refreshes the stored status.
  - **Explicit gate:** `soundping selftest clock` exits nonzero on fail.
  - The pass/fail status is persisted, keyed like calibrations (device, rate, buffer), for Phase 2's "unverified clock" label.
  - `selftest midi` arrives in Phase 2.
- **D-06:** Store root is `~/Library/Application Support/SoundPing/` (the app and the CLI resolve the same path).
  - **Override:** `SOUNDPING_HOME` env var / `--store` flag, for CI and tests.
  - **`soundping paths`** (or equivalent) prints the root, so agents don't fight the space in the path.
  - **Layout:** per ARCHITECTURE.md (`runs/<timestamp>-<slug>/run.json` + calibrations).

### 🎛️ Device & channel picking — PROVISIONAL
- **D-07:** ⚠️ **Provisional: Flo expects to tweak this after hands-on use.** Keep the setups schema small and versioned, and build nothing else on top of it yet.
- **D-08:** **One resolver** for audio + MIDI, shared later with the app picker:
  - **Selector:** an exact UID, else a unique case-insensitive name match. Exact name beats substring.
  - **Errors:** ambiguous or missing selectors fail with the candidate list (UIDs included).
  - **`devices` row numbers** are display-only and never accepted as selectors.
  - MIDI endpoints are listed with `kMIDIPropertyUniqueID` now, though MIDI recipes start in Phase 2.
- **D-09:** **Named setups** live in a config file:
  - **Fields:** output, input, in-channel, out-channels, midi-out.
  - **Usage:** `--setup <name>`; flags override individual fields.
  - **Identity:** each binding stores UID + display name.
  - **UID miss** (e.g. a USB device moved to another port changes its UID): fall back to the exact stored name, with a loud warning that the calibration may not apply.
  - **Calibration key:** stays UID-based.
- **D-10:** **No implicit system defaults, ever.** `default` is accepted only as an explicit keyword, resolved and pinned to a UID at arm time, then printed.
- **D-11:** **Channels are explicit state** (1-based, shown with the HAL channel names), part of the calibration key.
  - **`--in-channel auto`:** a one-shot helper. It probes, prints the channel it found with its confidence (margin rule; an error if two channels tie), and offers to save it into the setup. Never a silent per-run guess.
  - **Output:** defaults to the device's preferred stereo pair; `--out-channels` overrides.

### 🔊 Test sound & level (Claude's discretion, research-backed; Flo deferred to the research)
- **D-12:** **Stimulus:** a short band-limited log **chirp** (~20–50 ms, Tukey-faded), detected by matched filter:
  - normalised correlation peak (0–1) as confidence
  - peak-to-sidelobe and "first peak above k·max" checks, against reflections
  - parabolic sub-sample interpolation
  - **Band per listener:** ~300 Hz–8 kHz for speaker/mic, wider for loopback. Tune on the bench.
- **D-13:** **One correlator, generic over the template** (the template is data).
  - A windowed short click ships as an **A/B control template**.
  - Run the chirp-vs-click comparison on the bench early, since the Apple Silicon built-in mic DSP behaviour is unverified.
  - Only OboeTester's confidence formula may be borrowed (Apache-2.0, keep its header + NOTICE); not its coded-burst stimulus.
- **D-14:** **Level policy: auto-ramp, then lock.**
  - **Ramp:** probe hits start at ≈ −48 dBFS and step +6 dB until confidence/SNR clears the target with input peak ≤ −6 dBFS.
  - **Ceilings:** a hard ceiling per listener, lower when the output data source reports headphones.
  - **Lock:** the level is locked for the whole run; warm-ups double as probes.
  - **At the ceiling:** "nothing heard at ceiling" becomes a named preflight cause (check cable / permission / volume / interface gain).
  - This implements ENG-03's silent/clipping preflight.
- **D-15:** The chirp is designed for **reuse in Phase 2**, as the bundled DAW sample and reference click (an up/down chirp pair stays separable). Don't make choices that block this.

### 📜 Licence: PolyForm Shield 1.0.0 (source-available, not OSI open source)
- **D-16:** SoundPing is licensed under **PolyForm Shield 1.0.0** — **Reversibility:** costly — the licence can be relaxed later (to MPL, GPL or others) only while Flo holds relicensing rights to every contribution, hence the CLA; versions already released stay under Shield.
  - **Intent:** free for anyone to use, professionals included; nobody may offer a competing product, paid or free.
    - Shield bans *competing products*, not profit in general. A consultant charging to measure latency with SoundPing is fine.
  - **Rejected:**
    - GPL-3.0, because it allows selling.
    - MIT, Apache-2.0 and MPL-2.0, because they allow closed commercial products.
    - PolyForm Noncommercial, because it would ban paid musicians.
    - FSL, because its automatic 2-year opening isn't wanted.
- **D-17:** **Exit-gate licence work** (lands before any ported code):
  - **`LICENSE`:** the full verbatim PolyForm Shield 1.0.0 text, from `PolyForm-Shield-1.0.0.md` in GitHub `polyformproject/polyform-licenses` (the polyformproject.org URL may 404).
    - Add `Required Notice: Copyright 2026 Flo Kempenich`.
    - **No** `Licensor Line of Business:` line (deliberately left out; verify against the actual text whether the field exists).
  - **`CLA.md`:**
    - **Grant:** contributors give Flo a perpetual, irrevocable licence to their contributions, including the right to sublicense and relicense under any terms, commercial ones included.
    - **Copyright:** contributors keep it.
    - **Not a DCO:** a DCO isn't enough.
    - **Basis:** an established template (Apache ICLA-style or Contributor Agreements / Harmony), not written from scratch.
  - **`CONTRIBUTING.md`:** contributions require signing the CLA; a bot asks on the first PR.
  - **README licence section,** exact text approved by Flo:
    > **Licence**
    >
    > Free for anyone to use, including professionally. You may modify and share it, but not offer a competing product. Source-available under [PolyForm Shield 1.0.0](LICENSE).
    >
    > The licence is deliberately strict for now and may be relaxed to a more open one later.
  - **Doc wording:** change "open source" → "source-available (PolyForm Shield 1.0.0)" wherever it describes the licence, and record the decision + rationale in PROJECT.md Key Decisions. Files:
    - `.planning/PROJECT.md`: the constraint and the Key Decisions table
    - `.planning/REQUIREMENTS.md`: REL-04's "open-source licence", and the telemetry row's "Open-source tool"
    - `.planning/ROADMAP.md`: the Phase 1 exit gate wording, and the Phase 7 title "Open-Source Release"
    - `.planning/research/STACK.md`: the licence-check table header "OK for any SoundPing licence?" covers Shield; all shipped deps are MIT/Apache-2.0 and pass, GPL tools stay dev-only
    - `CLAUDE.md` / `AGENTS.md`: the same (CLAUDE.md is partly generated from STACK.md, so fix the source too)
  - **Oboe LatencyAnalyzer port** (if it happens): keep its Apache-2.0 header + NOTICE attribution on the ported files; this is compatible with Shield for the rest of the repo.
- **D-18:** **CLA bot is Flo's manual step,** not an agent task: install CLA Assistant on the GitHub repo **before the repo goes public**. It doesn't block the Phase 1 exit gate.

### 🧠 Claude's Discretion
- Stimulus design, detector checks and level-ramp parameters (D-12..D-15). Flo deferred to the research; tune on the bench.
- Exact pretty-output layout, exit-code numbering, the JSON field names (as long as they stay Codable and versioned), and the config file format/location for setups (TOML or JSON under `~/.config/soundping/` or the store root).

</decisions>

<canonical_refs>
## 📚 Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project scope & requirements
- `.planning/PROJECT.md`: core value, constraints, key decisions (accuracy constraint: no hidden offsets)
- `.planning/REQUIREMENTS.md`: ENG-01..07, RES-01/02, CAL-01..03, RUN-01, REL-04 (licence part)
- `.planning/ROADMAP.md` §Phase 1: goal, success criteria, exit gates, research flags

### Research (PROJECT.md wins where they disagree; ignore web-UI content)
- `.planning/research/SUMMARY.md`: reconciled overview and gaps
- `.planning/research/STACK.md`: Swift/HAL/CoreMIDI/vDSP stack, mic permission (app vs CLI), licence-check table
- `.planning/research/ARCHITECTURE.md`: components, RunEvent contract, stored data shape (Application Support, `run.json`, calibrations), setup profiles, calibration key
- `.planning/research/PITFALLS.md`: clock domains (#3), silent TCC zeros (#7), default-device switching (#11), stats honesty (#9), phase-locked hits (#8)
- `.planning/research/FEATURES.md`: table stakes (preflight, transparent corrections)

### External
- GitHub `polyformproject/polyform-licenses` → `PolyForm-Shield-1.0.0.md`: verbatim LICENSE source
- google/oboe `apps/OboeTester/app/src/main/cpp/analyzer/LatencyAnalyzer.h` (Apache-2.0): confidence-formula reference, only if ported

</canonical_refs>

<code_context>
## 🧩 Existing Code Insights

### Reusable Assets
- None: greenfield repo (only `README.md`, `AGENTS.md`, `CLAUDE.md`). Phase 1 creates the SwiftPM package (`SoundPingKit` + `soundping`).

### Established Patterns
- Flo's conventions: Just for orchestration (`just test`, `just cli`), with complex logic in scripts that Just calls.
- Engine → UI contract: `run(_ recipe:) -> AsyncThrowingStream<RunEvent, Error>`. The CLI is a pure consumer and never touches CoreAudio.

### Integration Points
- Saved runs and calibrations under the store root are the contract with later phases (Phase 2 reads the clock-check status and calibrations; Phase 6 app reads runs).

</code_context>

<specifics>
## 💬 Specific Ideas

- Flo will mostly drive tests by telling an agent to run the CLI, so the `--json` summary must be enough on its own (absolute run path included); an agent shouldn't need to scrape pretty text or make a second call.
- Device selection is expected to change after real use; don't over-invest in it.

</specifics>

<deferred>
## 🅿️ Deferred Ideas

- Adaptive stopping (run until the median CI is tight): revisit if the key-press / BT MIDI recipes prove highly variable (Phase 4–5).
- Multi-sine "precision loopback" mode: only if 1–2 sample accuracy ever proves too coarse.
- `calibrate` alias: not now; reconsider for strangers' docs in Phase 7.

</deferred>

---

*Phase: 01-audio-round-trip*
*Context gathered: 2026-11-11*
