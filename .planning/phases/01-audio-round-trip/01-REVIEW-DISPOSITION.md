---
phase: 01
review: 01-REVIEW.md
titles: json
findings:
  - id: CR-05
    severity: critical
    disposition: open
    title: "Two unrelated virtual devices count as \"a loop SoundPing can see\": a monitored virtual output can ramp to -6 dBFS into headphones"
  - id: WR-15
    severity: warning
    disposition: open
    title: "The channel probe keeps the first channel's ceiling but re-baselines route watching on every reopen, so a route change between channels is never reported"
  - id: WR-16
    severity: warning
    disposition: open
    title: "A `--level` above the ceiling that hears nothing reports the requested level, not the clamped level that was played"
  - id: IN-22
    severity: info
    disposition: open
    title: "The loudness invariant cannot catch a drift in the transport strings the classifier keys on"
  - id: CR-04
    severity: critical
    disposition: fixed
    title: "A virtual output is now a \"loopback\" whatever the input: a mic run through a monitored virtual device can ramp to -6 dBFS (regression from the CR-03 fix)"
  - id: WR-13
    severity: warning
    disposition: fixed
    title: "`--listener` lifts the headphone and Bluetooth ceiling without `--max-level`, though the help says `--max-level` is the only way"
  - id: WR-14
    severity: warning
    disposition: fixed
    title: "A headphone plug-in during a run is not watched: a built-in output locked at the speaker level keeps playing into the ears"
  - id: IN-15
    severity: info
    disposition: fixed
    title: "The stack documentation still lists swift-log as a shipped, always-used dependency (IN-05 residual)"
  - id: IN-16
    severity: info
    disposition: fixed
    title: "A wrapped ring's \"forgotten\" range is bounded by retained lower bounds, and the oldest slot can be read torn"
  - id: IN-17
    severity: info
    disposition: fixed
    title: "A backward sample-time jump moves the published label backwards and poisons everything below the old position"
  - id: IN-18
    severity: info
    disposition: fixed
    title: "The overload interval and the settle are sized from the buffer requested at open, not the one the device settled on"
  - id: IN-19
    severity: info
    disposition: fixed
    title: "The channel probe treats a glitched probe as heard and climbs 12 dB on it (IN-01 residual)"
  - id: IN-20
    severity: info
    disposition: fixed
    title: "Reopen is fixed for HAL open → stop → open only: the simulator's stream stays finished, and open → open leaks running IOProcs (IN-09 residual)"
  - id: IN-21
    severity: info
    disposition: fixed
    title: "Already-defended-elsewhere: the label loads in `RTState.faults` are discarded and add no ordering"
  - id: CR-03
    severity: critical
    disposition: fixed
    title: "A virtual or \"Loop\" input overrides the headphone ceiling: the ramp can reach -6 dBFS in headphones (external: codex)"
  - id: WR-01
    severity: warning
    disposition: fixed
    title: "Overload rejection is racy and checks a single frame, not the lost interval"
  - id: WR-03
    severity: warning
    disposition: fixed
    title: "The stamp log pairs input and output by array index, and the 2^21-entry ring wraps on long runs"
  - id: IN-02
    severity: warning
    disposition: fixed
    title: "The same-device window has no pre-roll, so a near-zero path is rejected as `outsideWindow`"
  - id: WR-12
    severity: warning
    disposition: fixed
    title: "A built-in output without a readable `hdpn` data source gets the speaker ceiling: the classifier fails open"
  - id: IN-01
    severity: info
    disposition: fixed
    title: "A probe rejected for an overload or a discontinuity counts as \"not heard\", so the ramp climbs 6 dB"
  - id: IN-03
    severity: info
    disposition: fixed
    title: "`requireFloat32` checks only the first stream of a scope"
  - id: IN-04
    severity: info
    disposition: fixed
    title: "Doc comments contradict the code"
  - id: IN-05
    severity: info
    disposition: fixed
    title: "Dead code and an unused dependency"
  - id: IN-06
    severity: info
    disposition: fixed
    title: "Duplicated logic"
  - id: IN-07
    severity: info
    disposition: fixed
    title: "Several stdout writes bypass `Output`'s guarded write"
  - id: IN-08
    severity: info
    disposition: fixed
    title: "The IOProc stamps `mHostTime` and `mSampleTime` without checking `mFlags`"
  - id: IN-09
    severity: info
    disposition: fixed
    title: "`HALBackend` is not reusable after `stop()`, though ChannelProbe reopens it"
  - id: IN-10
    severity: info
    disposition: fixed
    title: "`--in-channel auto` ignores device changes while it probes (external: codex)"
  - id: IN-11
    severity: info
    disposition: fixed
    title: "`RunParameters.minValidFraction` is never validated (external: codex)"
  - id: IN-12
    severity: info
    disposition: fixed
    title: "Simulation flags are not range-checked and can trap the process (external: codex)"
  - id: IN-13
    severity: info
    disposition: fixed
    title: "A side-file write failure after run.json turns a saved run into a reported failure (WR-02 residual)"
  - id: IN-14
    severity: info
    disposition: fixed
    title: "`recipes` output still disagrees with what a run uses"
  - id: CR-01
    severity: critical
    disposition: fixed
    title: "`--level` accepts NaN and ±inf. NaN bypasses the ceiling and plays NaN samples; inf throws away a finished run"
  - id: CR-02
    severity: critical
    disposition: fixed
    title: "`--in-channel auto` ignores the headphone ceiling and probes up to -18 dBFS into known headphones"
  - id: WR-02
    severity: warning
    disposition: fixed
    title: "Calibration and self-test records are written before run.json, so a failed write orphans them"
  - id: WR-04
    severity: warning
    disposition: fixed
    title: "Two-device runs record only the input device's buffer size"
  - id: WR-05
    severity: warning
    disposition: fixed
    title: "A buffer size that settles at start always aborts the run, though the comment says the run adopts it"
  - id: WR-06
    severity: warning
    disposition: fixed
    title: "Interactive save of the probed channel can write it into a setup with a different input device"
  - id: WR-07
    severity: warning
    disposition: fixed
    title: "The `.aborted` event covers only some failures, so the stream contract is inconsistent"
  - id: WR-08
    severity: warning
    disposition: fixed
    title: "Bluetooth (and USB headset) outputs get the -18 dBFS \"unknown\" ceiling"
  - id: WR-09
    severity: warning
    disposition: fixed
    title: "`soundping recipes` advertises a start level the engine never uses"
  - id: WR-10
    severity: warning
    disposition: fixed
    title: "CI job has no `timeout-minutes`"
  - id: WR-11
    severity: warning
    disposition: fixed
    title: "`bench.sh` aborts on any run with zero valid hits"
