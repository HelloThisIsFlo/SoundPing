# Phase 1 Bench

Measured 2026-11-12 on Flo's MacBook Pro (macOS 27.2.1, terminal app Ghostty, mic access authorized), Scarlett 16i16 4th Gen at 48 kHz, SoundPing 0.1.0, `just bench` (`scripts/bench.sh`).

BENCH GATE: PASS

## 🎯 Verdicts

| Gate | Verdict | Numbers | Limit |
|---|---|---|---|
| CAL-01 repeatability | ✅ PASS | two 100-hit runs, 100/100 valid each: headline 311.0000 vs 311.0000, path 27.0000 vs 27.0000, difference 0.0000 frames | ≤ 2.0 frames |
| CAL-03 clock self-test | ✅ PASS | `selftest clock`, n 100: median Δ −0.00003 frames, p95 \|Δ\| 0.0139 frames | median ≤ 1, p95 ≤ 2 frames |

- 🚦 **Exit gate for Phase 2 is met on the Scarlett loop.** No simulated run contributed.
- ⚠️ **Caveat:** the loop is the Scarlett's internal digital `Loop 1` channel. Jitter is exactly 0, so repeatability is easy there. A cable loop through the converters was not benched.
- 📂 **Raw JSON of every bench run:** `~/Library/Application Support/SoundPing/bench/20261112T023627Z/` (one `.json` + `.err` + `.rc` per run, `devices.json`, `gates.txt`, `verdict`).

## 🧪 Bench setup

- **Setup `scarlett-loop`:** Scarlett → Scarlett, output channels 1,2, input channel 7 (`Loop 1`), saved to `setups.json`.
- **`--in-channel auto` is ambiguous on a stereo output.** Output 1,2 feed `Loop 1` and `Loop 2` equally (both confidence 1.00), so `inChannelAmbiguous` is the normal answer. `bench.sh` falls back to `BENCH_IN_CHANNEL` (default 7).
- **Buffer 128, 105 hits per run** (5 warm-ups, then 100 measured). Level ramp locked at the first probe, −48 dBFS (loopback ceiling −6).
- **Not used:** `--store /private/tmp/...` (deferred bug in `RunStore.runsChild`, see `deferred-items.md`).

## 📊 Same-device runs: reported vs measured

Scarlett loop, buffer 128 (medians, frames at 48 kHz):

| Run | Template | Valid | Path reported / measured | App round trip reported / measured | Δio expected / measured | Jitter p5–p95 |
|---|---|---|---|---|---|---|
| repeat-1 | chirp-loopback | 100/100 | 57 / 27.00 | 341 / 311.00 | 284 / 284 | 0.00 |
| repeat-2 | chirp-loopback | 100/100 | 57 / 27.00 | 341 / 311.00 | 284 / 284 | 0.00 |
| click | click | 100/100 | 57 / 27.00 | 341 / 311.00 | 284 / 284 | 0.00 |
| virtual loopback (`Loopback: Ableton Out`) | chirp-loopback | 50/50 | 0 / 768.00 | 256 / 1024.00 | 256 / 256 | 0.00 |

Buffer sweep on the Scarlett loop (20 hits each, extra runs in the same bench folder):

| Buffer | Path measured | App round trip reported / measured | Δio expected / measured | Self-test |
|---|---|---|---|---|
| 64 | 26.00 | 213 / 182.00 | 156 / 156 | pass |
| 128 | 27.00 | 341 / 311.00 | 284 / 284 | pass |
| 256 | 27.00 | 597 / 567.00 | 540 / 540 | pass |

