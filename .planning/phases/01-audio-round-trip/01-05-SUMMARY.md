---
phase: 01-audio-round-trip
plan: 05
subsystem: devices
tags: [swift6, coreaudio-hal, coremidi, device-resolver, setups-json, argument-parser, swift-testing]

requires:
  - phase: 01-audio-round-trip/02
    provides: ResolvedSetup/DeviceRef/MIDIRef, RunOptions flag group, StorePaths, withErrorReporting seam, RecipeRegistry
  - phase: 01-audio-round-trip/10
    provides: RunsCommand pattern, run lock taken in makeStore(), RunJSON encoders
provides:
  - "soundping devices [--json] [--simulate]: audio devices (UID, transport, clock domain, rate, per-scope 1-based channels with HAL names, device + stream latency, safety offset, this process's buffer) and MIDI sources/destinations with signed unique IDs"
  - DeviceCatalog protocol with HALDeviceCatalog (the only HAL property reader) and SimulatedCatalog (four fixtures, one MIDI destination)
  - "SetupResolver: one resolver for audio selectors, MIDI selectors and named setups (D-08..D-11)"
  - "setups.json (schemaVersion 1) with Setups.load/save and SetupBinding"
  - "run flags --setup --output --input --in-channel --out-channels --midi-out --save-setup"
  - "soundping recipes [--json] and soundping paths [--json]"
  - "ReportedLatency.compute: HAL-reported path and app-round-trip sums (RES-02 math)"
affects: [01-03, 01-06, 01-07, 01-08, 01-09, all later phases that open a device]

plan_head_before: 231e19486818be34fa59173a29f51f0a9a0811db
plan_head_after: 8be7197b553c46434ed098da98d517193605befc

actuals:
  tokens: 21000
  tasks: 3
  commits: 4

tech-stack:
  added: []
  patterns:
    - "CoreAudio is imported only in Audio/HALProperty.swift and Audio/DeviceCatalog.swift; CoreMIDI only in MIDI/MIDIEndpoints.swift; everything else works on Codable DeviceInfo/DevicesListing"
    - "Typed HAL readers (get/string/array/streamChannelCounts) always use kAudioObjectPropertyElementMain except per-channel names; nothing sets a property"
    - "Resolver errors are SoundPingError.usage with the candidate list in both detail and context[\"candidates\"] as `name (uid)` joined by `; `"
    - "Selector resolution runs inside RunOptions.makeBackend before the hardware-unavailable guard, so device errors surface first"
    - "Read-only commands (devices, recipes, paths) resolve StorePaths directly and never take the run lock"

key-files:
  created:
    - Sources/SoundPingKit/Audio/DeviceInfo.swift
    - Sources/SoundPingKit/Audio/HALProperty.swift
    - Sources/SoundPingKit/Audio/DeviceCatalog.swift
    - Sources/SoundPingKit/MIDI/MIDIEndpoints.swift
    - Sources/SoundPingKit/Simulation/SimulatedCatalog.swift
    - Sources/SoundPingKit/Engine/SetupResolver.swift
    - Sources/SoundPingKit/Store/Setups.swift
    - Sources/SoundPingKit/Measurement/ReportedLatency.swift
    - Sources/soundping/Commands/DevicesCommand.swift
    - Sources/soundping/Commands/RecipesCommand.swift
    - Sources/soundping/Commands/PathsCommand.swift
    - Tests/SoundPingKitTests/HardwareDevicesTests.swift
    - Tests/SoundPingKitTests/ResolverTests.swift
    - Tests/SoundPingKitTests/ReportedLatencyTests.swift
  modified:
    - Sources/soundping/SoundPing.swift
    - Sources/soundping/Commands/RunOptions.swift

key-decisions:
  - "Device selectors match across every device and the direction is checked afterwards (new code deviceHasNoChannels), so `MacBook Pro` is ambiguous between the mic and the speakers exactly as the plan's behavior list says, instead of being quietly disambiguated by role"
  - "Resolution lives in RunOptions.makeBackend (via resolveSetup), not makeRequest: RunCommand.swift is not this plan's file and calls makeBackend first, which is also what lets selector errors precede hardwareBackendUnavailable"
  - "A channel the HAL leaves unnamed (Loopback returns empty strings) is labelled `Channel N`, so a channel always has a label to list"
  - "When chosen output channels sit in different streams the reported stream latency is the slowest of those streams, not a sum"
  - "Simulated runs with no selectors now resolve through the catalog, so their setup gains transport `virtual` and clockDomain 0 compared with the old hard-coded duplex"

patterns-established:
  - "RED commit for a plan with an existing API surface carries compile-only stubs (notImplemented), so the target fails on its assertion and not on a build error"
  - "Fixtures mirror the real HAL: the Scarlett, MacBook mic and speakers latencies are the values read from Flo's machine, and a live `devices --json` reproduced them (mic stream 1439; Scarlett 25/14 in, 32/14 out)"

