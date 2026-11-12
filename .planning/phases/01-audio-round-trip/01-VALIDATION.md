---
phase: "01"
slug: "audio-round-trip"
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
# audit-milestone §5.5 distinguishes NOT-VALIDATED (draft) from PARTIAL (validated + nyquist_compliant: true) (#2117)
status: validated
nyquist_compliant: true
wave_0_complete: true
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

Rows are keyed by requirement; Plan lists every plan that declares it (audited 2026-11-12 after all 10 plans merged; full suite 238 tests green + `ci-sim: OK`).

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| — | 01-05 | 4 | ENG-01 | — | Ambiguous device names list candidates, never guess | unit | `swift test --filter ResolverTests` | ✅ | ✅ green |
| — | 01-05 | 4 | ENG-01 | — | N/A | hardware smoke | `SOUNDPING_HW=1 swift test --filter HardwareDevicesTests` | ✅ | ✅ green (on Flo's Mac, 01-05) |
| — | 01-02, 01-03, 01-07 | 2–6 | ENG-02 | — | N/A | sim integration | `swift test --filter RunStreamTests` + `scripts/ci-sim.sh` | ✅ | ✅ green |
| — | 01-08 | 7 | ENG-03 | — | Denied mic → `micPermissionDenied` naming the owning app | sim | `swift test --filter PreflightTests` | ✅ | ✅ green |
| — | 01-02, 01-10 | 2–3 | ENG-04 | — | N/A | unit | `swift test --filter SchedulerTests` | ✅ | ✅ green |
| — | 01-01, 01-02, 01-04, 01-08 | 1–7 | ENG-05 | — | N/A | sim | `swift test --filter SimulationRecoveryTests` | ✅ | ✅ green |
| — | 01-02, 01-06, 01-10 | 2–5 | ENG-06 | — | N/A | unit | `swift test --filter ResultSchemaTests` | ✅ | ✅ green |
| — | 01-07 | 6 | ENG-07 | — | Mid-run device change aborts with named cause | sim | `swift test --filter AbortTests` | ✅ | ✅ green |
| — | 01-02, 01-03, 01-04 | 2–4 | RES-01 | — | N/A | unit | `swift test --filter StatsTests` | ✅ | ✅ green |
| — | 01-05, 01-06 | 4–5 | RES-02 | — | N/A | unit | `swift test --filter ReportedLatencyTests` | ✅ | ✅ green |
| — | 01-04, 01-07, 01-09 | 3–8 | CAL-01 | — | N/A | unit | `swift test --filter CorrelatorTests` | ✅ | ✅ green |
| — | 01-06 | 5 | CAL-02 | — | N/A | unit | `swift test --filter CalibrationStoreTests` | ✅ | ✅ green |
| — | 01-06, 01-09 | 5–8 | CAL-03 | — | N/A | unit + sim | `swift test --filter ClockTests` | ✅ | ✅ green |
| — | 01-02, 01-10 | 2–3 | RUN-01 | Slug escape | `../x` label never escapes the store | unit | `swift test --filter RunStoreTests` | ✅ | ✅ green |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [x] `Package.swift` + `Tests/SoundPingKitTests/` skeleton with one passing test
- [x] `scripts/ci-sim.sh` — runs `soundping run round-trip --simulate --json --store "$TMP"` and asserts with `python3 -c` (no extra deps)
- [x] `.github/workflows/ci.yml` on `macos-26` — `swift test` + `scripts/ci-sim.sh`
- [x] Shared fixtures — synthetic chirp generator, fake device properties (Scarlett + MacBook values), fake PermissionProbe
- [x] `scripts/bench.sh` — the human bench procedure (prints commands + expected ranges)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real mic denial names Ghostty | ENG-03 | Needs real TCC state | ⬜ open — `tccutil reset Microphone com.mitchellh.ghostty`, run, confirm message names Ghostty, re-grant |
| Unplug / change sample rate mid-run aborts | ENG-07 | Needs physical device | ⬜ open — start a run, change rate in Audio MIDI Setup or unplug; expect named abort, exit 75 (listener wiring proven in sim + register/remove on real device) |
| Two loopback runs agree within 1–2 samples | CAL-01 | Needs Scarlett loopback | ✅ `just bench`: 311 vs 311 frames (01-BENCH.md); `HardwareRoundTripTests` green on hardware (01-07) |
| Host-clock self-test passes on hardware (exit gate) | CAL-03 | Needs real HAL timestamps | ✅ `just bench`: median Δ −0.00003, p95 0.014 frames (01-BENCH.md) |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 120s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** validated 2026-11-12 (automated coverage complete; 2 manual-only checks open)

## Validation Audit 2026-11-12

| Metric | Count |
|---|---|
| Gaps found | 0 |
| Resolved | 0 |
| Escalated | 0 |
