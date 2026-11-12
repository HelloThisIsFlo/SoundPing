---
phase: 01-audio-round-trip
review: 01-REVIEW.md
updated: 2026-11-12
---

# Phase 01 — Code Review Disposition

> One row per REVIEW.md finding. Default `open` until triaged (fix / accept / defer).

| ID | Severity | Finding | Disposition | Note |
|----|----------|---------|-------------|------|
| CR-01 | critical | `--level` accepts NaN and ±inf. NaN bypasses the ceiling and plays NaN samples; inf throws away a finished run | open | |
| CR-02 | critical | `--in-channel auto` ignores the headphone ceiling and probes up to -18 dBFS into known headphones | open | |
| WR-01 | warning | Overload rejection is racy and checks a single frame, not the lost interval | open | |
| WR-02 | warning | Calibration and self-test records are written before run.json, so a failed write orphans them | open | |
| WR-03 | warning | The stamp log pairs input and output by array index, and the 2^21-entry ring wraps on long runs | open | |
| WR-04 | warning | Two-device runs record only the input device's buffer size | open | |
| WR-05 | warning | A buffer size that settles at start always aborts the run, though the comment says the run adopts it | open | |
| WR-06 | warning | Interactive save of the probed channel can write it into a setup with a different input device | open | |
| WR-07 | warning | The `.aborted` event covers only some failures, so the stream contract is inconsistent | open | |
| WR-08 | warning | Bluetooth (and USB headset) outputs get the -18 dBFS "unknown" ceiling | open | |
| WR-09 | warning | `soundping recipes` advertises a start level the engine never uses | open | |
| WR-10 | warning | CI job has no `timeout-minutes` | open | |
| WR-11 | warning | `bench.sh` aborts on any run with zero valid hits | open | |
| IN-01 | info | A probe rejected for an overload or a discontinuity counts as "not heard", so the ramp climbs 6 dB | open | |
| IN-02 | info | The same-device window has no pre-roll, so a near-zero path is rejected as `outsideWindow` | open | |
| IN-03 | info | `requireFloat32` checks only the first stream of a scope | open | |
| IN-04 | info | Doc comments contradict the code | open | |
| IN-05 | info | Dead code and an unused dependency | open | |
| IN-06 | info | Duplicated logic | open | |
| IN-07 | info | Several stdout writes bypass `Output`'s guarded write | open | |
| IN-08 | info | The IOProc stamps `mHostTime` and `mSampleTime` without checking `mFlags` | open | |
| IN-09 | info | `HALBackend` is not reusable after `stop()`, though ChannelProbe reopens it | open | |