requirements-completed: [ENG-01, RES-02]

coverage:
  - id: D1
    description: "`soundping devices --json` lists every audio device with UID, transport, clock domain, rate, 1-based channels with HAL names, device + stream latency, safety offset and buffer size, plus MIDI sources and destinations with signed unique IDs, sorted by name then UID"
    requirement: ENG-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/HardwareDevicesTests.swift (SOUNDPING_HW=1, 7 tests)"
        status: pass
      - kind: other
        ref: "live `soundping devices --json` on this Mac: MacBook Pro Microphone streamLatencies [1439], Scarlett input channels include `Loop 1`"
        status: pass
    human_judgment: false
  - id: D2
    description: "`soundping devices --simulate --json` lists the duplex device, Scarlett 16i16, MacBook Pro Microphone and Speakers plus the -823739469 MIDI destination with no CoreAudio or CoreMIDI call"
    requirement: ENG-01
    verification:
      - kind: other
        ref: "Task 1 automated verify -> DEVICES-SIM-OK"
        status: pass
    human_judgment: false
  - id: D3
    description: "Selector resolution (exact UID, default keyword, exact name, unique substring), ambiguity and not-found errors with candidate UIDs, exact-name-over-substring adjacency, empty selector, row numbers never accepted, no silent system-default fallback, explicit input channel, preferred stereo default, named setups with override and UID-to-name fallback, MIDI selectors incl. negative IDs"
    requirement: ENG-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/ResolverTests.swift (33 tests)"
        status: pass
      - kind: other
        ref: "Task 2 automated verify -> RESOLVE-OK and SETUP-OK; real-hardware `run round-trip --output scarlett --input scarlett` exits 1 with inChannelRequired before any backend work"
        status: pass
    human_judgment: false
  - id: D4
    description: "setups.json is schemaVersion 1, stores uid and name for output and input, round-trips through Setups.load, and a wrong version or malformed JSON is a usage error naming the file"
    requirement: ENG-01
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/ResolverTests.swift#savedSetupsRoundTripThroughLoad, anotherSchemaVersionIsUnreadableAndNamesTheFile, malformedJSONIsUnreadableAndNamesTheFile"
        status: pass
    human_judgment: false
  - id: D5
    description: "`recipes --json` lists round-trip with segments and defaults (100 hits, 5 warm-ups); `paths --json` reports absolute store paths and the source (env, flag, default); `devices` table prints channel names under each device with a select-by-UID-or-name header"
    requirement: ENG-01
    verification:
      - kind: other
        ref: "Task 3 automated verify -> RECIPES-OK, PATHS-OK, TABLE-OK; `--store` reports source flag"
        status: pass
    human_judgment: false
  - id: D6
    description: "ReportedLatency sums device + stream latency per direction for the streams holding the chosen channels and adds both safeties and both buffers: Scarlett at buffer 128 gives 57 and 341 frames, MacBook speakers to mic gives 2203"
    requirement: RES-02
    verification:
      - kind: unit
        ref: "Tests/SoundPingKitTests/ReportedLatencyTests.swift (7 tests)"
        status: pass
    human_judgment: true
    rationale: "The arithmetic is pinned, but whether the reported sums agree with measured hardware figures (and which safety-offset reading is right, RESEARCH P3) is only settled by plan 01-06/01-07 putting them next to real measurements"

duration: 14min
completed: 2026-11-12
status: complete
---

# Phase 1 Plan 05: Device discovery and selection Summary

**`soundping devices` lists real CoreAudio and CoreMIDI devices by UID with HAL channel names and latencies (a live run reproduced the researched Scarlett and MacBook values), one resolver turns UID/name/`default`/saved-setup selectors into a pinned `ResolvedSetup` without ever guessing a device or channel, and `ReportedLatency` computes the HAL-reported path and app-round-trip sums.**

## Performance

- **Duration:** ~14 min (2026-11-12T00:57Z to 01:11Z)
- **Tasks:** 3 (tracer, TDD resolver, discovery verbs + math)
- **Files:** 16 (14 created, 2 modified)
- **Commits:** 4 task commits (measured with `git rev-list --count` from the dispatch base)

## Accomplishments

