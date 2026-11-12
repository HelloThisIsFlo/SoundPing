---
phase: 01-audio-round-trip
plan: 10
subsystem: store
tags: [swift6, run-store, flock, argument-parser, swift-testing, json-contract]

requires:
  - phase: 01-audio-round-trip/02
    provides: RunStore/StorePaths, RunOptions flag group, withErrorReporting seam, RunResult/RunEvent contract, HitScheduler
provides:
  - "--label (verbatim) and repeatable --tag (deduplicated, order kept) on soundping run"
  - RunStore.slug (traversal-safe, 48-char cap), collision-safe createRunFolder (-2, -3)
  - RunStore.list() -> [RunListing], load(_:), loadBytes(_:)
  - RunLock (flock LOCK_EX|LOCK_NB on <root>/.run.lock) held through RunOptions.makeStore()
  - soundping runs list|show with --json and --store
  - RunStoreTests, ResultSchemaTests, SchedulerTests
affects: [01-03, 01-05, all later phases that read saved runs]

plan_head_before: 4ab39f49f33736d5b448e70869bd964f87e7bf55
plan_head_after: 42ae1046d33a94a4ab446f8e66b2a7bc44a29cc7

actuals:
  tokens: 8000
  tasks: 3
  commits: 4

tech-stack:
  added: []
  patterns:
    - "RunStore carries an optional RunLock reference, so the lock lives as long as any copy of the store (the coordinator's Session keeps one for the whole run)"
    - "Run ids are bare folder names resolved through one runsChild(named:) guard (no '/', not '.' or '..', standardized-prefix check); absolute paths must hold run.json"
    - "runs subcommands resolve StorePaths directly and never take the lock, so listing works during a run"

key-files:
  created:
    - Sources/SoundPingKit/Store/RunLock.swift
    - Sources/soundping/Commands/RunsCommand.swift
    - Tests/SoundPingKitTests/RunStoreTests.swift
    - Tests/SoundPingKitTests/ResultSchemaTests.swift
    - Tests/SoundPingKitTests/SchedulerTests.swift
  modified:
    - Sources/SoundPingKit/Store/RunStore.swift
    - Sources/soundping/Commands/RunOptions.swift
    - Sources/soundping/SoundPing.swift

key-decisions:
  - "runs list/show declare their own --json flag instead of reusing OutputOptions, whose help text promises run.json bytes and which plan 01-05 may extend"
  - "Slug is the lowercased `<recipe id>-<label>` mapped to [a-z0-9-] and capped at 48 characters, so the recipe id counts toward the cap"
  - "StorePaths needed no change: the precedence and absolute-root tests passed against plan 01-02's code"

patterns-established:
  - "TDD for a plan with an existing tracer: the RED commit carries compile-only API stubs so the target fails on its assertion, never on a build error"

requirements-completed: [RUN-01, ENG-04, ENG-06]

