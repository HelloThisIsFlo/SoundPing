---
phase: 01-audio-round-trip
plan: 04
subsystem: detection
tags: [matched-filter, zncc, first-peak, psr, vdsp, stimulus-templates, rejection, numpy-percentiles, swift-testing]

requires:
  - phase: 01-audio-round-trip/02
    provides: Correlator/Detection, SimulatedBackend/Scenario, Stats/Histogram, RejectionReason, CallbackStamp
provides:
  - Correlator with first-peak rule (k = 0.5), ZNCC minus noise/signal RMS confidence, PSR outside +-1 ms, clipped / ambiguousPeaks / discontinuity rejections
  - StimulusLibrary with five templates as data (chirp-loopback, chirp-speaker, both down-sweep twins, 1 ms Hann click)
  - Scenario.missedHits / xrunHits and --sim-miss / --sim-xrun / --sim-gain-db (ENG-05 fault injection)
  - Stats histogram whose edges agree with first + k * width (upper-bin rule holds for any width)
  - RejectionTests, CorrelatorTests, StatsTests
affects: [01-03, 01-05, 01-07, 01-08, phase-2 DAW sample and click]

plan_head_before: 4ab39f49f33736d5b448e70869bd964f87e7bf55
plan_head_after: 4ce4724d00138cc603cb1ec2ab6f3b95dfcbd434

actuals:
  tokens: 8500
  tasks: 3
  commits: 5

tech-stack:
  added: []
  patterns:
    - "Fault injection lives in Scenario (data), not in test-only backends; the CLI flags fill the same fields"
    - "Detector order: discontinuity, noPeak, clipped, lowConfidence (strongest peak), first-peak choice, ambiguousPeaks, found"
    - "Local maximum at the template's own resolution: beat every sample within ceil(fs / (2 * bandHigh)) (min 2)"

key-files:
  created:
    - Tests/SoundPingKitTests/RejectionTests.swift
    - Tests/SoundPingKitTests/CorrelatorTests.swift
    - Tests/SoundPingKitTests/StatsTests.swift
  modified:
    - Sources/SoundPingKit/Detection/Correlator.swift
    - Sources/SoundPingKit/Stimulus/Stimulus.swift
    - Sources/SoundPingKit/Stats/Stats.swift
    - Sources/SoundPingKit/Simulation/SimulatedBackend.swift
    - Sources/soundping/Commands/SimulationOptions.swift

key-decisions:
  - "The lowConfidence gate judges the strongest peak (is a template present at all); the first peak's own confidence is recorded on the hit but not gated, because a weaker direct path under an overlapping louder reflection legitimately correlates at about 0.5"
  - "Fault indices outside the scheduled hits are rejected in SimulatedBackend.schedule (usage error invalidParameters), since RunOptions and RunCoordinator are off limits to this plan"
  - "PSR is capped at 1e6 so a noise-free window still reports a finite, non-nil number (JSON has no infinity)"
  - "An xrun is modelled as 64 lost input frames on the first buffer boundary after the middle of the arrival: zeros in the capture, plus a jump in inputSampleTime of every later callback"
  - "SweepDirection gained .none and StimulusTemplate gained kind (chirp | click), both additive"

patterns-established:
  - "Edge-exact binning: compute a bin as the reader would (first + k * width) and correct floor() by looping"
  - "Synthetic detector tests render each template through its own analytic generator at an exact fractional delay"

requirements-completed: [CAL-01, RES-01, ENG-05]

