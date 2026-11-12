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
WORK="$(mktemp -d)"
HOLDER_PID=""
cleanup() {
  if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null || true; fi
  rm -rf "$STORE" "$STORE2" "$OUT" "$NDJSON" "$WORK"
}
trap cleanup EXIT

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
# Measured next to reported (RES-02): the simulated duplex runs 2 x 128 + 28 frames of I/O offset
# ahead, so the headline app round trip is the path plus that; a passing run stores a calibration.
assert r["measured"]["domain"] == "sample" and r["measured"]["headline"] == "appRoundTrip", r["measured"]
assert abs(r["measured"]["ioOffset"]["median"]["frames"] - 284) < 0.001, r["measured"]["ioOffset"]
assert abs(r["measured"]["appRoundTrip"]["median"]["frames"] - (412.37 + 284)) <= 0.1, r["measured"]
assert r["reported"]["source"] == "halReported", r["reported"]
assert r["calibration"]["stored"] is True and r["calibration"]["label"] == "round trip", r["calibration"]
ids = [s["id"] for s in r["segments"]]
assert ids == ["audioOutput", "transmission", "audioInput"], ids
print(r["runPath"])
' "$OUT")"

cmp "$OUT" "$RUN_PATH/run.json"

python3 -c '
import json, sys
file = json.load(open(sys.argv[1] + "/calibrations.json"))
assert file["schemaVersion"] == 1 and len(file["calibrations"]) == 1, file
record = file["calibrations"][0]
assert record["kind"] == "roundTrip" and record["label"] == "round trip", record
assert record["key"]["sampleRate"] == 48000 and record["key"]["bufferFrames"] == 128, record["key"]
' "$STORE"

# --ndjson (D-03): every stdout line is one JSON event. The stream opens with the level probes,
# exactly one levelLocked, then armed (the preflight, ENG-03); finished is last; the 25 hit/rejected
# lines (5 warm-ups + 20 measured) come in strictly increasing index order; and the finished line
# equals the saved run.json. Nothing else may reach stdout.
"$BIN" run round-trip --simulate --seed 7 --hits 20 --ndjson --store "$STORE2" >"$NDJSON"

python3 -c '
import json, sys
lines = open(sys.argv[1]).read().split("\n")
assert lines[-1] == "", "stdout must end with a newline"
events = [json.loads(line) for line in lines[:-1]]
types = [e["type"] for e in events]
opening = 0
while types[opening] == "probe":
    opening += 1
assert opening >= 1, types[:3]
assert types[opening] == "levelLocked" and types[opening + 1] == "armed", types[: opening + 3]
assert types.count("levelLocked") == 1 and types.count("armed") == 1, types
assert all(e["index"] < 0 for e in events if e["type"] == "probe"), "probes carry negative indices"
assert events[-1]["type"] == "finished", events[-1]["type"]
hits = [e for e in events if e["type"] in ("hit", "rejected")]
assert len(hits) == 25, len(hits)
indices = [e["index"] for e in hits]
assert all(a < b for a, b in zip(indices, indices[1:])), indices
# A same-device run proves its clock before it finishes: probes, levelLocked, armed, 25 hits,
# selfTest, finished.
assert events[-2]["type"] == "selfTest", events[-2]["type"]
assert events[-2]["pass"] is True, events[-2]
assert len(events) == opening + 1 + 1 + 25 + 1 + 1, len(events)
result = events[-1]["result"]
assert result["selfTest"]["pass"] is True, result["selfTest"]
saved = json.load(open(result["runPath"] + "/run.json"))
assert result == saved, "finished line differs from run.json"
' "$NDJSON"

# Named failures (D-03): each class exits with its own code and, in --json mode, prints exactly one
# envelope line on stdout. `expect_failure NAME EXIT CODE ARGS...` runs the CLI with --json.
expect_failure() {
  local name="$1" want_rc="$2" want_code="$3" rc
  shift 3
  set +e
  "$BIN" "$@" --json >"$WORK/failure.out" 2>"$WORK/failure.err"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    echo "ci-sim: $name: expected exit $want_rc, got $rc" >&2
    cat "$WORK/failure.err" >&2
    exit 1
  fi
  python3 -c '
import json, sys
lines = open(sys.argv[1]).read().split("\n")
assert len(lines) == 2 and lines[1] == "", "stdout must be exactly one line: %r" % lines
e = json.loads(lines[0])
assert e["schemaVersion"] == 1 and e["type"] == "error", e
assert e["code"] == sys.argv[2], (e["code"], sys.argv[2])
assert e["kind"] in ("usage", "preflight", "deviceChanged", "gate", "busy", "internal"), e
assert e["detail"], e
' "$WORK/failure.out" "$want_code"
  grep -q "^error: $want_code:" "$WORK/failure.err" || {
    echo "ci-sim: $name: stderr lacks 'error: $want_code:'" >&2
    exit 1
  }
}

