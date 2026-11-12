# Deferred items, phase 01

Out-of-scope discoveries logged by plan executors. Not fixed by the plan that found them.

## From 01-07

- **`RunStore.runsChild` fails for a store under `/private/...`.** It compares `paths.runs.standardizedFileURL.path + "/"` with the standardized child path. `standardizedFileURL` strips a leading `/private` only when the stripped path exists, so the parent (exists) becomes `/tmp/...` and the not-yet-created child keeps `/private/tmp/...`; the prefix check fails and `soundping run --store /private/tmp/x` ends with `unreadableRun: '<id>' is not a run id under ...` after the audio ran. `/tmp/...`, `/var/folders/...` and the default store are unaffected. Fix idea: compare resolved real paths of the parent, or check the name only (no `/`, not `.`/`..`) and skip the prefix test. Found at `Sources/SoundPingKit/Store/RunStore.swift:113`.