coverage:
  - id: D1
    description: "Missed hits, an xrun and clipping in simulation are rejected with a named reason, counted in rejectedCounts, kept in hits[], and excluded from the statistics"
    requirement: ENG-05
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/RejectionTests.swift#missedHitsAndAnXrunAreRejectedWithTheirReason"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/RejectionTests.swift#aHotPathClipsAndEveryHitIsRejectedAsClipped"
        status: pass
      - kind: other
        ref: "soundping run round-trip --simulate --sim-jitter 0 --seed 7 --hits 30 --sim-miss 8,15 --sim-xrun 25 --json -> REJECT-OK"
        status: pass
    human_judgment: false
  - id: D2
    description: "Chirps are sub-sample accurate: worst error 0.044 frame (loopback band) and 0.014 frame (speaker band) over fractional delays 1000.00-1000.95, both polarities, noise; lowest confidence 0.89"
    requirement: CAL-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/CorrelatorTests.swift#chirpsAreSubSampleAccurateAtEveryFractionalDelay"
        status: pass
    human_judgment: false
  - id: D3
    description: "First-peak rule beats a louder later reflection; three comparable arrivals are ambiguousPeaks; noise is lowConfidence, silence noPeak; PSR above 2 on a clean chirp"
    requirement: CAL-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/CorrelatorTests.swift#aLouderLaterReflectionNeverBeatsTheDirectPath"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/CorrelatorTests.swift#threeComparableArrivalsAreAmbiguous"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/CorrelatorTests.swift#aCleanChirpReportsItsPeakToSidelobeRatio"
        status: pass
    human_judgment: false
  - id: D4
    description: "Template library as data: five templates (all at most 50 ms), separable up/down pair (ZNCC below 0.3), click A/B control within 0.5 frame (measured 0.32)"
    requirement: CAL-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/CorrelatorTests.swift#theUpAndDownSweepsStaySeparable"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/CorrelatorTests.swift#theClickControlIsWithinHalfAFrame"
        status: pass
    human_judgment: false
  - id: D5
    description: "Stats match numpy.percentile to 1e-9, N=0 gives no numbers, N=1 collapses, ties share a bin, edge values go to the upper bin, outliers stay"
    requirement: RES-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/StatsTests.swift#percentilesMatchNumpyToANanoframe"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/StatsTests.swift#aValueOnABinEdgeGoesToTheUpperBin"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/StatsTests.swift#anOutlierStaysAndMovesTheMedianByAtMostOneRank"
        status: pass
    human_judgment: false
  - id: D6
    description: "Detector behaviour on real hardware: the thresholds (k = 0.5, 0.7/0.9 ambiguity, minConfidence 0.5, 0.999 clip level) are tuned on synthetic signals only"
    requirement: CAL-01
    verification: []
    human_judgment: true
    rationale: "Real rooms, speakers and converters are not simulated; the bench plans (01-07, 01-08) are where the thresholds meet real signals"

duration: 14min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 04: Trustworthy detection and statistics Summary

**A first-peak, sub-sample matched filter (worst error 0.044 frame on the 100 Hz-20 kHz chirp) that rejects missed, xrun, clipped, ambiguous and low-confidence hits with a named reason, five stimulus templates as data, simulation knobs for missed hits / xruns / gain, and numpy-identical type-7 percentiles with edge-exact histogram bins.**

## Performance

- **Duration:** ~14 min
- **Started:** 2026-11-12T00:40Z (approx; recorded start 00:44:35Z after reading)
- **Completed:** 2026-11-12T00:54Z
- **Tasks:** 3 (1 tracer, 2 TDD)
- **Files modified:** 8 (3 created, 5 modified)
- **Commits:** 5

## Accomplishments

- **Broken hits are named and counted end to end (tracer).** `--sim-miss 8,15 --sim-xrun 25 --sim-gain-db N` fill `Scenario`; a 35-hit run keeps all 35 in `hits[]`, rejects 8 and 15 as `lowConfidence`, 25 as `discontinuity`, counts exactly 3, and the median stays at 412.37 +- 0.1.
- **Sub-sample accuracy pinned on both bands.** `chirp-loopback` worst error 0.044 frame, `chirp-speaker` 0.014 frame (both match the research prototype), lowest confidence 0.89 and 0.93 with +-0.05 noise and inverted polarity.
- **Reflection-proof.** The earliest local maximum at or above 0.5 x the strongest wins, so a direct path at 0.6 x a later 1.0 reflection is found at 1000 +- 0.1; three comparable arrivals are `ambiguousPeaks`.
- **Template library as data.** `chirp-speaker` (300 Hz-8 kHz), `chirp-loopback-down`, `chirp-speaker-down` and a 1 ms Hann `click`, each recording id, kind, band, duration and direction; all at most 50 ms so plan 01-10's spacing guard holds. An up chirp correlates with its down twin below 0.3.
- **Click A/B control measured:** worst sub-sample error 0.32 frame against 0.044 for the loopback chirp, recorded in the test output for the bench comparison.
- **Stats you can cross-check.** Percentiles equal `numpy.percentile` to 1e-9 on a 25-value fixture; N = 0 gives no numbers and no histogram; N = 1 collapses; outliers stay in `max` and in the last histogram bin.

## Task Commits

1. **Task 1: Broken hits rejected and counted (tracer)** - `7ad815e` (feat)
2. **Task 2 RED: failing CorrelatorTests** - `fb1e1c0` (test)
3. **Task 2 GREEN: template library and first-peak correlator** - `5a618b6` (feat)
4. **Task 3 RED: failing StatsTests** - `b27b2c9` (test)
5. **Task 3 GREEN: histogram edge fix** - `4ce4724` (fix)