expect_failure "relative store" 64 invalidStorePath run round-trip --simulate --store rel/path
expect_failure "unknown recipe" 64 unknownRecipe run nope --simulate --store "$WORK/store-unknown"

# A run while another process holds the store's flock is refused with exit 73.
mkdir -p "$WORK/store-busy"
python3 -c '
import fcntl, sys, time
handle = open(sys.argv[1] + "/.run.lock", "w")
fcntl.flock(handle, fcntl.LOCK_EX)
open(sys.argv[2], "w").write("locked")
time.sleep(60)
' "$WORK/store-busy" "$WORK/holder.ready" &
HOLDER_PID=$!
for _ in $(seq 1 100); do
  [ -f "$WORK/holder.ready" ] && break
  sleep 0.1
done
[ -f "$WORK/holder.ready" ] || { echo "ci-sim: the lock holder never started" >&2; exit 1; }
expect_failure "busy store" 73 runInProgress run round-trip --simulate --store "$WORK/store-busy"
kill "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""

# Gate class: missed hits at the normal latency leave the run armed and playing, so only measured
# hits go missing. Warm-ups are indices 0-4, measured hits 5-24, and the threshold is
# ceil(0.5 * 20) = 10 valid. The result is saved and printed, then the exit code is 3.
gate_run() {
  local name="$1" misses="$2"
  set +e
  "$BIN" run round-trip --simulate --seed 7 --sim-jitter 0 --hits 20 --sim-miss "$misses" \
    --json --store "$WORK/store-gate-$name" >"$WORK/gate-$name.out" 2>"$WORK/gate-$name.err"
  GATE_RC=$?
  set -e
}

gate_check() {
  python3 -c '
import json, os, sys
out, valid = sys.argv[1], int(sys.argv[2])
result = json.load(open(out))
path = result["measured"]["path"]
assert path["valid"] == valid and path["n"] == 20, path
assert (path.get("median") is None) == (valid == 0), path
# The ramp locks on probes the missed-hit knob cannot reach, so a run with every hit missed is a
# gate failure (exit 3), never a preflight one (exit 65).
assert result["preflight"]["lockedLevelDbfs"] is not None, result["preflight"]
saved = result["runPath"] + "/run.json"
assert os.path.isfile(saved), saved
assert open(out).read() == open(saved).read(), "stdout differs from run.json"
' "$1" "$2"
}

gate_run none "$(seq -s, 5 24)"
[ "$GATE_RC" -eq 3 ] || { echo "ci-sim: gate (valid 0): expected exit 3, got $GATE_RC" >&2; exit 1; }
grep -q "^error: tooFewValidHits:" "$WORK/gate-none.err" || { echo "ci-sim: gate (valid 0): stderr lacks tooFewValidHits" >&2; exit 1; }
gate_check "$WORK/gate-none.out" 0

gate_run nine "5,6,7,8,9,10,11,12,13,14,15"
[ "$GATE_RC" -eq 3 ] || { echo "ci-sim: gate (valid 9): expected exit 3, got $GATE_RC" >&2; exit 1; }
grep -q "^error: tooFewValidHits:" "$WORK/gate-nine.err" || { echo "ci-sim: gate (valid 9): stderr lacks tooFewValidHits" >&2; exit 1; }
gate_check "$WORK/gate-nine.out" 9

gate_run ten "5,6,7,8,9,10,11,12,13,14"
[ "$GATE_RC" -eq 0 ] || { echo "ci-sim: gate (valid 10): expected exit 0, got $GATE_RC" >&2; cat "$WORK/gate-ten.err" >&2; exit 1; }
gate_check "$WORK/gate-ten.out" 10

# Host-clock self-test (CAL-03): the explicit gate passes on the simulated duplex device and writes
# clock-selftest.json; a 3-frame input stamp bias fails it with exit 3 and the named gate error.
"$BIN" selftest clock --simulate --json --store "$WORK/store-selftest" >"$WORK/selftest.out"
python3 -c '
import json, sys
report = json.load(open(sys.argv[1]))
assert report["type"] == "clockSelfTest" and report["pass"] is True, report
assert report["schemaVersion"] == 1 and report["n"] == 100, report
assert abs(report["medianDeltaFrames"]) < 0.1, report
status = json.load(open(sys.argv[2] + "/clock-selftest.json"))
assert status["schemaVersion"] == 1, status
entry = status["entries"][0]
assert entry["deviceUID"] == report["key"]["deviceUID"] == "soundping-sim-duplex", entry
assert entry["sampleRate"] == 48000 and entry["bufferFrames"] == 128 and entry["pass"] is True, entry
' "$WORK/selftest.out" "$WORK/store-selftest"
expect_failure "clock self-test failure" 3 clockSelfTestFailed selftest clock --simulate --sim-stamp-bias 3 --store "$WORK/store-selftest-bias"
expect_failure "self-test needs one device" 64 selfTestNeedsSameDevice selftest clock --simulate --output scarlett --input "MacBook Pro Microphone" --in-channel 1 --store "$WORK/store-selftest-two"

