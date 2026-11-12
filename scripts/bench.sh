#!/usr/bin/env bash
# The Phase 1 bench: measures the exit gates on real hardware (the loop on an audio interface) and
# keeps the raw JSON of every run, so a verdict can be re-read later.
#
#   scripts/bench.sh                  run the whole bench on the real devices
#   scripts/bench.sh --compare A B    print whether two medians (in frames) pass the CAL-01 rule
#
# Gates (exit 3 with "BENCH GATE: FAIL" when either fails; "BENCH GATE: PASS" and exit 0 otherwise):
#   CAL-01  two 100-hit round-trip runs on the loop have medians within 2.0 frames of each other,
#           for the headline and for the path
#   CAL-03  `soundping selftest clock` passes on the same loop (|median delta| <= 1, p95 <= 2 frames)
# Everything else (chirp vs click, MacBook speakers -> mic, a virtual loopback) is reported, never gated.
#
# Settings (environment):
#   BENCH_SETUP       setup name in setups.json; created on first use       (default scarlett-loop)
#   BENCH_BUFFER      SoundPing's own buffer in frames                      (default 128)
#   BENCH_IN_CHANNEL  1-based input channel of the loop, used when `--in-channel auto` finds the
#                     Loop 1 / Loop 2 pair equally loud                     (default 7 = Loop 1)
#   BENCH_STORE       absolute store folder                                  (default: soundping's own)
#   BENCH_SIMULATE=1  dry run of this script on the simulated device. It checks the script's own
#                     plumbing and can never print "BENCH GATE: PASS": a simulated run is not a gate.
set -euo pipefail

cd "$(dirname "$0")/.."

# CAL-01: a pair of medians passes when they differ by at most 2.0 frames. The difference is rounded
# to 6 decimals first, so 2.0 passes whatever the float noise and 2.01 fails.
within_two_frames() {
  python3 -c '
import sys
a, b = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if round(abs(a - b), 6) <= 2.0 else 1)
' "$1" "$2"
}

if [ "${1:-}" = "--compare" ]; then
  [ "$#" -eq 3 ] || { echo "usage: scripts/bench.sh --compare <median-frames> <median-frames>" >&2; exit 64; }
  if within_two_frames "$2" "$3"; then
    echo "repeatability PASS: $2 vs $3 differ by at most 2.0 frames"
    exit 0
  fi
  echo "repeatability FAIL: $2 vs $3 differ by more than 2.0 frames"
  exit 3
fi

BENCH_SETUP="${BENCH_SETUP:-scarlett-loop}"
BENCH_BUFFER="${BENCH_BUFFER:-128}"
BENCH_IN_CHANNEL="${BENCH_IN_CHANNEL:-7}"
BENCH_SIMULATE="${BENCH_SIMULATE:-0}"

swift build --product soundping
BIN="$(swift build --show-bin-path)/soundping"

STORE_ARGS=()
if [ -n "${BENCH_STORE:-}" ]; then STORE_ARGS=(--store "$BENCH_STORE"); fi
SIM_ARGS=()
if [ "$BENCH_SIMULATE" = "1" ]; then SIM_ARGS=(--simulate); fi

ROOT="$("$BIN" paths --json ${STORE_ARGS[@]+"${STORE_ARGS[@]}"} | python3 -c 'import json, sys; print(json.load(sys.stdin)["root"])')"
SETUPS_FILE="$("$BIN" paths --json ${STORE_ARGS[@]+"${STORE_ARGS[@]}"} | python3 -c 'import json, sys; print(json.load(sys.stdin)["setups"])')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$ROOT/bench/$STAMP"
mkdir -p "$OUT"
echo "bench folder: $OUT"
echo "setup: $BENCH_SETUP, buffer: $BENCH_BUFFER$([ "$BENCH_SIMULATE" = "1" ] && echo ', SIMULATED dry run')"

# bench_run NAME ARGS... : runs the CLI with --json, keeps stdout in NAME.json, stderr in NAME.err and
# the exit code in NAME.rc. A failing run never stops the bench: the gates read the files afterwards.
bench_run() {
  local name="$1" rc
  shift
  echo
  echo "--- $name"
  echo "    soundping $* --json"
  set +e
  "$BIN" "$@" --json ${STORE_ARGS[@]+"${STORE_ARGS[@]}"} ${SIM_ARGS[@]+"${SIM_ARGS[@]}"} >"$OUT/$name.json" 2>"$OUT/$name.err"
  rc=$?
  set -e
  echo "$rc" >"$OUT/$name.rc"
  python3 - "$OUT/$name.json" "$rc" <<'PYEOF'
import json, sys
path, rc = sys.argv[1], int(sys.argv[2])
try:
    d = json.load(open(path))
except Exception:
    print("    exit %d, no JSON on stdout" % rc)
    sys.exit(0)
if d.get("type") == "error":
    print("    exit %d, %s: %s" % (rc, d.get("code"), d.get("detail")))
elif d.get("type") == "clockSelfTest":
    print("    exit %d, self-test %s: median delta %.3f, p95 |delta| %.3f frames over %d" % (
        rc, "PASS" if d["pass"] else "FAIL", d["medianDeltaFrames"], d["p95AbsDeltaFrames"], d["n"]))
elif d.get("type") == "channelProbe":
    print("    exit %d, chose input channel %s" % (rc, d.get("chosen", {}).get("index")))
else:
    # A run that fails the valid-hit gate (exit 3) still prints a result, with null stats.
    m = d["measured"]
    h = m.get(m.get("headline")) or {}

    def frames(stat):
        value = (h.get(stat) or {}).get("frames")
        return "-" if value is None else "%.2f" % value

    print("    exit %d, valid %s/%s, headline %s median %s frames, jitter %s frames" % (
        rc, h.get("valid", "-"), h.get("n", "-"), m.get("headline"), frames("median"), frames("jitter")))
PYEOF
}

