---
phase: 01-audio-round-trip
plan: 09
subsystem: testing
tags: [bench, coreaudio, scarlett, cal-01, cal-03, licence, polyform-shield, runs-list, swift-testing]

requires:
  - phase: 01-audio-round-trip
    provides: "round-trip engine, host-clock self-test, preflight and level ramp (plans 01-06 to 01-08)"
provides:
  - "scripts/bench.sh and `just bench`: the Phase 1 exit-gate procedure on real hardware"
  - "01-BENCH.md: gate verdicts, reported vs measured, RESEARCH assumptions confirmed or refuted"
  - "Same-device result screen with hardware path, SoundPing buffer and total side by side (no single headline)"
  - "`runs list` BUFFER / PATH / TOTAL columns and per-run JSON (bufferMs, pathMs, totalMs, bufferFrames)"
  - "PolyForm Shield 1.0.0 wording across PROJECT, REQUIREMENTS, ROADMAP, STACK, AGENTS; Phase 7 renamed Source-Available Release"
  - "PROJECT.md Key Decisions rows: licence, three-figure round trip, probe phase"
affects: [phase-02, phase-03, phase-06, phase-07]

actuals:
  tokens: 16800
  tasks: 3
  commits: 3
plan_head_before: b56a1401bdff269d3d5c884e93ba6c3cc61b7c07
plan_head_after: fc36f3a1fd386badcad8385e94bf402ab613b0ec

tech-stack:
  added: []
  patterns:
    - "A same-device result is three labelled figures (path measured, buffer calculated, total); the stored `measured.headline` is a calibration marker only"
    - "Pretty renderer and `runs` table/summary expose pure functions returning [String] so the layout is testable"

key-files:
  created:
    - scripts/bench.sh
    - .planning/phases/01-audio-round-trip/01-BENCH.md
    - Tests/soundpingTests/RunsListTests.swift
  modified:
    - justfile
    - Sources/SoundPingKit/Engine/RunModel.swift
    - Sources/SoundPingKit/Store/RunStore.swift
    - Sources/soundping/Commands/RunsCommand.swift
    - Sources/soundping/Render/PrettyRenderer.swift
    - Tests/SoundPingKitTests/MeasuredFiguresTests.swift
    - Tests/SoundPingKitTests/RunStoreTests.swift
    - Tests/soundpingTests/PrettyRendererTests.swift
    - Tests/soundpingTests/ReportedBlockTests.swift
    - .planning/PROJECT.md
    - .planning/REQUIREMENTS.md
    - .planning/ROADMAP.md
    - .planning/research/STACK.md
    - AGENTS.md

key-decisions:
  - "No single headline for a same-device round trip: hardware path (measured, HAL-reported figure beside it), SoundPing buffer (calculated: 2 x buffer + safety in + safety out), total (path + buffer). Flo's third option, chosen over the plan's appRoundTrip / path choice. One big number is deferred to Phase 6"
  - "`measured.headline` stays in run.json for schema stability as the marker the calibration record keys on; the calibration stored value and how corrections use it are unchanged (still appRoundTrip). No user-facing output presents it as the number"
  - "`runs list` carries BUFFER, PATH, TOTAL; PATH is the primary measured column and the one runs are compared by where a single value is needed. `medianMs` is replaced by `pathMs` / `bufferMs` / `totalMs` (+ `bufferFrames`) in the JSON listing"
  - "Licence PolyForm Shield 1.0.0 plus CLA recorded in Key Decisions (D-16); probe phase separate from warm-ups recorded (D-14)"
  - "Phase 3 note: SoundPing cannot see where a virtual device such as Loopback routes audio through CoreAudio; measure it with Phase 3's A/B method"

patterns-established:
  - "Bench gates are numeric and exit non-zero; raw JSON of every bench run is kept under <store>/bench/<UTC timestamp>/"

requirements-completed: [CAL-01, CAL-03]

