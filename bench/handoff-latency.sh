#!/bin/bash
# Usage: handoff-latency.sh TRUNK_REV [RUNS] [OUT_DIR]
# Times the gap from a fixture session's end to the done command's start, interleaving trunk (the old private settings: mini
# mode with a Hermes stub), this checkout in mini mode with the same settings, and this checkout in local-only mode.
# Prints seconds per run and the p50 and p95 of each, and keeps the raw lines in OUT_DIR/latency.txt.
set -euo pipefail
trunk_rev="$1"; runs="${2:-20}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="${3:-$(mktemp -d /tmp/l2-latency.XXXXXX)}"
mkdir -p "$out"
trunk="$out/trunk"
mkdir -p "$trunk"
git -C "$repo" archive "$trunk_rev" | tar -x -C "$trunk"
# Trunk has no local-only done command, so its copy of the probe drops that mode.
sed '/case "local":/,+1d' "$repo/mac/Tests/LMLCoreTests/HandoffLatencyProbe.swift" > "$trunk/mac/Tests/LMLCoreTests/HandoffLatencyProbe.swift"
cat > "$out/stamp.py" <<PY
#!$(command -v python3)
import os, time
open(os.environ['LML_PROBE_STAMP'], 'w').write(repr(time.time()))
PY
chmod +x "$out/stamp.py"
mkdir -p "$out/bin"; cp "$out/stamp.py" "$out/bin/hermes"
run_probe() { "$1/mac/scripts/test.sh" --filter HandoffLatencyProbe "${@:2}"; }
run_probe "$trunk" >/dev/null 2>&1; run_probe "$repo" >/dev/null 2>&1
: > "$out/latency.txt"
probe() {
    local mode="$1" checkout="$2" label="$3" work
    work="$(mktemp -d "$out/run.XXXXXX")"
    mkdir -p "$work/xdg/hereby" "$work/mini-root"
    printf 'done_command = "hermes cron run listener-meeting-processing"\n' > "$work/xdg/hereby/recorder.toml"
    LML_PROBE_MODE="$mode" LML_PROBE_LABEL="$label" LML_PROBE_WORK="$work" LML_PROBE_STAMP="$work/stamp" LML_PROBE_OUT="$out/latency.txt" \
        LML_PROBE_MINI="$checkout/mini" LML_PROBE_STUB="$out/stamp.py" LML_ROOT="$work/mini-root" XDG_CONFIG_HOME="$work/xdg" \
        PATH="$out/bin:$PATH" run_probe "$checkout" --skip-build >"$work/log" 2>&1 || { cat "$work/log" >&2; exit 1; }
    rm -rf "$work"
}
for i in $(seq 1 "$runs"); do
    probe mini "$trunk" trunk
    probe mini "$repo" head-mini
    probe local "$repo" head-local
done
python3 - "$out/latency.txt" <<'PY'
import collections, sys
values = collections.defaultdict(list)
for line in open(sys.argv[1]):
    label, seconds = line.split()[:2]
    values[label].append(float(seconds))
def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if len(xs) > 1 else xs[0]
for label in ('trunk', 'head-mini', 'head-local'):
    xs = values[label]
    print(f'{label}: n={len(xs)} p50={pct(xs, .5):.3f}s p95={pct(xs, .95):.3f}s max={max(xs):.3f}s')
trunk95 = pct(values['trunk'], .95)
failed = False
for label in ('head-mini', 'head-local'):
    over = pct(values[label], .95) - trunk95
    failed |= over > 1
    print(f'{label} vs trunk at p95: {over:+.3f}s -> {"FAIL" if over > 1 else "PASS"}')
sys.exit(1 if failed else 0)
PY