coverage:
  - id: D1
    description: "`soundping run round-trip --simulate --label '../../x' --tag a --tag a --tag b` stores the label verbatim and tags [a, b]; the run lands in <store>/runs/<stamp>-round-trip-x and `runs list --json` returns it"
    requirement: RUN-01
    verification:
      - kind: other
        ref: "Task 1 automated verify -> RUNS-OK"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/RunStoreTests.swift#slugNeutralisesTraversalAndStaysInsideRuns"
        status: pass
    human_judgment: false
  - id: D2
    description: "Slug boundary (48 kept, 49 cut, trailing dash trimmed), non-ASCII to dashes, empty label gives the recipe id, same-second runs get -2 and -3, createdAt-descending list order with folder-name ties"
    requirement: RUN-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/RunStoreTests.swift (slug*, sameSecondSameSlugGetsSuffixes, listSortsNewestFirstThenByFolderName)"
        status: pass
    human_judgment: false
  - id: D3
    description: "A second run while another process holds <store>/.run.lock fails with runInProgress; `runs show --json` prints bytes identical to run.json; ids that could leave runs/ fail with unreadableRun"
    requirement: RUN-01
    verification:
      - kind: other
        ref: "Task 2 automated verify -> SHOW-LOCK-OK (cmp + python fcntl.flock holder)"
        status: pass
      - kind: unit
        ref: "Tests/SoundPingKitTests/RunStoreTests.swift (aSecondRunLockOnTheSameRootIsBusy, loadRefusesIdsThatCouldLeaveRuns, anUndecodableRunJsonIsUnreadableAndNamesThePath)"
        status: pass
    human_judgment: false
  - id: D4
    description: "ENG-04 pinned: gaps within [450, 750] ms and not all equal, seed reproducibility, warm-up count, spacingTooShort, and the defaults pass the guard for every StimulusLibrary template up to 50 ms"
    requirement: ENG-04
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/SchedulerTests.swift#defaultsPassSpacingGuard and the other SchedulerTests cases"
        status: pass
    human_judgment: false
  - id: D5
    description: "ENG-06 pinned: every RunEvent case encodes a `type` key, RunResult round-trips unchanged with sorted keys, schemaVersion 1, `[]` for empty corrections and tags, segments in order audioOutput, transmission, audioInput"
    requirement: ENG-06
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/ResultSchemaTests.swift"
        status: pass
    human_judgment: false

duration: 20min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 10: Run labels, safe store and runs list/show Summary

**`soundping run` takes `--label`/`--tag`, saves into a traversal-proof, collision-suffixed folder under a `flock`ed store, and `soundping runs list|show` read runs back byte for byte, with the Codable contract and the seeded scheduler pinned by 27 new tests.**

## Performance

- **Duration:** ~20 min
- **Tasks:** 3 (tracer, TDD expansion, contract tests)
- **Files:** 8 (5 created, 3 modified)
- **Commits:** 4 task commits

## Accomplishments

