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
expected: The level ramp (starts -48 dBFS, ceilings loopback -6 / speaker -12 / headphones -30) is comfortable and never painful. The bench saw the speaker ramp reach -12 dBFS three times before aborting
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

## Summary

total: 7
passed: 0
issues: 0
pending: 7
skipped: 0
blocked: 0

## Gaps
