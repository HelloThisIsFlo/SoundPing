# Walking Skeleton — SoundPing

**Phase:** 1
**Generated:** 2026-11-11

## Capability Proven End-to-End

> An agent (or Flo) runs `soundping run round-trip --simulate --json --store <dir>` and gets the injected latency back, sub-sample accurate, as a saved `run.json` whose bytes equal the printed JSON, and GitHub Actions runs the same command on every push.

- Proven by plans 01-01 (licensed, buildable, CI-checked repo) and 01-02 (the round-trip slice through every layer).
- Every later plan in Phase 1, and every later phase, adds a slice on top of this path without changing the decisions below.

## Architectural Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language + build | Swift 6 language mode, SwiftPM `swift-tools-version: 6.2`, `platforms: [.macOS(.v15)]` | Native CoreAudio/CoreMIDI with no FFI; 6.2 floor builds on CI's Xcode 26.6 and local 6.4.2 (RESEARCH P9) |
| Targets | `SoundPingKit` (engine library), `soundping` (CLI executable), `SoundPingKitTests` + `soundpingTests` (Swift Testing) | The CLI never imports CoreAudio; the Phase 6 app reuses the engine unchanged |
| Engine → UI contract | `RunCoordinator.run(_ request: RunRequest) -> AsyncThrowingStream<RunEvent, Error>` | One event stream feeds pretty, `--json`, `--ndjson` and later the app (D-03) |
| Wire + file format | One Codable schema (`RunEvent` with a `type` discriminator, `RunResult` with `schemaVersion: 1`), encoded with sorted keys + ISO-8601 UTC dates | `--json` output = `run.json` = what the app reads (D-03); agent-friendly, stable diffs |
| Data layer | Plain JSON files under the store root: `runs/<yyyyMMdd'T'HHmmss'Z'>-<slug>/run.json`, `calibrations.json`, `clock-selftest.json`, `setups.json`, `.run.lock` | Zero dependencies, readable by agents and the app; atomic writes + `flock` (D-06, RESEARCH Pattern 9) |
| Store root | `--store` flag, else `SOUNDPING_HOME`, else `~/Library/Application Support/SoundPing/`; must be absolute | Same path for CLI and app (D-06); tests and CI isolate completely |
| Audio access | `AudioBackend` protocol: `SimulatedBackend` (virtual time, no CoreAudio) and `HALBackend` (raw HAL IOProc per device, plan 01-07) | `--simulate` runs anywhere, including runners with no audio devices (ENG-05) |
| Real-time path | IOProc block → `@_noLocks` functions over preallocated buffers + `Synchronization.Atomic` indices | No locks/alloc/print/async on the audio thread (STACK "What NOT to use") |
| Common clock | Host ticks (`mach_absolute_time`), per-device per-direction timelines fitted from IOProc stamps | Same-device runs measure in samples; two-device runs and Phase 2 MIDI use host time (RESEARCH Pattern 2) |
| Detection | One matched-filter correlator over a template-as-data (log chirp default, click as A/B control) on vDSP | Sub-sample, polarity-proof, reusable as the Phase 2 reference click (D-12, D-13, D-15) |
| Auth / consent | No accounts. macOS TCC owns microphone consent; preflight names the app that holds it | Local tool, nothing leaves the machine (Out of Scope: telemetry) |
| Errors | `SoundPingError {kind, code, detail, context}` → JSON error envelope + one exit code per class (64 usage, 65 preflight, 75 device change, 3 gate, 73 busy, 70 internal) | Agents branch on codes, never on prose (D-01, D-03) |
| Deployment | GitHub Actions `macos-26` runs `swift test` + `scripts/ci-sim.sh`; locally `just test` | CI proves the skeleton on every push; release signing arrives in Phase 7 |
| Orchestration | `justfile` recipes call `scripts/*.sh`; binaries located with `swift build --show-bin-path` | Flo's convention (Just over Make, logic in scripts); avoids the moved `.build/debug` path (RESEARCH P8) |
| Directory layout | `Sources/SoundPingKit/{Engine,Recipes,Audio,MIDI,Clock,Simulation,Stimulus,Detection,Stats,Preflight,Measurement,Store}/`, `Sources/soundping/{Commands,Render}/`, `Tests/{SoundPingKitTests,soundpingTests}/`, `scripts/` | Folder = responsibility tier from RESEARCH's Architectural Responsibility Map |
| Licence | PolyForm Shield 1.0.0 (source-available), CLA for contributions | D-16, D-17 |

## Stack Touched in Phase 1

- [ ] Project scaffold: `Package.swift` (exact pins, committed `Package.resolved`), Swift Testing, `justfile`, `.gitignore` (plan 01-01)
- [ ] Routing: the `soundping run <recipe>` subcommand with the shared `@OptionGroup` flags (plan 01-02)
- [ ] Data layer: a real write (`run.json` per run, plan 01-02) and a real read (`soundping runs list/show`, plan 01-10)
- [ ] UI: the CLI invocation prints the result (`--json` in 01-02; live `--ndjson` and pretty TTY in 01-03)
- [ ] Deployment: CI on `macos-26` runs `swift test` + the simulated round trip on every push (plans 01-01, 01-02)

## Out of Scope (Deferred to Later Slices)

- Inside Phase 1, later plans: labels/tags, collision-safe folders, run lock, `runs list/show` and contract tests (01-10), live/pretty output and error envelope (01-03), detector/stats rigor (01-04), device listing + selection (01-05), clock self-test + reported vs measured + calibrations (01-06), the real HAL backend (01-07), preflight + level ramp (01-08), bench gate (01-09)
- Later phases: tool-sent MIDI (Phase 2), raw audio snippets + export + run comparison (Phase 3), key press (Phase 4), transports (Phase 5), native app (Phase 6), signed release (Phase 7)
- Deferred ideas (CONTEXT.md): adaptive stopping, multi-sine precision loopback, a `calibrate` alias

## Subsequent Slice Plan

Each later phase adds one vertical slice on top of this skeleton without altering its architectural decisions:

- Phase 2: tool-sent MIDI note → DAW → sound, reusing the chirp as reference click and the clock self-test status
- Phase 3: output-chain A/B loopback + run comparison + snippets/export
- Phase 4: real key press + chain breakdown
- Phase 5: transport comparison (opens with the TRAN-01 echo spike)
- Phase 6: SwiftUI app over the same `RunEvent` stream and store
- Phase 7: signed, notarised DMG + Homebrew cask + Sparkle