- A run labelled `../../x` lands in `<store>/runs/<stamp>-round-trip-x/`; run.json keeps `"label" : "../../x"` verbatim and tags `["a","b"]` (duplicates dropped, order kept).
- Three runs started in the same second get `...-round-trip`, `...-round-trip-2`, `...-round-trip-3` (checked end to end through the CLI), which also removes plan 01-02's `runFolderUnavailable` on a quick second run.
- `RunLock` fails a concurrent run with `error: runInProgress` (kind busy); the lock rides on the `RunStore` returned by `makeStore()` and is kept alive by the coordinator's session, so `RunCommand.swift` and `RunCoordinator.swift` were not touched.
- `runs list [--json]` returns `{"schemaVersion":1,"runs":[...]}` sorted newest first; `runs show <id-or-path> [--json]` prints run.json bytes (`cmp` clean) or a short text summary.
- Wave-4 plans now build on pinned tests: ResultSchemaTests (contract), SchedulerTests (including `defaultsPassSpacingGuard`, which iterates `StimulusLibrary.ids` so plan 01-04's new templates are checked against the defaults whenever the suite runs).

## Task Commits

1. **Task 1: tracer, label/tag, slug, runs list** - `d5f5f80` (feat)
2. **Task 2 RED: failing RunStoreTests** - `4eb40da` (test)
3. **Task 2 GREEN: collisions, run lock, runs show, load** - `ff1cd18` (feat)
4. **Task 3: ResultSchemaTests and SchedulerTests** - `42ae104` (test)

Tracer feedback gate: the tracer `<verify>` is automated-only; it returned `RUNS-OK` before the tracer commit and the whole slice stayed green through expansion, so no checkpoint was synthesized.

## TDD

- **RED (Task 2):** `RunStoreTests` with compile-only API stubs (`acquiringRunLock` returning self, `load`/`loadBytes` throwing `notImplemented`). Command: `SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 swift test --filter RunStoreTests`. Target `sameSecondSameSlugGetsSuffixes()` failed with `runFolderUnavailable` (plan 01-02's no-overwrite) instead of producing `-2`/`-3`. Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, 14 tests, 9 pass, 5 fail, swift-testing). Semantic assessment: the target ran and failed on the planned collision behaviour; the other four failures (lock busy, load by id/path, escaping ids, undecodable run.json) failed on their own assertions against the stubs, and the nine slug/precedence/write/list cases passed at once as the plan said they would.
- **GREEN:** `RunLock` (flock), collision loop in `createRunFolder`, `runFile`/`loadBytes`/`load`; suite passes (14 tests).
- **REFACTOR:** none.
- **Task 3** is characterization of plan 01-02 code and was expected green on first run (no RED phase by design, per the plan). All 13 tests passed first time, so no plan 01-02 bug surfaced.
- RED commit `4eb40da` precedes GREEN `ff1cd18`.

## Decisions Made

See `key-decisions`. Notes for wave 4:

- `RunStore` gained `slug(recipeId:label:)`, `acquiringRunLock()`, `list()`, `load(_:)`, `loadBytes(_:)`; `RunsCommand` has nested `List` and `Show` subcommands registered in `SoundPing.swift`, so plans 01-03/01-05 can append subcommands to `RunsCommand.configuration`.
- `RunOptions.makeStore()` now takes the lock, so any command that calls it for a read-only purpose must resolve `StorePaths` itself like `RunsCommand` does.

## Deviations from Plan

### Auto-fixed / additive

**1. [Rule 3 - Blocking] RED stubs in the production tree**
- **Found during:** Task 2 RED
- **Issue:** `<behavior>` puts load and the lock under "start red", but a test that references an API that does not exist is a build failure (INVALID_RED), not a RED.
- **Fix:** the RED commit includes compile-only stubs; GREEN replaces them.
- **Files modified:** `RunLock.swift`, `RunStore.swift`
- **Commit:** `4eb40da`

**2. [Plan shorthand] `armed` event runId can lack a collision suffix**
- **Found during:** Task 2
- **Issue:** the coordinator predicts the run id with `RunStore.folderName` for the `armed` event and then overwrites `result.runId` with the real folder name. With suffixes the two can differ (`...-round-trip` armed, `...-round-trip-2` final). `RunCoordinator.swift` is outside this plan's files, so it was left alone. The saved run.json and the `finished` event carry the true id.
- **Impact:** only a second run started in the same second as another is affected. A later plan that owns the coordinator can create the folder before emitting `armed`.

**3. [Scope] `swift format` touched four files outside the plan**
- **Found during:** Task 2 formatting
- **Fix:** `HitScheduler.swift`, `RunCoordinator.swift`, `SimulatedBackend.swift` and `Stats.swift` were reverted with `git checkout -- <file>` before committing; only plan files were staged.

**Total deviations:** 3 (1 blocking-gap stub, 1 documented limitation, 1 scope revert). **Impact:** none on the plan's goals.

## Issues Encountered

- The worktree sandbox refused git plumbing inside the shared `.git` directory, so the persisted plan-head ledger (`gsd-plan-head-before-01-10`) could not be written. `plan_head_before` is the dispatch base `4ab39f4` and `commits` is measured from it with `git rev-list --count`.
- Pre-existing, out of scope: `swift format` would reformat four files from plan 01-02 (logged here, not fixed).

## Known Stubs

None. (`Correlator` `psr: nil` from plan 01-02 is untouched and resolved by plan 01-04.)

## Threat Flags

None. T-01-05 (slug and prefix guard), T-01-06 (flock) and T-01-34 (load) are mitigated and covered by RunStoreTests plus the RUNS-OK and SHOW-LOCK-OK gates. T-01-SC: no new packages.

## User Setup Required

None.

## Next Phase Readiness

- Plans 01-03 and 01-05 can extend `RunsCommand` and `RunOptions` as left here.
- The `armed` event runId note above matters if plan 01-05's streaming renderer prints it before the run finishes.

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*

## Self-Check: PASSED

All 8 plan files present; commits d5f5f80, 4eb40da, ff1cd18, 42ae104 are ancestors of HEAD; gates RUNS-OK, SHOW-LOCK-OK, `Suite RunStoreTests passed`, both Task 3 gates and `just test` (32 tests plus `ci-sim: OK`) pass.
