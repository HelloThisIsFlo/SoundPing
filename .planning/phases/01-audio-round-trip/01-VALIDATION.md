---
phase: "01"
slug: "audio-round-trip"
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
# audit-milestone §5.5 distinguishes NOT-VALIDATED (draft) from PARTIAL (validated + nyquist_compliant: false) (#2117)
status: draft
nyquist_compliant: false
wave_0_complete: false
created: "2026-11-11"
---

# Phase 01 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Source: `01-RESEARCH.md` § ✅ Validation Architecture.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Swift Testing (toolchain-bundled) |
| **Config file** | none — Wave 0 installs (`Package.swift` test target) |
| **Quick run command** | `swift test --filter SoundPingKitTests` (or `--filter <touched suite>`) |
| **Full suite command** | `just test` → `swift test` then `scripts/ci-sim.sh` (simulated CLI runs with JSON assertions) |
| **Hardware tests** | `SOUNDPING_HW=1 swift test --filter Hardware` — never on CI |
| **Estimated runtime** | ~60 seconds (build-dominated; simulated runs < 2 s each) |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter <touched suite>`
- **After every plan wave:** Run `just test`
- **Before `/gsd-verify-work`:** Full suite green + bench checkpoint (repeatability + `selftest clock`)
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

Task IDs are filled in once plans exist; rows are keyed by requirement until then.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | TBD | ENG-01 | — | Ambiguous device names list candidates, never guess | unit | `swift test --filter ResolverTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | ENG-01 | — | N/A | hardware smoke | `SOUNDPING_HW=1 swift test --filter HardwareDevicesTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | ENG-02 | — | N/A | sim integration | `swift test --filter RunStreamTests` + `scripts/ci-sim.sh` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | ENG-03 | — | Denied mic → `micPermissionDenied` naming the owning app | sim | `swift test --filter PreflightTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | ENG-04 | — | N/A | unit | `swift test --filter SchedulerTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | ENG-05 | — | N/A | sim | `swift test --filter SimulationRecoveryTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | ENG-06 | — | N/A | unit | `swift test --filter ResultSchemaTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | ENG-07 | — | Mid-run device change aborts with named cause | sim | `swift test --filter AbortTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | RES-01 | — | N/A | unit | `swift test --filter StatsTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | RES-02 | — | N/A | unit | `swift test --filter ReportedLatencyTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | CAL-01 | — | N/A | unit | `swift test --filter CorrelatorTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | CAL-02 | — | N/A | unit | `swift test --filter CalibrationStoreTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | CAL-03 | — | N/A | unit + sim | `swift test --filter ClockTests` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | RUN-01 | Slug escape | `../x` label never escapes the store | unit | `swift test --filter RunStoreTests` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `Package.swift` + `Tests/SoundPingKitTests/` skeleton with one passing test
- [ ] `scripts/ci-sim.sh` — runs `soundping run round-trip --simulate --json --store "$TMP"` and asserts with `python3 -c` (no extra deps)
- [ ] `.github/workflows/ci.yml` on `macos-26` — `swift test` + `scripts/ci-sim.sh`
- [ ] Shared fixtures — synthetic chirp generator, fake device properties (Scarlett + MacBook values), fake PermissionProbe
- [ ] `scripts/bench.sh` — the human bench procedure (prints commands + expected ranges)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real mic denial names Ghostty | ENG-03 | Needs real TCC state | `tccutil reset Microphone com.mitchellh.ghostty`, run, confirm message names Ghostty, re-grant |
| Unplug / change sample rate mid-run aborts | ENG-07 | Needs physical device | Start a run, change rate in Audio MIDI Setup or unplug; expect named abort |
| Two loopback runs agree within 1–2 samples | CAL-01 | Needs Scarlett loopback cable | `scripts/bench.sh repeatability` |
| Host-clock self-test passes on hardware (exit gate) | CAL-03 | Needs real HAL timestamps | `swift run soundping selftest clock --setup scarlett-loop --json` |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