- `devices --json` works on hardware and in simulation. Live on this Mac: MacBook Pro Microphone `streamLatencies [1439]`, device 14, safety 36; Scarlett 16i16 input device 25 / safety 14, output 32 / safety 14, preferred stereo `[1, 2]`, inputs include `Loop 1`. These match the RESEARCH Pattern 3 numbers exactly, which is the check that the HAL reader is right.
- Real MIDI enumeration returns signed unique IDs (negative ones included) for the IAC bus, Scarlett, USB-MIDI piano and the WIDI Bud, and `--midi-out -823739469` parses as a value thanks to `parsing: .unconditional`.
- Resolution rules (D-08..D-11) are pinned by 33 `ResolverTests`: exact UID beats names, exact name beats substring, ambiguity and not-found list `name (uid)` candidates, `default` resolves and warns, hardware runs without selectors or an input channel fail with `deviceSelectorRequired` / `inChannelRequired` listing the HAL channel names, out channels default to the preferred stereo pair, a changed UID falls back to the stored name with the calibration warning.
- `--save-setup bench` then `--setup bench` round-trips through `<store>/setups.json` (`"schemaVersion" : 1`, uid + name per device).
- `recipes --json`, `paths --json` and the `devices` table exist; `ReportedLatency.compute` gives 57 / 341 frames for the Scarlett at buffer 128 and 2203 for MacBook speakers to mic.

## Task Commits

1. **Task 1: devices --json for audio and MIDI (tracer)** - `b9bf26f` (feat)
2. **Task 2 RED: failing ResolverTests** - `2c96ddc` (test)
3. **Task 2 GREEN: resolver, setups.json, run flags** - `a5d523c` (feat)
4. **Task 3: devices table, recipes, paths, ReportedLatency** - `8be7197` (feat)

Tracer feedback gate: the tracer `<verify>` is automated-only (`DEVICES-SIM-OK` and the hardware suite); both passed before the tracer commit and `SOUNDPING_HW=1 swift test --filter HardwareDevicesTests` stayed green through expansion, so no checkpoint was synthesized (`human_verify_mode` is `end-of-phase`).

## TDD (Task 2)

- **RED:** `ResolverTests` (33 tests) against compile-only stubs (`SetupResolver.resolve`, `Setups.load`, `Setups.save` throw `notImplemented`). Command: `SWT_SF_SYMBOLS_ENABLED=0 NO_COLOR=1 swift test --filter ResolverTests`. Target `anAmbiguousSubstringListsBothCandidatesWithUIDs()` failed on `error?.code == "ambiguousDevice"`, `error?.kind == .usage` and both candidate-string expectations. Classifier verdict `RED_EVIDENCE_OK` (`target_test_failed`, format swift-testing, 33 tests, all 33 failing). Semantic assessment: the target ran and failed on the planned assertions (expected code `ambiguousDevice` with both MacBook candidates and UIDs, actual `notImplemented` from the stub); no build, import or fixture fault. All 33 fail because every behavior sits behind the stubbed resolver or the stubbed `Setups` functions, which is expected for a feature that did not exist.
- **GREEN:** `SetupResolver`, `Setups.load/save` and the run-flag wiring; all 33 pass at the first run (`Suite ResolverTests passed`).
- **REFACTOR:** none needed.
- RED commit `2c96ddc` precedes GREEN `a5d523c`. Tasks 1 and 3 are not `tdd="true"` in the plan; Task 3's `ReportedLatencyTests` were written together with the implementation.

## Files Created/Modified

Engine: `Audio/{DeviceInfo,HALProperty,DeviceCatalog}.swift`, `MIDI/MIDIEndpoints.swift`, `Simulation/SimulatedCatalog.swift`, `Engine/SetupResolver.swift`, `Store/Setups.swift`, `Measurement/ReportedLatency.swift`. CLI: `Commands/{DevicesCommand,RecipesCommand,PathsCommand}.swift`, `Commands/RunOptions.swift`, `SoundPing.swift`. Tests: `HardwareDevicesTests`, `ResolverTests`, `ReportedLatencyTests`.

## Decisions Made

See `key-decisions`. For the plans that follow:

- **Plan 01-06/01-07:** `ReportedLatency.compute(output:outChannels:input:inChannel:bufferFrames:sampleRate:)` takes the `DeviceInfo` of each side; get them from `DeviceCatalog.listing()` by the `ResolvedSetup` UIDs. `ScopeInfo.bufferFrameSize` is this process's size read before any I/O, so pass the buffer the backend actually runs at.
- **Plan 01-08:** `--in-channel auto` is carried as the raw string and the resolver answers `inChannelAutoUnavailable`; replace that branch in `SetupResolver.pickInChannel`.
- **Plan 01-03:** `devices`, `recipes` and `paths` all use `withErrorReporting(jsonMode:)` and the module-level `writeJSONLine(_:)` helper in `DevicesCommand.swift`; the JSON envelope applies to them after merge.

## Deviations from Plan

### Auto-fixed / additive

