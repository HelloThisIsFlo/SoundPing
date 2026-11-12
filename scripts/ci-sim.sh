#!/usr/bin/env bash
# CI assertion of the simulated round trip (ENG-05): the injected latency comes back as a
# saved run.json, and --json prints exactly those bytes. No CoreAudio, no audio devices.
set -euo pipefail

swift build --product soundping
BIN="$(swift build --show-bin-path)/soundping"

STORE="$(mktemp -d)"
STORE2="$(mktemp -d)"
OUT="$(mktemp)"
NDJSON="$(mktemp)"
trap 'rm -rf "$STORE" "$STORE2" "$OUT" "$NDJSON"' EXIT

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

# --ndjson (D-03): every stdout line is one JSON event, armed first, finished last, the 25
# hit/rejected lines (5 warm-ups + 20 measured) in strictly increasing index order, and the
# finished line equals the saved run.json. Nothing else may reach stdout.
"$BIN" run round-trip --simulate --seed 7 --hits 20 --ndjson --store "$STORE2" >"$NDJSON"

python3 -c '
import json, sys
lines = open(sys.argv[1]).read().split("\n")
assert lines[-1] == "", "stdout must end with a newline"
events = [json.loads(line) for line in lines[:-1]]
assert events[0]["type"] == "armed", events[0]["type"]
assert events[-1]["type"] == "finished", events[-1]["type"]
hits = [e for e in events if e["type"] in ("hit", "rejected")]
assert len(hits) == 25, len(hits)
indices = [e["index"] for e in hits]
assert all(a < b for a, b in zip(indices, indices[1:])), indices
assert len(events) == 27, len(events)
result = events[-1]["result"]
saved = json.load(open(result["runPath"] + "/run.json"))
assert result == saved, "finished line differs from run.json"
' "$NDJSON"

echo "ci-sim: OK"
