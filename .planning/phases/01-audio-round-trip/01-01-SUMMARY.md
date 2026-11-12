---
phase: 01-audio-round-trip
plan: 01
subsystem: infra
tags: [swiftpm, polyform-shield, github-actions, swift-testing, argument-parser, cla]

requires: []
provides:
  - PolyForm Shield 1.0.0 LICENSE (verbatim, hash-verified) with Required Notice
  - SwiftPM package with SoundPingKit library, soundping executable and SoundPingKitTests
  - just/scripts orchestration (test, cli, fmt)
  - CI on macos-26 (build, test, soundping --version)
  - CLA.md (byte-identical to Flo's CLA Assistant gist), CONTRIBUTING.md, current README
affects: [01-02, all later Phase 1 plans, release phase]

plan_head_before: 73c3a756d61f1ab642b01399dc3603ed5beb19ab
plan_head_after: 1a9579d0449febedad88f9e232d8e93c4872e99d

actuals:
  tokens: 4500
  tasks: 2
  commits: 2

tech-stack:
  added: [swift-argument-parser 1.8.2, swift-log 1.17.0]
  patterns:
    - "Just orchestrates, scripts hold logic"
    - "scripts/cli.sh resolves the binary via swift build --show-bin-path"
    - "CI calls swift and scripts directly, not just"

key-files:
  created:
    - LICENSE
    - Package.swift
    - Package.resolved
    - .gitignore
    - justfile
    - scripts/test.sh
    - scripts/cli.sh
    - .github/workflows/ci.yml
    - Sources/SoundPingKit/SoundPingKit.swift
    - Sources/soundping/SoundPing.swift
    - Tests/SoundPingKitTests/SmokeTests.swift
    - CLA.md
    - CONTRIBUTING.md
  modified:
    - README.md

key-decisions:
  - "actions/checkout pinned to v7.0.1 commit 3d3c42e5aac5ba805825da76410c181273ba90b1 (latest release at execution time)"
  - "CLA.md left untouched even though the plan's 'relicens' grep does not match it; byte-identity with the signed gist wins"

requirements-completed: [ENG-05]

coverage:
  - id: D1
    description: "LICENSE is PolyForm Shield 1.0.0 verbatim (lines 1-89 hash-checked) plus the Required Notice, no Licensor Line of Business line"
    requirement: ENG-05
    verification:
      - kind: other
        ref: "head -n 89 LICENSE | shasum -a 256 == 56328093...; tail -n 1 LICENSE == Required Notice; LICENSE-OK"
        status: pass
    human_judgment: false
  - id: D2
    description: "swift build, swift test and soundping --version (0.1.0) succeed on a clean checkout; just test and just cli work"
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/SmokeTests.swift#versionLooksLikeSemver"
        status: pass
      - kind: other
        ref: "swift run soundping --version == 0.1.0"
        status: pass
    human_judgment: false
  - id: D3
    description: "CI workflow on macos-26 with read-only permissions and SHA-pinned checkout"
    verification:
      - kind: other
        ref: "grep gates on .github/workflows/ci.yml (CI-OK)"
        status: pass
    human_judgment: true
    rationale: "The workflow has not run on GitHub yet; a green macos-26 run is only provable after Flo pushes"
  - id: D4
    description: "CLA.md byte-identical to Flo's gist; CONTRIBUTING.md and README carry the CLA pointer and the D-17 licence text"
    verification:
      - kind: other
        ref: "gh api gists/e803ee99... | diff -q - CLA.md (CLA-MATCH); DOCS-OK"
        status: pass
    human_judgment: false

duration: 3min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 01: Licence, SwiftPM scaffold and CI Summary

**PolyForm Shield 1.0.0 LICENSE (hash-verified) as the first code commit, a building and tested SwiftPM package (`soundping --version` prints 0.1.0), macos-26 CI, and the CLA/CONTRIBUTING/README contribution terms.**

## Performance

- **Duration:** 3 min
- **Started:** 2026-11-12T00:22:00Z
- **Completed:** 2026-11-12T00:24:43Z
- **Tasks:** 2
- **Files modified:** 14 (13 created, 1 rewritten)

## Accomplishments

- LICENSE: lines 1-89 sha256 `56328093...a91` as required, blank line, `Required Notice: Copyright 2026 Flo Kempenich`, no Licensor Line of Business line.
- Package builds with exact-pinned dependencies (swift-argument-parser 1.8.2, swift-log 1.17.0); `Package.resolved` committed.
- Swift Testing smoke suite passes ("Suite SmokeTests passed"); `just test` and `just cli --version` work.
- CI workflow: push + pull_request, `permissions: contents: read`, `runs-on: macos-26`, checkout pinned by SHA.
- CLA.md copied byte for byte from Flo's gist; CONTRIBUTING.md and README (current product description plus the D-17 licence section) added.

## Task Commits

1. **Task 1: Licensed, buildable, CI-checked repo (tracer)** - `8a090f7` (feat)
2. **Task 2: CLA.md, CONTRIBUTING.md and README** - `1a9579d` (docs)

**Plan metadata:** committed after this file (docs: complete plan)

Tracer feedback gate: the tracer `<verify>` carried only `<automated>` checks; re-run end-to-end after the commit and passed, so expansion continued without a checkpoint.

## Files Created/Modified

- `LICENSE` - PolyForm Shield 1.0.0 plus Required Notice
- `Package.swift`, `Package.resolved` - manifest and pinned resolution
- `Sources/SoundPingKit/SoundPingKit.swift` - `SoundPingInfo.version`
- `Sources/soundping/SoundPing.swift` - `@main` AsyncParsableCommand with `--version`
- `Tests/SoundPingKitTests/SmokeTests.swift` - version-format smoke test
- `justfile`, `scripts/test.sh`, `scripts/cli.sh` - orchestration
- `.github/workflows/ci.yml` - CI on macos-26
- `.gitignore` - `.build/`, `.swiftpm/`, `.DS_Store`
- `CLA.md`, `CONTRIBUTING.md`, `README.md` - contribution terms and public description

## Decisions Made

- Used the latest `actions/checkout` release (v7.0.1) at execution time, pinned by full SHA with the tag in a comment.
- Kept CLA.md untouched (see deviation below).

## Deviations from Plan

### Plan defect (not a code fix)

**1. [Plan verify over-specified] Task 2 `grep -qi 'relicens' CLA.md` cannot pass on the approved CLA**
- **Found during:** Task 2 verify
- **Issue:** Flo's approved CLA text grants the right to "sublicense" and to license contributions "under any terms the Maintainer chooses", but never uses the word "relicense". The plan simultaneously requires CLA.md to be byte-identical to the gist and to match that grep, which cannot both hold.
- **Fix:** Kept CLA.md byte-identical (the stronger, explicit requirement; never reword Flo's text). Verified the substantive criteria instead: `sublicens` present, `under any terms the Maintainer chooses` present, `diff -q` against the gist passes (CLA-MATCH). The CLA wording itself already covers relicensing.
- **Files modified:** none
- **Suggested follow-up:** drop `relicens` from the plan's verify when this is next touched.

---

**Total deviations:** 1 (plan verify defect, no code change)
**Impact on plan:** None on deliverables; the CLA grant is intact and matches what CLA Assistant serves.

## Issues Encountered

None.

## Known Stubs

None. `SoundPing` has no subcommands yet by design (registered by later plans).

## Threat Flags

None. No new network endpoints, auth paths or trust-boundary schema changes beyond the plan's threat model; T-01-01 to T-01-04 and T-01-SC mitigations applied (hash gate, exact pins plus committed Package.resolved, read-only token and SHA-pinned checkout, byte-identical CLA).

## User Setup Required

None - no external service configuration required. CLA Assistant is already installed by Flo (D-18).

## Next Phase Readiness

- Scaffold is ready for engine code in plan 01-02 onward.
- After Flo pushes, confirm the first macos-26 CI run is green (`gh run list --limit 1`); this is the one verification that could not run locally.

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*

## Self-Check: PASSED

All 14 files present; commits 8a090f7 and 1a9579d are ancestors of HEAD; all plan verify gates pass (LICENSE-OK, SCAFFOLD-OK, CI-OK, CLA-MATCH, DOCS-OK without the defective `relicens` grep).