**Plan metadata:** committed after this file (docs: complete plan)

Tracer feedback gate: the tracer `<verify>` is automated-only; re-run end to end after the tracer commit (`swift test`, `scripts/ci-sim.sh`, the REJECT-OK CLI run) and passed, so expansion continued without a checkpoint.

## TDD

- **Task 2 RED:** `CorrelatorTests` written first. Target `aLouderLaterReflectionNeverBeatsTheDirectPath()` failed on `abs(hit.frame - 1000) <= 0.1` (the old correlator took the global maximum, about 100 frames late). Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, 8 tests, 7 failing, swift-testing). Command: `SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 swift test --filter CorrelatorTests`. Semantic assessment: the target ran and failed on the planned position assertion for the intended reason; the other failures were missing templates (`unknownTemplate`), missing PSR and the missing ambiguity rule, all planned behaviour. **GREEN:** all 8 pass. **REFACTOR:** none.
- **Task 3 RED:** `StatsTests` written first. Target `aValueOnABinEdgeGoesToTheUpperBin()` failed on `histogram.counts[k] == 1` for edges 3, 6 and 12 of a 0.35-frame histogram (`1.0499999999999998` fell in bin 2). Verdict `RED_EVIDENCE_OK` (9 tests, 1 failing). Semantic assessment: a genuine bug in the plan-01-02 histogram, caught by the planned edge behaviour. The other eight cases (numpy constants, N = 0 / 1, ties, outliers, ms) were already green, which is expected for a hardening plan over code that was written to the same rules. **GREEN:** `bin(of:)` corrects `floor()` against `first + k * width`; all 9 pass. **REFACTOR:** none.
- Gate order in history: RED `fb1e1c0` before GREEN `5a618b6`; RED `b27b2c9` before GREEN `4ce4724` (committed as `fix(01-04)`, a bug fix, rather than `feat`).

## Files Created/Modified

- `Sources/SoundPingKit/Detection/Correlator.swift` - first-peak, ZNCC minus noise ratio, PSR, clipped / ambiguousPeaks / discontinuity
- `Sources/SoundPingKit/Stimulus/Stimulus.swift` - five templates, `TemplateKind`, `SweepDirection.none`
- `Sources/SoundPingKit/Stats/Stats.swift` - edge-exact histogram binning
- `Sources/SoundPingKit/Simulation/SimulatedBackend.swift` - `missedHits`, `xrunHits`, xrun gap model, full-scale clamp, index validation, tolerant `Scenario` decoding
- `Sources/soundping/Commands/SimulationOptions.swift` - `--sim-miss`, `--sim-xrun`, `--sim-gain-db` and the `HitIndexList` argument type
- `Tests/SoundPingKitTests/{RejectionTests,CorrelatorTests,StatsTests}.swift` - 3 + 8 + 9 cases

## Decisions Made

See `key-decisions`. The one worth a second look on the bench: **the lowConfidence gate sits on the strongest peak, not on the first peak.** With the plan's own reflection numbers (direct 0.6, later reflection 1.0, 30 ms chirps overlapping almost entirely) the normalised correlation at the direct arrival is about 0.53 before the noise ratio and 0.48 after, below `minConfidence`. Gating the first peak would reject exactly the case the first-peak rule exists for. The first peak's own confidence is still reported on the hit (0.48 in that case), so a reader can see it.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Histogram edge values fell into the lower bin**
- **Found during:** Task 3 RED
- **Issue:** `floor((v - first) / width)` rounds just below the integer for widths that are not exactly representable (edge 3 of a 0.35 histogram), breaking RES-01's half-open `[a, b)` rule.
- **Fix:** `bin(of:)` corrects the floor against `first + k * width`, the arithmetic any reader uses; `first` is also pulled back if `lo / width` rounded up.
- **Files modified:** `Sources/SoundPingKit/Stats/Stats.swift`
- **Verification:** `StatsTests` 9/9, `ci-sim: OK`
- **Committed in:** `4ce4724`

**2. [Rule 1 - Plan numbers] Clipping case uses +40 dB, not +30 dB**
- **Found during:** Task 1
- **Issue:** at the -30 dBFS start level, +30 dB lands exactly on full scale; only 17 of 20 hits clipped (three or more consecutive samples at 0.999 or more is not guaranteed at amplitude 1.0).
- **Fix:** the test uses +40 dB, which clips every hit. The correlator and the `--sim-gain-db` flag are unchanged.
- **Files modified:** `Tests/SoundPingKitTests/RejectionTests.swift`
- **Committed in:** `7ad815e`

