---
status: testing
phase: 01-audio-round-trip
source: [01-VERIFICATION.md]
started: 2026-11-12T15:11:16Z
updated: 2026-11-12T15:11:16Z
---

## Current Test

number: 1
name: Real mic denial names the owning app (ENG-03)
expected: |
  After `tccutil reset Microphone com.mitchellh.ghostty`, `soundping run round-trip` with a mic input stops with micPermissionDenied naming Ghostty and the System Settings fix; re-grant works
awaiting: user response

## Tests

### 1. Real mic denial names the owning app (ENG-03)
expected: After `tccutil reset Microphone com.mitchellh.ghostty`, `soundping run round-trip` with a mic input stops with micPermissionDenied naming Ghostty and the System Settings fix; re-grant works
result: [pending]

### 2. Terminal.app mic prompt or denial (RESEARCH Q3)
expected: Run the CLI from Terminal.app (no NSMicrophoneUsageDescription in its Info.plist) and record whether macOS prompts or silently denies, and what SoundPing reports
result: [pending]

### 3. Unplug the interface / change sample rate or buffer mid-run on real hardware (ENG-07)
expected: Named abort, exit 75, no run saved as a valid result
result: [pending]

### 4. Listening check on MacBook speakers and on headphones
expected: The level ramp (starts -48 dBFS; the ceiling comes from the output alone: built-in speakers -12 / headphones and Bluetooth -30 / everything else -18, loops included; the `--in-channel auto` probe uses the same ceilings) is comfortable and never painful. The bench saw the speaker ramp reach -12 dBFS three times before aborting
result: [pending]

### 5. Ableton open at buffer 256 while SoundPing runs at 128 (RESEARCH A7)
expected: SoundPing's per-process buffer holds at 128 and the run is valid; the reported SoundPing buffer matches what was applied
result: [pending]

### 6. Pretty TTY look
expected: Per-hit lines, dimmed rejections, summary block, histogram and sparkline read well in Ghostty; NO_COLOR gives zero ANSI
result: [pending]

### 7. A real microphone round trip (SC1 'loopback or mic')
expected: At least one acoustic path (external mic, or a template tuned for the MacBook speakers -> built-in mic) produces valid hits and a number
result: [pending]

### 8. Scarlett Loop 1 locks at or below -18 dBFS without --max-level
expected: `just hw-test` on the Scarlett `Loop 1` round trip locks its level at or below -18 dBFS (the ceiling for an interface; no loop gets a louder one) without `--max-level`, and both runs produce valid hits
result: [pending]

### 9. Duplex round trip unchanged after the stamp redesign (code review WR-03, IN-08, WR-02, IN-13)
expected: `just hw-test` on a duplex device: the I/O offset and appRoundTrip match a run recorded before quick task 261112-ql0 within one frame; `soundping selftest clock` passes with no self-test warning; run.json and the calibration/self-test records are all written
result: [pending]

### 10. Glitches are rejected, not measured (code review WR-01, IN-01, IN-16, IN-17, IN-18, IN-19)
expected: Forcing overloads during a run (e.g. heavy CPU load or a tiny buffer) shows them as `discontinuity` rejections without shifting the median; the HAL 'over' notification lands inside the 20 ms margins; a glitched ramp or channel probe is replayed at the same level instead of climbing; an audio restart that resets the sample clock ends the run as `sampleClockReset`
result: [pending]

### 11. Two devices with different buffer sizes (code review WR-04, WR-05)
expected: MacBook speakers → built-in mic: run.json records the output and input buffer sizes separately; a buffer that settles to a different size at start is adopted (no abort), and only a change after the first hit aborts; the first run after the update asks for one recalibration
result: [pending]

### 12. Headphones plugged or unplugged mid-run abort the run (code review WR-14, WR-15, jack follow-up ad6a7d6, IN-10)
expected: Plugging or unplugging headphones on the built-in output during a run, and between channels during `--in-channel auto`, ends it with `outputRouteChanged` (data source or `jackIsConnected`) before anything plays at the wrong level; nothing aborts when nothing changes
result: [pending]

### 13. Loudness rule on real outputs (code review CR-02, CR-03, CR-04, CR-05, WR-08, WR-12, WR-13, WR-16)
expected: AirPods/Bluetooth and the built-in headphone output never ramp above -30 dBFS, including with `--in-channel auto`, a virtual input, or `--listener speaker`/`loopback` (the run warns that `--listener` didn't raise it); a virtual output heard by a real mic stays at or below -18; only `--max-level` goes louder; a "nothing heard" error names the level actually played. Check what the Apple Silicon headphone output reports (`hdpn` vs other) and that built-in speakers report `ispk`
result: [pending]

### 14. Channel probe and setup reuse on real devices (code review WR-06, IN-03, IN-05, IN-09, IN-20, WR-07)
expected: `--in-channel auto` on a multi-stream interface probes the right channels (every selected stream checked as Float32); "save channel to setup" only offers a setup bound to the probed devices; a probe followed by a run on the same backend works (fresh event stream); a refused HAL listener shows as a preflight warning; every failure appears as `.aborted` on the event stream
result: [pending]

## Summary

total: 14
passed: 0
issues: 0
pending: 14
skipped: 0
blocked: 0

## Gaps