coverage:
  - id: D1
    description: "`just bench` measures the Phase 1 exit gates on the Scarlett loop: CAL-01 repeatability within 2 frames and CAL-03 clock self-test, and writes 01-BENCH.md"
    requirement: CAL-01
    verification:
      - kind: other
        ref: "bash scripts/bench.sh -> BENCH GATE: PASS (CAL-01 311 vs 311 frames; CAL-03 median delta -0.00003, p95 0.014 frames)"
        status: pass
    human_judgment: false
  - id: D2
    description: "Same-device result screen shows hardware path, SoundPing buffer (with formula) and total side by side, no single headline"
    verification:
      - kind: unit
        ref: "Tests/soundpingTests/ReportedBlockTests.swift#aSameDeviceSummaryShowsPathBufferAndTotalWithMacOSBesideThem, theBreakdownLeadsWithNoSingleHeadlineNumber"
        status: pass
    human_judgment: true
    rationale: "How the breakdown reads on a real TTY is Flo's call (the pretty TTY look check from plan 01-03 is still open)"
  - id: D3
    description: "`runs list` BUFFER / PATH / TOTAL columns and per-run JSON; `runs show` prints the same three figures"
    verification:
      - kind: unit
        ref: "Tests/soundpingTests/RunsListTests.swift; Tests/SoundPingKitTests/RunStoreTests.swift#aSameDeviceRunListsBufferPathAndTotalWithNoneAsTheHeadline"
        status: pass
    human_judgment: false
  - id: D4
    description: "Licence wording sweep (source-available, PolyForm Shield 1.0.0) and the Phase 1 Key Decisions rows"
    verification:
      - kind: other
        ref: "plan Task 3 SWEEP-OK grep gate (ROADMAP Source-Available Release x3, REQUIREMENTS/PROJECT/AGENTS old wording gone, STACK and AGENTS table header)"
        status: pass
    human_judgment: false
  - id: D5
    description: "Task 3 hardware and listening checks (TCC reset, Terminal.app prompt, speakers and headphones loudness, Ableton open at buffer 256)"
    verification: []
    human_judgment: true
    rationale: "Changing real TCC state, a real Terminal.app prompt, loudness comfort and Ableton's UI need Flo"

duration: 150min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 09: Bench, three-figure round trip and licence close-out Summary

**Phase 1 exit gates pass on the Scarlett loop (CAL-01 311 vs 311 frames, CAL-03 median delta -0.00003 frames), and a same-device round trip now reads as hardware path + SoundPing buffer = total with no single headline.**

## Performance

- **Duration:** about 150 min across the Task 1 session and this continuation (approximate)
- **Completed:** 2026-11-12
- **Tasks:** 3 (Task 2 was a decision checkpoint, answered by Flo)
- **Files modified:** 17 (vs plan base)

## Accomplishments