**3. [Rule 1 - Design] lowConfidence gated on the strongest peak** (see Decisions Made). The plan text gates the first peak; that contradicts its own reflection example.
- **Found during:** Task 2 analysis before GREEN
- **Files modified:** `Sources/SoundPingKit/Detection/Correlator.swift`
- **Committed in:** `5a618b6`

**4. [Rule 1 - Test scale] Reflection and ambiguity tests scale the plan's gains**
- **Found during:** Task 2 GREEN
- **Issue:** the plan's reflection gain 1.0 (and the sum of three overlapping arrivals) exceeds the clip level, so the new `clipped` rule fired first.
- **Fix:** gains 0.3 / 0.5 (reflection) and 0.165 / 0.3 / 0.285 (ambiguity) keep the plan's ratios (0.6 : 1.0 and 0.55 : 1.0 : 0.95) below full scale.
- **Files modified:** `Tests/SoundPingKitTests/CorrelatorTests.swift`
- **Committed in:** `fb1e1c0` and `5a618b6`

### Plan-silent additions

**5. [Rule 2 - Missing critical] Fault-index validation placed in `SimulatedBackend.schedule`**
- The plan wants indices validated within `0..<hits+warmup` (T-01-15) but forbids editing `RunOptions`/`RunCoordinator`; the backend sees every scheduled hit, so an out-of-range index throws `invalidParameters` there (`error: invalidParameters: --sim-xrun names hit 999 ...`, exit 1). The error surfaces after the `armed` event rather than at argument parsing.
- **Committed in:** `7ad815e`

**6. [Rule 3 - Additive] `SweepDirection.none`, `StimulusTemplate.kind`, hand-written `Scenario.init(from:)`** so the click can record "no direction", templates record their kind, and a run.json saved before `missedHits`/`xrunHits` existed still decodes. No existing call site changed.

---

**Total deviations:** 6 (2 bug fixes, 1 design adjustment, 1 test-scale adjustment, 1 missing-critical placement, 1 additive).
**Impact on plan:** goals and artifacts delivered as written; deviation 3 is the one that changes behaviour relative to the plan's prose and is flagged for the bench.

## Issues Encountered

- A repeated `Write` on a file edited through `swift format` needed a fresh `Read` first; no impact on content.
- No numpy dependency: constants were computed once with `uv run --with numpy` and hard-coded with the command in `StatsTests.swift`.

## Known Stubs

None. The plan-01-02 stub (`Correlator.detect` returning `psr: nil` and ignoring `stamps`) is resolved: PSR is reported and stamps drive `discontinuity`.

## Threat Flags

None. The only new input surface is the `--sim-miss` / `--sim-xrun` / `--sim-gain-db` flags, covered by T-01-15 (indices validated, usage error). T-01-14 mitigations (first-peak, PSR, ambiguity, clipping, named and counted rejections, accuracy pinned by tests) are in place. T-01-SC: no new packages.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plans 01-03 and 01-05 (wave 4) can render `rejectedCounts` entries for all six reasons and read `confidence` / `psr` on every found hit.
- Bench plans should tune on hardware: `minConfidence` 0.5, k = 0.5, the 0.7 / 0.9 ambiguity fractions and the 0.999 clip level are synthetic-signal defaults (coverage item D6).
- `.planning/WINDOWS.md` was not touched (shared file, parallel worktrees); no stub or skipped test was left behind that would need an entry.

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*

## Self-Check: PASSED

Files present: `Sources/SoundPingKit/Detection/Correlator.swift`, `Sources/SoundPingKit/Stimulus/Stimulus.swift`, `Sources/SoundPingKit/Stats/Stats.swift`, `Sources/SoundPingKit/Simulation/SimulatedBackend.swift`, `Sources/soundping/Commands/SimulationOptions.swift`, `Tests/SoundPingKitTests/RejectionTests.swift`, `Tests/SoundPingKitTests/CorrelatorTests.swift`, `Tests/SoundPingKitTests/StatsTests.swift`. Commits `7ad815e`, `fb1e1c0`, `5a618b6`, `b27b2c9`, `4ce4724` are ancestors of HEAD. Gates: `Suite RejectionTests passed`, `Suite CorrelatorTests passed`, `Suite StatsTests passed`, `REJECT-OK`, `swift test` (25 tests in 5 suites) green, `scripts/ci-sim.sh` ends `ci-sim: OK`, `grep -ci oboe Correlator.swift` = 1, no Apache-2.0 header under Sources.