- 🧮 **Δio is exactly `2 × buffer + safety_in + safety_out`** (14 + 14 on the Scarlett) at 64, 128 and 256. The safety-offset dispute (P3) is settled for this device: SoundPing's reported expectation is right.
- 📏 **Path is stable, app round trip follows the buffer.** Path 26–27 frames at every buffer; `appRoundTrip` = path + 156 / 284 / 540.
- ➖ **Reported path 57 vs measured 27: a constant 30-frame gap.** The gap does not move with the buffer. The Loop channels are a digital loop inside the interface, so the DAC/ADC latencies the HAL reports (32 + 25) are not traversed in full.
- 🔢 **Path is quantised to whole frames.** Within a run every hit lands on the same frame (min = max). Across sessions the path took two values, one frame apart: 26 (02:33, two runs; and the whole verify re-run at 02:48), 27 (02:36 to 02:41, all bench runs of the first pass). The virtual loopback shows the same step (768, then 767). Within CAL-01's tolerance, but it is a one-frame step between sessions that never shows up inside a run, so a repeatability pair taken across a session boundary could differ by 1.

## 🔀 Chirp vs click (D-13)

| Template | Valid | Path median (frames) | Jitter p5–p95 | Self-test (in-run) |
|---|---|---|---|---|
| chirp-loopback | 100/100 | 27.0000001 | 0.00 | pass |
| click | 100/100 | 27.0000091 | 0.00 | pass |

- ➖ **On a clean digital loop the two stimuli agree to 0.00001 frames.** The loop cannot separate them. The A/B only matters on acoustic paths, below.

## 🔊 MacBook speakers → built-in mic (two devices, host-measured path)

| Template | Result | Detail |
|---|---|---|
| chirp-speaker (default) | ❌ preflight `inputClipping` (exit 65), no hits | ZNCC confidence 0.04 → 0.35 across -48 to -12 dBFS, never near the 0.9 lock threshold; the mic peaks −0.3 dBFS with the test sound at −12 dBFS and clips |
| click | ❌ preflight `nothingHeardAtCeiling` (exit 65), no hits | confidence 0, 0.24, 0.23, 0.48, 0.60, 0 (non-monotonic), 0.62 at −12 dBFS; never reaches 0.9 |

Probe table for the default template (`speakers-probes-chirp-speaker.ndjson` in the bench folder):

| Test level (dBFS) | −48 | −42 | −36 | −30 | −24 | −18 | −12 |
|---|---|---|---|---|---|---|---|
| Input peak (dBFS) | −35.6 | −29.8 | −23.3 | −17.4 | −11.0 | −4.6 | −0.2 |
| Confidence | 0.04 | 0.24 | 0.28 | 0.32 | 0.34 | 0.35 | 0.34 |