**1. [Rule 2 - Missing critical] Extra error codes `deviceHasNoChannels`, `setupsUnwritable`, `invalidSetupName`**
- **Found during:** Task 2
- **Issue:** the plan's code list has no code for choosing a device that lacks the requested direction (a microphone as `--output`), for a failed atomic write of setups.json, or for an empty `--save-setup` name; each would otherwise surface as a misleading `invalidChannel` or an internal error.
- **Fix:** three additional usage codes. `deviceHasNoChannels` is covered by `aDeviceWithoutTheRightDirectionIsRefused`.
- **Files modified:** `Engine/SetupResolver.swift`, `Store/Setups.swift`, `Commands/RunOptions.swift`
- **Commit:** `a5d523c`

**2. [Rule 3 - Blocking] Resolution wired in `makeBackend`, not `makeRequest`**
- **Found during:** Task 2
- **Issue:** the plan says `makeRequest` resolves, but `RunCommand.swift` (not this plan's file) calls `makeBackend` first and `makeRequest(recipe:setup:)` only passes the setup on; resolving in `makeRequest` would let `hardwareBackendUnavailable` win over selector errors, contradicting "selector errors surface first".
- **Fix:** `RunOptions.resolveSetup(simulated:)` runs at the top of `makeBackend`; `makeRequest` is unchanged.
- **Commit:** `a5d523c`

**3. [Rule 1 - Bug] Unnamed HAL channels**
- **Found during:** Task 1 (live run)
- **Issue:** Loopback's virtual devices return an empty string for every channel name, which would list as blank choices.
- **Fix:** an empty or missing HAL name becomes `Channel N`.
- **Files modified:** `Audio/DeviceCatalog.swift`
- **Commit:** `b9bf26f`

**4. [Plan shorthand] Smaller points**
- The UID-changed warning appends detail after the plan's wording (`... may not apply (output 'X': old -> new)`); the plan's text is the prefix. Same for the added MIDI-ID-changed warning.
- `devices --store` is accepted for flag uniformity but never touches the store (it is in the plan's command line, so it is kept; the help text says so).
- `SetupSelectors.saveSetup` is carried but the resolver ignores it; `RunOptions.resolveSetup` does the writing.
- The plan-head ledger file could not be written (git plumbing inside the shared `.git` is refused by the worktree sandbox, same as plan 01-10); `plan_head_before` is the dispatch base and `commits` is measured from it.
- `swift format` was run on this plan's files only.

**Total deviations:** 3 auto-fixed (1 missing codes, 1 blocking wiring, 1 bug) plus shorthand notes. **Impact:** none on the plan's goals; all verify gates and success criteria pass.

## Issues Encountered

- Running `soundping paths` once without `SOUNDPING_HOME` created an empty `~/Library/Application Support/SoundPing/runs` (existing `StorePaths.resolve` behaviour, plan 01-02). I removed the two empty directories it made. Worth knowing: even read-only commands create the store root.
- The real Scarlett exposes 18 input channels (ADAT 1 to 8 included); the simulated fixture lists 10 (through S/PDIF 2), which is all the plan and tests need.
- Hardware tests silently pass on machines without the named device (the Scarlett and MacBook-mic tests `return` early); they assert only when the device is present, as the plan words it.

## Known Stubs

None. (`Correlator` `psr: nil` from plan 01-02 is untouched and resolved by plan 01-04.)

## Threat Flags

None. The only new surface is HAL and CoreMIDI reads (read-only, T-01-19: no `AudioObjectSetPropertyData` anywhere) and setups.json read/write (T-01-17: typed decode, schemaVersion check, `setupsUnreadable` naming the file, atomic write). T-01-16 is mitigated by the resolver rules and `ResolverTests`; T-01-18 by `parsing: .unconditional` plus the `RESOLVE-OK` gate. T-01-SC: no new packages.

## User Setup Required

None.

## Next Phase Readiness

- Plans 01-06 and 01-07 can consume `DevicesListing`, `ScopeInfo.bufferFrameSize` and `ReportedLatency`; the HAL backend (01-07) replaces the `hardwareBackendUnavailable` guard in `RunOptions.makeBackend` after resolution has already succeeded.
- Run `bash scripts/ci-sim.sh` after merging with plan 01-03: both plans touch `SoundPing.swift` (subcommand list) and `RunOptions.swift` is only edited here.

---
*Phase: 01-audio-round-trip*
*Completed: 2026-11-12*

## Self-Check: PASSED

All 14 created source and test files present; commits b9bf26f, 2c96ddc, a5d523c and 8be7197 are ancestors of HEAD; gates DEVICES-SIM-OK, `Suite HardwareDevicesTests passed` (SOUNDPING_HW=1), `Suite ResolverTests passed`, RESOLVE-OK, SETUP-OK, `Suite ReportedLatencyTests passed`, RECIPES-OK, PATHS-OK and TABLE-OK pass; `swift test` (98 tests) green and `bash scripts/ci-sim.sh` ends with `ci-sim: OK`; CoreAudio imported only in HALProperty.swift and DeviceCatalog.swift, CoreMIDI only in MIDIEndpoints.swift.
