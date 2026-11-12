---
phase: "01"
slug: "audio-round-trip"
status: verified
# threats_open = count of OPEN threats at or above workflow.security_block_on severity (the blocking gate)
threats_open: 0
asvs_level: 1
created: "2026-11-12"
---

# Phase 01 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.
> Register authored at plan time (all 10 PLAN.md `<threat_model>` blocks); verified at ASVS L1 (grep depth) after all plans merged. No SUMMARY raised a new threat flag.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| CLI args / env → engine | User or agent supplies flags, labels, `--store`, `SOUNDPING_HOME` | Untrusted strings (paths, labels, selectors, indices) |
| Engine → filesystem store | run.json, setups.json, calibrations.json, clock-selftest.json, run lock | Local JSON, device names and numbers; no audio |
| Engine ↔ CoreAudio HAL | Device reads, one buffer-size write, IOProc real-time thread | Device config (must not be altered), audio buffers |
| Engine → speakers/headphones | Chirps played at a ramped level | Sound level (hearing safety) |
| Repo → CI / contributors | SwiftPM deps, GitHub Actions, CLA | Supply chain, token scope, contributor licence grant |

---

## Threat Register

| Threat ID | Category | Component | Severity | Disposition | Mitigation | Status |
|-----------|----------|-----------|----------|-------------|------------|--------|
| T-01-01 | Tampering | LICENSE | medium | mitigate | LICENSE ends with Required Notice line; hash gate in 01-01 | closed |
| T-01-02 | Tampering | Package.swift dependencies | high | mitigate | Package.swift exact: pins (apple org); Package.resolved committed | closed |
| T-01-03 | Elevation of privilege | .github/workflows/ci.yml | medium | mitigate | ci.yml permissions contents: read; checkout pinned to 40-char SHA | closed |
| T-01-04 | Repudiation | CLA.md | medium | mitigate | CLA.md byte-identical to gist (01-01 diff gate) | closed |
| T-01-05 | Tampering | RunStore slug / run folder | high | mitigate | RunStore slug [a-z0-9-], maxSlugLength 48, prefix check; RunStoreTests | closed |
| T-01-06 | Denial of service | concurrent runs | medium | mitigate | RunLock flock(LOCK_EX|LOCK_NB) → runInProgress; ci-sim exit 73 | closed |
| T-01-07 | Tampering | run.json partial writes | medium | mitigate | RunStore run.json written with .atomic | closed |
| T-01-08 | Tampering | `--store` / SOUNDPING_HOME | medium | mitigate | StorePaths invalidStorePath for non-absolute roots | closed |
| T-01-09 | Information disclosure | persisted runs | low | accept | Accepted risk (see log) | closed |
| T-01-10 | Denial of service | `--hits` / spacing parameters | low | mitigate | HitScheduler spacingTooShort; SchedulerTests | closed |
| T-01-11 | Tampering | stdout in JSON modes | medium | mitigate | Output.swift: progress to stderr, data-only stdout; ci-sim parses ndjson | closed |
| T-01-12 | Information disclosure | error envelope context | low | accept | Accepted risk (see log) | closed |
| T-01-13 | Repudiation | agent misreading failures as success | medium | mitigate | ExitCodes gate = 3, distinct codes; ci-sim gate boundary | closed |
| T-01-14 | Tampering (integrity of results) | Correlator | high | mitigate | Correlator first-peak/PSR/ambiguity; CorrelatorTests, RejectionTests | closed |
| T-01-15 | Denial of service | `--sim-miss` / `--sim-xrun` lists | low | mitigate | SimulatedBackend invalidParameters on out-of-range indices | closed |
| T-01-16 | Spoofing | device selection by name | high | mitigate | SetupResolver throws ambiguous for >1 exact/partial match; ResolverTests | closed |
| T-01-17 | Denial of service | setups.json decode | medium | mitigate | Setups setupsUnreadable typed decode | closed |
| T-01-18 | Tampering | negative MIDI IDs parsed as flags | low | mitigate | RunOptions parsing: .unconditional | closed |
| T-01-19 | Tampering | device settings | high | mitigate | No AudioObjectSetPropertyData in DeviceCatalog/HALProperty (doc comment only); the one set is HALBackend.applyBuffer, SoundPing's own per-process buffer size | closed |
| T-01-20 | Tampering (integrity of results) | calibration misuse | high | mitigate | CalibrationKind only case roundTrip; CalibrationStoreTests | closed |
| T-01-21 | Denial of service | calibrations.json / clock-selftest.json decode | medium | mitigate | schemaVersion checks in CalibrationStore/ClockSelfTestStore | closed |
| T-01-22 | Repudiation | stale or wrong clock status | medium | mitigate | ClockSelfTestStore entries carry runId + measuredAt | closed |
| T-01-23 | Denial of service | IOProc (priority inversion, dropped buffers) | high | mitigate | @_noLocks on RTState/IOCycle; build enforces | closed |
| T-01-24 | Tampering | ring buffer bounds | high | mitigate | RTState/IOCycle capacity validation; IOCycleTests | closed |
| T-01-25 | Tampering | user's device configuration | high | mitigate | Only AudioObjectSetPropertyData call is kAudioDevicePropertyBufferFrameSize (HALBackend.swift:255); source-scan test | closed |
| T-01-26 | Tampering (integrity of results) | device change mid-run | high | mitigate | DeviceListeners deviceGone/sampleRateChanged; AbortTests | closed |
| T-01-27 | Information disclosure | microphone capture | medium | mitigate | Preflight micPermissionDenied names owning app; no audio persisted | closed |
| T-01-28 | Safety (hearing damage) | LevelRamp | high | mitigate | LevelRamp firstProbeDbfs -48, headphones ceiling -30; LevelRampTests | closed |
| T-01-29 | Spoofing | ResponsibleApp env fallbacks | low | mitigate | ResponsibleApp detectedVia "env (likely)" | closed |
| T-01-30 | Tampering | user's output settings | medium | mitigate | Preflight outputMuted; reads only | closed |
| T-01-31 | Repudiation | exit-gate verdict | medium | mitigate | bench.sh numeric gates, BENCH GATE PASS/FAIL exit 3; raw JSON kept | closed |
| T-01-32 | Safety (hearing) | bench runs on speakers/headphones | medium | mitigate | bench.sh uses soundping run (ramp + ceilings always on), never passes --level/--max-level | closed |
| T-01-33 | Tampering | TCC reset and the Terminal.app prompt during the human checks | low | accept | Accepted risk (see log) | closed |
| T-01-34 | Information disclosure | `runs show <id-or-path>` / RunStore.load | low | mitigate | RunStore resolves an id under runs/ only (unreadableRun otherwise); an absolute folder path holding run.json is read where it points, because the caller names it explicitly | closed |
| T-01-SC | Tampering | SwiftPM installs | high | mitigate | Only apple/swift-argument-parser 1.8.2 + apple/swift-log 1.17.0, exact pins; no packages added after 01-01 | closed |

*Status: open · closed · open — below high threshold (non-blocking)*
*Severity: critical > high > medium > low — only open threats at or above workflow.security_block_on count toward threats_open*
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-01 | T-01-09 | Phase 1 persists no audio, only device names and numbers; raw snippets arrive in Phase 3 with their own storage cap | Plan 01-02 threat model (approved plan) | 2026-11-11 |
| AR-02 | T-01-12 | Error envelope context holds device names, store path and terminal app name only; local tool, no secrets in Phase 1 | Plan 01-03 threat model (approved plan) | 2026-11-11 |
| AR-03 | T-01-33 | Flo runs the TCC reset, re-grant and any Terminal.app allow/deny himself; no agent changes TCC state | Plan 01-09 threat model (approved plan) | 2026-11-11 |

## Security Audit 2026-11-12

| Metric | Count |
|---|---|
| Threats found | 35 |
| Closed | 35 |
| Open | 0 |