# --- 0. Devices and the setup (D-11) ---------------------------------------------------------
echo
echo "=== 0. devices and setup"
"$BIN" devices --json >"$OUT/devices.json"
echo "    snapshot: $OUT/devices.json"

if python3 - "$SETUPS_FILE" "$BENCH_SETUP" <<'PYEOF'
import json, os, sys
path, name = sys.argv[1], sys.argv[2]
sys.exit(0 if os.path.isfile(path) and name in json.load(open(path)).get("setups", {}) else 1)
PYEOF
then
  echo "    setup '$BENCH_SETUP' exists"
else
  echo "    setup '$BENCH_SETUP' does not exist yet: probing for the loop channel (--in-channel auto)"
  echo "    expected: one channel hears the chirp; on a Scarlett the stereo pair feeds Loop 1 and Loop 2 equally,"
  echo "    so 'inChannelAmbiguous' is normal and falls back to --in-channel $BENCH_IN_CHANNEL"
  bench_run setup-probe run round-trip --output scarlett --input scarlett --in-channel auto --save-setup "$BENCH_SETUP"
  if grep -q '"code":"inChannelAmbiguous"' "$OUT/setup-probe.json"; then
    echo "    ambiguous: saving the setup with the explicit channel $BENCH_IN_CHANNEL (10 hits)"
    bench_run setup-create run round-trip --output scarlett --input scarlett --in-channel "$BENCH_IN_CHANNEL" \
      --buffer "$BENCH_BUFFER" --hits 10 --save-setup "$BENCH_SETUP" --label bench-setup
  fi
fi

# --- 1. Repeatability (CAL-01) ---------------------------------------------------------------
echo
echo "=== 1. repeatability, CAL-01 (two 100-hit runs)"
echo "    expected: 100/100 valid each; medians within 2.0 frames of each other, for the headline and the path"
bench_run repeat-1 run round-trip --setup "$BENCH_SETUP" --buffer "$BENCH_BUFFER" --hits 100 --label bench-repeat-1
bench_run repeat-2 run round-trip --setup "$BENCH_SETUP" --buffer "$BENCH_BUFFER" --hits 100 --label bench-repeat-2

# --- 2. Clock self-test (CAL-03) -------------------------------------------------------------
echo
echo "=== 2. host-clock self-test, CAL-03 (the exit gate)"
echo "    expected: pass true, |median delta| <= 1 frame, p95 |delta| <= 2 frames"
bench_run selftest selftest clock --setup "$BENCH_SETUP" --buffer "$BENCH_BUFFER"

# --- 3. Chirp vs click (D-13) ----------------------------------------------------------------
echo
echo "=== 3. chirp vs click on the same loop"
echo "    expected: the same path within a few frames; compare jitter and valid counts"
bench_run click run round-trip --setup "$BENCH_SETUP" --buffer "$BENCH_BUFFER" --hits 100 --template click --label bench-click

# --- 4. MacBook speakers -> mic (two devices, built-in mic DSP, D-13) ------------------------
echo
echo "=== 4. MacBook speakers -> built-in mic"
echo "    expected: a host-measured path of a few ms to tens of ms; the built-in mic DSP may reject hits"
echo "    (a named preflight error is a result too)"
bench_run speakers-default run round-trip --output "MacBook Pro Speakers" --input "MacBook Pro Microphone" \
  --in-channel 1 --hits 50 --label bench-speakers
bench_run speakers-click run round-trip --output "MacBook Pro Speakers" --input "MacBook Pro Microphone" \
  --in-channel 1 --hits 50 --template click --label bench-speakers-click

# --- 5. Virtual loopback (RESEARCH A1/P3) ----------------------------------------------------
echo
echo "=== 5. virtual loopback"
LOOPBACK="$(python3 - "$OUT/devices.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for dev in d["audio"]:
    if "loopback" in dev["name"].lower() and dev.get("input") and dev.get("output"):
        print(dev["uid"])
        break
PYEOF
)"
if [ -n "$LOOPBACK" ]; then
  echo "    device: $LOOPBACK"
  echo "    expected: path close to 0 frames (a software loop adds no converter latency)"
  bench_run virtual-loopback run round-trip --output "$LOOPBACK" --input "$LOOPBACK" --in-channel 1 \
    --buffer "$BENCH_BUFFER" --hits 50 --label bench-virtual-loopback