- 🎙️ **The mic does hear the chirp, loudly.** The input peak tracks the test level 1:1 plus about 12 dB, so the built-in path is hot, not deaf.
- 📉 **Confidence is flat at about 0.35 from −24 dBFS up.** More level does not help, so the limit is the waveform the speaker → air → mic path returns, not noise. That is the speaker/mic DSP bending the template (D-13's built-in mic DSP concern), consistent with the ZNCC ~0.35 seen in plan 01-07.
- 🛑 **No speakers → mic number exists yet.** The ramp does its job (named errors, never a silent run), but the default minConfidence 0.5 and the lock threshold 0.9 refuse this path. Closing this is gap work: a template tuned for the built-in path, a different lock threshold, or a different path (external mic).
- 🎚️ **The ramp climbed to −12 dBFS three times** on the chirp run (up, clip, step down 12 dB, up again, twice, then abort). Whether that was comfortable is Flo's listening check.

## 🔁 Virtual loopback (RESEARCH A1/P3)

- **Device:** `Loopback: Ableton Out` (Rogue Amoeba, 2 in / 2 out, 48 kHz), channel 1.
- **Path is not about 0.** Measured **768 frames (16.0 ms)** at buffer 128, and **768 again at buffer 256**, while the HAL reports 0. The device has a fixed internal delay that its properties do not declare.
- **Δio is exactly `2 × buffer`** (256 at 128, 512 at 256): safety offsets are 0 on this device, as reported.

## 🧭 RESEARCH assumptions

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| A1 | Label gap `S_i − S_o` holds converter/driver latency but not app buffers or safety offsets | ✅ Confirmed for buffers and safeties, with a twist | `appRoundTrip` = path + exactly `2 × buffer + safeties` at three buffers. Path is 27, not the reported 57 (digital loop skips converters). The virtual loopback's "≈ 0" expectation is refuted: 768 frames of undeclared delay |
| A2 | Self-test thresholds `\|median Δ\| ≤ 1`, `p95 \|Δ\| ≤ 2` | ✅ Workable, loose here | Observed median 0.00003, p95 0.014 to 0.063 frames, over 4 same-device runs. Median about 30000 times under its limit, p95 32 to 140 times under. One device only; not a reason to tighten yet |
| A3 | Ceilings −6 / −12 / −18 / −30 dBFS and the headphone data source | ⚠️ Loopback fine, speakers too hot | Loop locks at −48, far under −6. The speaker ceiling −12 clips the built-in mic (peak −0.2 dBFS). Headphones not benched; listening is a human check |
| A5 | Scarlett `Loop 1/2` act as zero-cable loopbacks | ✅ Confirmed | Both channels hear the chirp at confidence 1.00. They carry the stereo pair equally, so `--in-channel auto` needs help (explicit 7) |
| A8 | Spacing 450–750 ms, window 350 ms | ✅ for the loop; untested on slow paths | 0 rejected hits across the three 100-hit loop runs (every rejection count is zero). The speakers path never reached a measured hit |

Not in this table: A4, A6 (CI), A7 (per-process buffer with Ableton open, a human check).

## ✅ Hardware paths first exercised here

Plan 01-08's code had only compiled before this bench. On real hardware:

- 🔐 **Microphone permission read:** `authorized`, app named Ghostty, on every run.
- 🔇 **Mute / volume reads:** ran for the Scarlett and the MacBook speakers; neither tripped `outputMuted`.
- 📈 **Level ramp:** locked at −48 on the loop; climbed, clipped and stepped down on the speakers; named its failure each time.
- 🔎 **Channel probe:** found the Loop pair, refused to pick between them (`inChannelAmbiguous`), as designed.

## 👤 Human checks still open (collected for end-of-phase review)

- Task 3 checks of plan 01-09: reset Ghostty's mic grant and re-run; Terminal.app prompt or denial (RESEARCH Q3); listen to speakers and headphones; Ableton open at buffer 256 while SoundPing runs at 128 (also the D-04 look at the first measured hits: here they are identical to the rest, 27.00 from hit 5 on, so 5 warm-ups and 100 hits look right on the loop).
- From plan 01-07: change the sample rate or pull USB mid-run (not scripted).
- From plan 01-03: the pretty TTY look.

## 🔭 For the headline decision (plan 01-09 Task 2)

| | `path` | `appRoundTrip` |
|---|---|---|
| Scarlett loop, buffer 64 / 128 / 256 | 26 / 27 / 27 frames (0.56 ms) | 182 / 311 / 567 frames (3.8 / 6.5 / 11.8 ms) |
| Moves with SoundPing's buffer | no | yes, by exactly `2 × buffer + safeties` |
| Matches the HAL's reported figure | 57 reported vs 27 measured (30 gap, digital loop) | 341 reported vs 311 measured (same 30 gap) |

## 🔁 Verify re-run

The task's automated verify runs the bench a second time (`bash scripts/bench.sh | tail -n 1`). It ended `BENCH GATE: PASS` (folder `20261112T024849Z`).

| Gate | Numbers |
|---|---|
| CAL-01 repeatability | headline 310.0000 vs 310.0000, path 26.0000 vs 26.0000, difference 0.0000 frames |
| CAL-03 clock self-test | median Δ −0.0001, p95 \|Δ\| 0.0178 frames, n 100 |

- Same picture as the first pass: Δio 284 / 284, reported path 57 vs 26 measured, speakers → mic refused by preflight (`inputClipping` and `nothingHeardAtCeiling`), virtual loopback 767 frames of path, 50/50 valid.
