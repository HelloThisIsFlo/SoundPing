# Phase 1: Audio Round Trip - Pattern Map

**Mapped:** 2026-11-11
**Files analyzed:** ~45 new + 8 modified (grouped by folder below)
**Analogs found:** 0 / all source files (greenfield)

## 🚫 Greenfield verdict

- `git ls-files` outside `.planning/` = `AGENTS.md`, `CLAUDE.md`, `README.md`. No Swift, no Package.swift, no justfile, no scripts, no CI.
- **No in-repo analog exists for any source file.** The reference pattern for each file is the verified excerpt in `01-RESEARCH.md` (line refs below). Do not invent analogs.
- **The files this phase creates become the analogs for Phases 2–7.** Plan 2 (walking skeleton) sets the conventions; later plans copy from it.

## 📋 File Classification

| New/Modified File | Role | Data Flow | Reference pattern (01-RESEARCH.md) | Match |
|---|---|---|---|---|
| `LICENSE` | config/legal | — | D-17; verbatim PolyForm Shield 1.0.0 from branch `1.0.0` (L526, OQ5 L728) | none (external text) |
| `CLA.md` | config/legal | — | Harmony Individual CLA v1.0, Option Five (L527, OQ4 L726) | none (external template) |
| `CONTRIBUTING.md` | docs | — | D-17 | none |
| `README.md` (modify) | docs | — | D-17 exact licence text; P11 stale intro (L584) | existing file |
| `.planning/PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `research/STACK.md`, `CLAUDE.md`, `AGENTS.md` (modify) | docs | — | D-17 wording sweep list | existing files |
| `Package.swift` (+ `Package.resolved`) | config | — | L211-233 | none |
| `justfile` | config | batch | L197, P8 (L570-573: `swift build --show-bin-path`) | none |
| `scripts/ci-sim.sh`, `scripts/bench.sh` | utility | batch | Wave 0 gaps L787-792 | none |
| `.github/workflows/ci.yml` | config | batch | L743, P9 (L575-578), Wave 0 L790 | none |
| `Sources/SoundPingKit/Engine/RunEvent.swift`, `RunResult.swift` | model | streaming | Pattern 6 (L436-456) | none |
| `Sources/SoundPingKit/Engine/RunCoordinator.swift` | service (actor) | streaming / event-driven | Arch diagram L252-294, Pattern 2 (L347-375), Pattern 7 (L458-471) | none |
| `Sources/SoundPingKit/Recipes/Recipe.swift`, `RoundTripRecipe.swift`, registry | model/config | — | D-02, D-04, P6 (L562-564: `maxLatency`, spacing) | none |
| `Sources/SoundPingKit/Audio/AudioBackend.swift` (protocol) | service interface | streaming | Pattern 7 (L460-463) | none |
| `Sources/SoundPingKit/Audio/HALBackend.swift`, `RTState.swift`, IOProc | service (real-time) | streaming | Pattern 1 (L332-345), code L607-629 | none |
| `Sources/SoundPingKit/Audio/DeviceCatalog.swift` | service | request-response | code L590-605, Pattern 3 (L378-386), Pattern 8 (L477-478) | none |
| `Sources/SoundPingKit/Audio/DeviceListeners.swift` | middleware/observer | event-driven | Pattern 10 (L493-506) | none |
| `Sources/SoundPingKit/MIDI/MIDIEndpoints.swift` | service | request-response | Pattern 8 (L476), P7 (L566-568) | none |
| `Sources/SoundPingKit/Clock/HostClock.swift`, `DeviceTimeline.swift` | utility | transform | Pattern 2 (L369-375), Don't hand-roll L521-522 | none |
| `Sources/SoundPingKit/Simulation/SimulatedBackend.swift`, `Scenario.swift`, `SplitMix64.swift` | service (fake) | streaming | Pattern 7 (L458-471) | none |
| `Sources/SoundPingKit/Stimulus/Chirp.swift`, `Click.swift` | model (data) | transform | Pattern 4 (L390-392, L402) | none |
| `Sources/SoundPingKit/Detection/Correlator.swift`, `PeakPicker.swift`, `RejectionReason.swift` | utility (pure DSP) | transform | Pattern 4 (L393-403), code L644-653 | none |
| `Sources/SoundPingKit/Stats/Stats.swift`, `Histogram.swift` | utility | transform | code L655-662, RES-01 row L141 | none |
| `Sources/SoundPingKit/Preflight/PermissionProbe.swift`, `ResponsibleApp.swift`, `LevelRamp.swift` | service | request-response | Pattern 5 (L405-434), code L631-642, P4 (L549-556) | none |
| `Sources/SoundPingKit/Store/StorePaths.swift`, `RunStore.swift`, `CalibrationStore.swift`, `ClockSelfTestStore.swift`, `Setups.swift` | service | file-I/O | Pattern 9 (L481-491), Pattern 8 (L479), D-09 | none |
| `Sources/SoundPingKit/Resolver/DeviceResolver.swift` (or under Audio/) | service | request-response | Pattern 8 (L473-479), D-08..D-11 | none |
| `Sources/soundping/Commands/*.swift` (Run, Devices, Recipes, Runs, Selftest, Paths, shared `RunOptions` OptionGroup) | controller | request-response | D-02, ArgumentParser L187, L524 | none |
| `Sources/soundping/Render/Pretty.swift`, `JSON.swift`, `NDJSON.swift`, `ErrorEnvelope.swift`, `ExitCodes.swift` | component (renderer) | streaming | D-03, code L664-678 | none |
| `Tests/SoundPingKitTests/*Tests.swift` (+ fixtures) | test | — | Test map L760-780, Wave 0 L787-792 | none |

## 🧩 Pattern Assignments (reference excerpts, not analogs)

### `Package.swift` (config)
- **Copy verbatim from** 01-RESEARCH.md L211-233: tools 6.2, `.macOS(.v15)`, `exact:` pins on swift-argument-parser 1.8.2 + swift-log 1.17.0, three targets.
- Commit `Package.resolved` (L246).

### `Audio/HALBackend.swift` + `RTState.swift` (real-time, streaming)
- **Reference:** L607-629.
  ```swift
  final class RTState: Sendable {
    let writeIndex = Atomic<Int>(0)
    nonisolated(unsafe) let capture: UnsafeMutablePointer<Float>
  }
  @_noLocks
  func ioCycle(_ rt: RTState, _ src: UnsafePointer<Float>, _ n: Int) { ... store(w + n, ordering: .releasing) }
  ```
- Per-callback duties = L337-342. SPSC schedule ring = L343. Analysis poll = L344.
- Hard rule: no locks / alloc / print / async in anything reachable from the IOProc block.

### `Audio/DeviceCatalog.swift` (request-response)
- **Reference:** generic `get<T>` property helper, L593-601. Use `kAudioObjectPropertyElementMain` (L685).
- Always sum device + **stream** latency (P2, L539-542). Channel names via `kAudioObjectPropertyElementName`, channel → stream map via `kAudioDevicePropertyStreamConfiguration` (L477-478).
- Fixture values for tests: Scarlett + MacBook numbers, L385-386.

### `Detection/Correlator.swift` (pure transform)
- **Reference:** L647-652 (`vDSP_conv` positive stride, `|c|`, `vDSP_maxvi`, parabolic frac).
- Add on top: first-peak ≥ k·max (k≈0.5), ZNCC confidence − noise/signal ratio, PSR outside ±1 ms (L395-398). Template is data (D-13).
- Rejection enum cases: L403.

### `Stats/Stats.swift` (pure transform)
- **Reference:** `percentile` type-7, L657-661. Must match numpy for cross-checks.

### `Preflight/ResponsibleApp.swift`
- **Reference:** `parent(of:)` sysctl walk, L634-641; fallback `__CFBundleIdentifier`, label "likely".
- Flow + error codes: Pattern 5 flowchart L407-423; ceilings L428-432.

### `Engine/RunEvent.swift` / `RunResult.swift` (model, streaming)
- **Custom Codable with `type` discriminator** — never synthesized enum coding (L438, L513).
- Event list L439-447; RunResult fields L448-455; encoder `.sortedKeys` + ISO-8601 (L456).

### `Engine/RunCoordinator.swift` (actor, streaming)
- Public contract: `run(_ recipe:) -> AsyncThrowingStream<RunEvent, Error>` (CLAUDE.md).
- Waits on **sample positions** via `AudioBackend.waitUntilCaptured`, never wall-clock sleeps (L464-466, L514).
- Measurement math (`path`, `appRoundTrip`, host path, self-test Δ): L361-375.

### `Simulation/*` (fake backend)
- Protocol surface L460-463; scenario knobs L467-469; SplitMix64 seeded RNG, seed in run.json (L470). Zero CoreAudio calls (L471).

### `Store/*` (file-I/O)
- Root order `SOUNDPING_HOME` → `--store` → Application Support/SoundPing (L483).
- Layout + key shape L484-488; atomic writes L489; `flock` on `.run.lock` → `busy` (L490); slug sanitised (L780).
- `CalibrationKind` has **no** mic-delay case (L145).

### `Commands/*` + `Render/*` (controller / renderer)
- Shared flags in one `@OptionGroup`; `AsyncParsableCommand` for `run`.
- Exit codes + error envelope table: L665-678 (64 usage, 65 preflight, 75 device change, 3 gate, 73 busy, 70 internal).
- Data → stdout, progress → stderr (D-03, L515). Negative MIDI IDs: `parsing: .unconditional` (P7).

### `justfile` + `scripts/*`
- Just only orchestrates; logic in `scripts/` (CLAUDE.md). Use `swift build --show-bin-path`, never `.build/debug` (P8).
- `ci-sim.sh` asserts JSON with `python3 -c`, no extra deps (L789).

### `.github/workflows/ci.yml`
- `macos-26` runner, Xcode 26.6 default; `swift test` + `scripts/ci-sim.sh`. No hardware tests (`SOUNDPING_HW` gate, L758).

### Tests
- Swift Testing; suite names fixed by the test map L763-780 (`ResolverTests`, `CorrelatorTests`, `ClockTests`, …). Hardware suites gated with `.enabled(if:)` on `SOUNDPING_HW=1`.

## 🔁 Shared Patterns

- 🔴 **RT safety** — `@_noLocks` + preallocated pointers + `Atomic` (L607-629). Applies to all `Audio/` IOProc code.
- 🧾 **Codable contract** — type-discriminated, `schemaVersion`, sorted keys. Applies to RunEvent, RunResult, store files, setups.json, error envelope.
- 🗂️ **Store root resolution** — one `StorePaths` used by CLI, tests, and later the app.
- 🧪 **Backend protocol** — every engine path testable through `SimulatedBackend`; CLI never imports CoreAudio.
- 📣 **Errors** — one error enum mapped to exit-code class + JSON envelope (L664-678).

## ❓ No Analog Found

All source, config, script, CI and test files. Reason: greenfield repo. Use the 01-RESEARCH.md references above.

## Metadata

- **Search scope:** whole repo (`git ls-files`), tracked files only
- **Files scanned:** 3 non-planning files
- **Date:** 2026-11-11