# A device that changes under a run (ENG-07): a sample rate change at hit 30 aborts with exit 75 and
# the named code, a lost device at the first measured hit (hit 5 after 5 warm-ups) does the same, and
# neither leaves a run.json behind. An overload only rejects its own hit and the run still passes.
expect_failure "sample rate change" 75 sampleRateChanged run round-trip --simulate --hits 40 --sim-fault sampleRateChange@30 --store "$WORK/store-abort"
expect_failure "device lost at the first measured hit" 75 deviceGone run round-trip --simulate --hits 20 --sim-fault deviceGone@5 --store "$WORK/store-abort"
[ -z "$(find "$WORK/store-abort/runs" -name run.json)" ] || { echo "ci-sim: an aborted run left a run.json" >&2; exit 1; }
expect_failure "fault at a hit the run never fires" 64 invalidParameters run round-trip --simulate --hits 10 --sim-fault overload@999 --store "$WORK/store-abort-range"
expect_failure "malformed fault" 64 invalidParameters run round-trip --simulate --sim-fault nonsense@3 --store "$WORK/store-abort-spec"

"$BIN" run round-trip --simulate --seed 7 --sim-jitter 0 --hits 20 --sim-fault overload@12 \
  --json --store "$WORK/store-overload" >"$WORK/overload.out"
python3 -c '
import json, sys
result = json.load(open(sys.argv[1]))
rejected = [h["index"] for h in result["hits"] if h.get("rejection")]
assert rejected == [12], rejected
assert result["rejectedCounts"]["discontinuity"] == 1, result["rejectedCounts"]
assert result["measured"]["path"]["valid"] == 19, result["measured"]["path"]
assert result["simulation"]["faults"] == [{"kind": "overload", "atHit": 12}], result["simulation"]
' "$WORK/overload.out"

# Preflight (ENG-03): a denied microphone is silence on macOS, so the run stops before any hit with
# exit 65 and names the app that owns the permission.
expect_failure "denied microphone" 65 micPermissionDenied run round-trip --simulate --sim-permission denied --store "$WORK/store-denied"
python3 -c '
import json, sys
e = json.load(open(sys.argv[1]))
assert e["kind"] == "preflight", e
assert e["terminalApp"], e
assert e["detectedVia"], e
assert "Privacy & Security" in e["fix"] and e["terminalApp"] in e["fix"], e
' "$WORK/failure.out"
[ -z "$(find "$WORK/store-denied/runs" -name run.json 2>/dev/null)" ] || { echo "ci-sim: a refused run left a run.json" >&2; exit 1; }

# The level ramp (D-14): -48 dBFS first, locked at or below the ceiling, probes kept out of hits[],
# and five warm-ups after the lock.
"$BIN" run round-trip --simulate --seed 5 --hits 20 --json --store "$WORK/store-ramp" >"$WORK/ramp.out"
python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
p = r["preflight"]
assert p["probes"][0]["levelDbfs"] == -48, p["probes"]
assert p["lockedLevelDbfs"] <= p["ceilingDbfs"], p
assert all(h["phase"] != "probe" for h in r["hits"]), "a probe leaked into hits[]"
assert sum(1 for h in r["hits"] if h["phase"] == "warmup") == 5, r["hits"][:6]
assert r["parameters"]["templateId"] == p["templateId"] == "chirp-loopback", p
' "$WORK/ramp.out"

# Named preflight causes (ENG-03), all exit 65.
expect_failure "all-zero input" 65 inputDigitalSilence run round-trip --simulate --sim-input-zeros --store "$WORK/store-zeros"
expect_failure "clipping input" 65 inputClipping run round-trip --simulate --sim-gain-db 66 --store "$WORK/store-clip"
expect_failure "deaf path" 65 nothingHeardAtCeiling run round-trip --simulate --sim-gain-db -80 --store "$WORK/store-deaf"
expect_failure "muted output" 65 outputMuted run round-trip --simulate --sim-muted --store "$WORK/store-muted"

echo "ci-sim: OK"