else
  echo "    no audio device named like 'Loopback' with both inputs and outputs: skipped"
fi

# --- 6. Table and gates ----------------------------------------------------------------------
echo
echo "=== 6. results"
python3 - "$OUT" "$BENCH_SETUP" "$BENCH_SIMULATE" <<'PYEOF'
import json, os, sys

out, setup, simulated = sys.argv[1], sys.argv[2], sys.argv[3] == "1"


def load(name):
    try:
        return json.load(open(os.path.join(out, name + ".json")))
    except Exception:
        return None


def rc_of(name):
    try:
        return int(open(os.path.join(out, name + ".rc")).read())
    except Exception:
        return None


def f(x, digits=2):
    return "-" if x is None else ("%.*f" % (digits, x))


def frames_of(stat):
    """The frames of a median/jitter stat, or None when the run had no valid hit (null stat)."""
    return (stat or {}).get("frames")


rows = []
for name in ["repeat-1", "repeat-2", "click", "speakers-default", "speakers-click", "virtual-loopback"]:
    d = load(name)
    if d is None:
        continue
    if d.get("type") == "error":
        rows.append((name, "ERROR %s" % d.get("code"), "", "", "", "", "", "", ""))
        continue
    m, rep = d["measured"], d.get("reported") or {}
    head = m.get(m.get("headline")) or {}
    path = m.get("path") or {}
    app = m.get("appRoundTrip")
    io = m.get("ioOffset")
    rows.append((
        name,
        d["parameters"]["templateId"],
        "%s/%s" % (head.get("valid", "-"), head.get("n", "-")),
        "%s %s" % (m.get("headline"), f(frames_of(head.get("median")))),
        f(frames_of(head.get("jitter"))),
        "%s / %s" % (f(rep.get("pathFrames"), 1), f(frames_of(path.get("median")))),
        "%s / %s" % (f(rep.get("appRoundTripFrames"), 1), f(frames_of((app or {}).get("median")))),
        "%s / %s" % (f(rep.get("expectedIoOffsetFrames"), 1), f(frames_of((io or {}).get("median")))),
        d["setup"]["output"]["name"] + " -> " + d["setup"]["input"]["name"],
    ))

header = ("run", "template", "valid", "headline median (frames)", "jitter p5-p95", "path reported / measured",
          "app RT reported / measured", "dIo expected / measured", "devices")
widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
for r in [header] + rows:
    print("  " + "  ".join(str(c).ljust(w) for c, w in zip(r, widths)))

# Gate CAL-01
failures = []
r1, r2 = load("repeat-1"), load("repeat-2")
rep_line = "CAL-01 repeatability: not measured (a repeat run failed)"
if r1 and r2 and r1.get("type") != "error" and r2.get("type") != "error" and rc_of("repeat-1") == 0 and rc_of("repeat-2") == 0:
    def med(r, key):
        return r["measured"][key]["median"]["frames"]
    head1, head2 = med(r1, r1["measured"]["headline"]), med(r2, r2["measured"]["headline"])
    path1, path2 = med(r1, "path"), med(r2, "path")
    dh, dp = round(abs(head1 - head2), 6), round(abs(path1 - path2), 6)
    ok = dh <= 2.0 and dp <= 2.0
    rep_line = "CAL-01 repeatability: headline %.4f vs %.4f (diff %.4f), path %.4f vs %.4f (diff %.4f), limit 2.0 -> %s" % (
        head1, head2, dh, path1, path2, dp, "PASS" if ok else "FAIL")
    if not ok:
        failures.append("CAL-01 repeatability")
else:
    failures.append("CAL-01 repeatability")
print()
print(rep_line)

# Gate CAL-03
st = load("selftest")
if st and st.get("type") == "clockSelfTest" and st.get("pass") is True and rc_of("selftest") == 0:
    print("CAL-03 clock self-test: median delta %.4f, p95 |delta| %.4f frames over %d -> PASS" % (
        st["medianDeltaFrames"], st["p95AbsDeltaFrames"], st["n"]))
else:
    failures.append("CAL-03 clock self-test")
    print("CAL-03 clock self-test: not passed (%s)" % (json.dumps(st)[:200] if st else "no result"))

open(os.path.join(out, "gates.txt"), "w").write(
    rep_line + "\n" + ("FAILED: " + ", ".join(failures) if failures else "all gates passed") + "\n")
open(os.path.join(out, "verdict"), "w").write(("FAIL: " + ", ".join(failures)) if failures else "PASS")
PYEOF

VERDICT="$(cat "$OUT/verdict")"
echo
echo "raw runs: $OUT"
if [ "$BENCH_SIMULATE" = "1" ]; then
  echo "BENCH DRY RUN ($VERDICT on the simulated device; a simulated run is not an exit gate)"
  exit 0
fi
if [ "$VERDICT" = "PASS" ]; then
  echo "BENCH GATE: PASS"
  exit 0
fi
echo "BENCH GATE: FAIL (${VERDICT#FAIL: })"
exit 3
