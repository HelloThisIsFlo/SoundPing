#!/usr/bin/env bash
# CI assertion of the simulated round trip (ENG-05): the injected latency comes back as a
# saved run.json, and --json prints exactly those bytes. No CoreAudio, no audio devices.
set -euo pipefail

swift build --product soundping
BIN="$(swift build --show-bin-path)/soundping"

STORE="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$STORE" "$OUT"' EXIT

"$BIN" run round-trip --simulate --sim-latency 412.37 --sim-jitter 0 --seed 7 --json --store "$STORE" >"$OUT"

RUN_PATH="$(python3 -c '
import json, os, sys
r = json.load(open(sys.argv[1]))
assert r["schemaVersion"] == 1, r["schemaVersion"]
assert r["recipe"]["id"] == "round-trip", r["recipe"]
path = r["measured"]["path"]
assert abs(path["median"]["frames"] - 412.37) <= 0.1, path["median"]
assert path["valid"] == 100 and path["n"] == 100, (path["valid"], path["n"])
assert os.path.isabs(r["runPath"]) and os.path.isdir(r["runPath"]), r["runPath"]
assert r["corrections"] == [], r["corrections"]
ids = [s["id"] for s in r["segments"]]
assert ids == ["audioOutput", "transmission", "audioInput"], ids
print(r["runPath"])
' "$OUT")"

cmp "$OUT" "$RUN_PATH/run.json"

echo "ci-sim: OK"