- **Exit gates met on real hardware** (Task 1, 7f3cdfd): both gates PASS, nothing simulated. Details in `01-BENCH.md`, raw JSON under `~/Library/Application Support/SoundPing/bench/20261112T023627Z/`.
- **Bench settled the open arithmetic:** Δio equals `2 x buffer + safety in + safety out` exactly at buffers 64, 128, 256 (Scarlett 14 + 14 safety). Path is 26-27 frames at every buffer; the HAL reports 57, a constant 30-frame gap (the Loop channels skip the converters). The virtual Loopback device reports 0 and measures 768 frames (16 ms).
- **Headline decision applied (Flo's third option):**
  - Result screen: `Round trip at buffer 128, 48000 Hz` with three rows, hardware path (measured; "macOS reports ..." beside it), SoundPing buffer ("calculated: 2 x 128 buffer + 14 safety in + 14 safety out"), total ("path + buffer"; macOS-reported total beside it). The per-hit statistics are labelled "Hardware path, per-hit statistics".
  - `soundping runs list`: `RUN WHEN LABEL BUFFER PATH TOTAL VALID`; JSON carries `bufferMs`, `pathMs`, `totalMs`, `bufferFrames`. `runs show` prints buffer, path, total.
  - Two-device runs: host-measured path as before, no breakdown (buffer and total are defined for one device only).
- **Licence sweep and Key Decisions** (D-16, D-17): see Decisions Made.

## Schema approach (least disruptive)

- **run.json is unchanged.** `measured.headline` is kept (still `appRoundTrip` for same-device, `path` for two-device), along with `path`, `appRoundTrip` and `ioOffset` stats. Existing run.json files and `scripts/ci-sim.sh` (which asserts the marker) stay valid.
- **The marker's meaning narrowed:** it is the key the calibration record stores its value on (plan 01-06), documented as such on `Measured.headline`. The calibration record, `CalibrationStore` and the corrections path are untouched.
- **Only `RunListing` (the `runs list` JSON) changed shape:** `medianMs` was the headline median, which is exactly the "one number" Flo declined, so it is replaced rather than kept beside the new fields. Pre-release, schemaVersion stays 1, no in-repo consumer used it.

## Task Commits

1. **Task 1: Bench run end to end** - `7f3cdfd` (feat)
2. **Task 2: Which number is "the" round trip?** - decision checkpoint, no commit; answered by Flo (three figures, no headline)
3. **Task 3: Phase close-out**
   - `3fa6d17` (feat): three-figure result screen, `runs list` / `runs show`, tests
   - `fc36f3a` (docs): licence wording sweep, Key Decisions rows, 01-BENCH.md decision section

**Plan metadata:** the commit that adds this SUMMARY (docs: complete plan).

## Files Created/Modified

- `scripts/bench.sh`, `justfile` - the bench and `just bench` (Task 1)
- `.planning/phases/01-audio-round-trip/01-BENCH.md` - numbers, verdicts, headline decision, Phase 3 note
- `Sources/soundping/Render/PrettyRenderer.swift` - `roundTripBreakdown`, labelled statistics header
- `Sources/soundping/Commands/RunsCommand.swift` - `List.table`, `Show.summaryLines`
- `Sources/SoundPingKit/Store/RunStore.swift` - `RunListing` buffer / path / total
- `Sources/SoundPingKit/Engine/RunModel.swift` - doc on the calibration marker
- `Tests/soundpingTests/RunsListTests.swift` - new; `ReportedBlockTests`, `PrettyRendererTests`, `RunStoreTests`, `MeasuredFiguresTests` updated
- `.planning/PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md` (content only), `research/STACK.md`, `AGENTS.md` - licence wording and Key Decisions

## Decisions Made

- No single headline; three figures (see Accomplishments). Rationale: the buffer part is exact bench-proven arithmetic, so `path` is the only part a measurement discovers, and the total is what you feel at SoundPing's buffer; each answers a different question. Recorded in PROJECT.md Key Decisions and 01-BENCH.md.
- Licence PolyForm Shield 1.0.0 + CLA (D-16), probe phase separate from the 5 warm-ups (D-14), calibration and median/jitter rows marked "Validated on the bench (Phase 1)" (the latter with the digital-loop-only caveat).
- Replaced the stale phrase "before the licence is even chosen" in the STACK / AGENTS GPL row with "SoundPing, which is PolyForm Shield 1.0.0" (same text in both so a regeneration matches). The "Gap" bullet about other maintained open-source tools is untouched.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `--in-channel auto` is ambiguous on the Scarlett loop**
- **Found during:** Task 1
- **Issue:** Loop 1 and Loop 2 both hear the chirp at confidence 1.00, so the setup cannot be created with `auto`
- **Fix:** `bench.sh` falls back to `BENCH_IN_CHANNEL` (default 7)
- **Committed in:** 7f3cdfd; documented in 01-BENCH.md

### Plan-level deviation

**2. [Decision] Task 2 resolved with a third option instead of the plan's `appRoundTrip` / `path` branch**
- **Found during:** Task 2 checkpoint (Flo's answer)
- **Effect on Task 3:** the "if path, change RunCoordinator" branch was not taken. `RunCoordinator` is unchanged (headline marker and calibration value as plan 01-06 built them); the change landed in the renderer, `runs` commands, `RunListing` and tests instead. `files_modified` therefore does not include RunCoordinator.swift or the planned MeasuredFiguresTests expectation change (comment only).

**3. [Rule 2 - Missing critical] Pretty statistics lines were unlabelled**
- **Issue:** `median` / `jitter` / `p95` / `max` described the path but read as the round trip's number
- **Fix:** header line "Hardware path, per-hit statistics" (or "Path (host clock), ..." for two devices)
- **Committed in:** 3fa6d17

**Total deviations:** 1 auto-fixed (Rule 3), 1 Rule 2 addition, 1 decision-driven change to the task scope.
**Impact on plan:** no scope creep; the pretty output no longer implies a single number.

## Issues Encountered

- Task 3 `<verify>` runs `swift test` and the SWEEP grep: both pass (`Test run with 238 tests in 21 suites passed`, `SWEEP-OK`). `bash scripts/ci-sim.sh` prints `ci-sim: OK`.
- The plan's `<automated>` Task 1 verify re-ran the bench a second time (folder `20261112T024849Z`), also `BENCH GATE: PASS`.

## Open human-only checks (collected for end-of-phase review)

Not run by the agent; each needs Flo's hands, ears or a real prompt.

**Plan 01-09 Task 3 (four checks)**
- [ ] **TCC reset:** `tccutil reset Microphone com.mitchellh.ghostty`, run `just cli run round-trip --setup scarlett-loop --hits 10`; expect `micPermissionDenied` naming Ghostty before any hit; re-grant; the same command runs.
- [ ] **Terminal.app:** run the same command from Terminal.app (RESEARCH Q3); note which happens (macOS prompt, or `micPermissionDenied` naming Terminal). It becomes the Terminal.app line for Phase 7's install docs.
- [ ] **Listening:** `just cli run round-trip --output "MacBook Pro Speakers" --input "MacBook Pro Microphone" --in-channel 1 --hits 20`, then with headphones; first probes barely audible, locked level comfortable, headphones never loud (ceiling -30 dBFS). Note the speakers run currently stops at preflight (see follow-ups), so the ramp can still be heard.
- [ ] **Ableton at buffer 256:** `just cli run round-trip --setup scarlett-loop --buffer 128 --hits 20`; Ableton still shows 256, run.json records 128 (RESEARCH A7); first measured hits after the 5 warm-ups are not outliers (on the loop they are already identical, 27.00 from hit 5 on).

**Carried over from earlier plans**
- [ ] **01-07:** change the device sample rate, or pull USB, mid-run (not scripted; the abort path is covered by simulation tests only).
- [ ] **01-03:** the pretty TTY look (colours, layout), now including the new round-trip breakdown block.

## Follow-ups (logged, not fixed here)

- **MacBook speakers -> built-in mic gives no number.** Default template: preflight `inputClipping` (confidence flat about 0.35, never near the 0.9 lock threshold, mic peaks -0.2 dBFS at -12 dBFS). Click: `nothingHeardAtCeiling`. Needs a speaker-path template or a different lock threshold (or an external mic). Detail in 01-BENCH.md.
- **`--in-channel auto` is ambiguous on stereo loops** (Loop 1 and Loop 2 tie at 1.00 on the Scarlett); today an explicit channel (7) is needed.
- **`/private/tmp` store bug** (`RunStore.runsChild` prefix check, `deferred-items.md`, from 01-07). Still open; it is why the bench avoids `--store /private/tmp/...`.
- **Path steps by one frame between sessions** (26 vs 27) while constant inside a run: a CAL-01 pair taken across a session boundary can differ by 1. Inside the 2-frame limit.
- **Digital loop only:** the bench loop is the Scarlett's internal Loop 1; jitter is exactly 0. A cable loop through the converters was not benched.
- **Phase 3 note (Flo's question):** can SoundPing see where a virtual device like Loopback routes its audio? Not via CoreAudio, which exposes only declared latency. Measure it with Phase 3's A/B method instead.
- **Phase 6:** a single "big number" for the app is explicitly deferred to Phase 6.

## Known Stubs

None. No placeholder data paths were added in this plan.

## Threat Flags

None. No new network, auth or file-access surface; bench output stays under the existing store root (T-01-31/32 mitigations as planned: numeric gates, raw JSON kept, level ramp applies to every bench run).

## Next Phase Readiness

- Phase 2 may start: the CAL-03 self-test gate passes on hardware and the licence is in place and described consistently.
- Open before Phase 2 work depends on them: none of the follow-ups block it; the speakers -> mic path matters again for recipes that listen through the built-in mic.

## Self-Check: PASSED

- Created files exist: `scripts/bench.sh`, `01-BENCH.md`, `Tests/soundpingTests/RunsListTests.swift`.
- Commits `7f3cdfd`, `3fa6d17`, `fc36f3a` are ancestors of HEAD.
- `swift test` green (238 tests), `bash scripts/ci-sim.sh` OK, SWEEP-OK.

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*