open: 4
total: 43
recorded: 2026-11-12T20:43:25.911Z
---

# Phase 01: Code Review Disposition

| Finding | Severity | Disposition | Source |
|---------|----------|-------------|--------|
| CR-05 | critical | open | - |
| WR-15 | warning | open | - |
| WR-16 | warning | open | - |
| IN-22 | info | open | - |
| CR-04 | critical | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-13 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-14 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-15 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-16 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-17 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-18 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-19 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-20 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-21 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| CR-03 | critical | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-01 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-03 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-02 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-12 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-01 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-03 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-04 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-05 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-06 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-07 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-08 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-09 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-10 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-11 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-12 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-13 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| IN-14 | info | fixed | 01-REVIEW-FIX.md (not in the current review) |
| CR-01 | critical | fixed | 01-REVIEW-FIX.md (not in the current review) |
| CR-02 | critical | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-02 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-04 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-05 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-06 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-07 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-08 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-09 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-10 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |
| WR-11 | warning | fixed | 01-REVIEW-FIX.md (not in the current review) |

Dispositions: `open` (recorded, not yet triaged), `fixed`, `skipped`, `deferred`.
Set `deferred` by hand and put the reason in the Source cell; both are preserved. A `|` in the reason is kept as prose and escaped on the next run.
Re-running the gate keeps every row it can. A row the current review no longer reports is kept and its Source cell flagged, so a finding does not leave this record silently. ONE exception: when a finding id is REUSED by a different finding, the earlier decision cannot keep a row — the id is taken — and it is dropped. A RECORDED decision (anything but `open`) is named on the console when that happens; a row still at `open` is replaced silently, because `open` records no decision to lose.
