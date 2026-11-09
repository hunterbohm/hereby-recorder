#!/bin/bash
# Usage: smoke-run.sh [LML_BINARY]
# Runs `lml run --test` under the AppKit loop with synthesized audio files (no microphone, no system audio,
# nothing played aloud), once to --duration and once stopped by SIGTERM, and checks each session closed with rows.
# A third run, offline, pauses and then stops over the control socket and checks that Stop ends the pause.
set -euo pipefail
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
lml="${1:-$package_dir/.build/debug/lml}"
work="$(mktemp -d /tmp/lml-smoke.XXXXXX)"
cleanup() {
    for root in "$work"/run-*; do
        for socket in "$root"/ssh-*; do
            [[ -S "$socket" ]] && /usr/bin/ssh -o ControlPath="$socket" -O exit "${socket##*/ssh-}" 2>/dev/null || true
        done
    done
    rm -rf "$work"
}
trap cleanup EXIT
say -v Samantha -o "$work/them.aiff" "Thanks for joining. The renewal moves to Friday."
say -v Daniel -o "$work/me.aiff" "Great, I will send the draft contract tonight."
check() {
    python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
root, label = pathlib.Path(sys.argv[1]), sys.argv[2]
(session,) = list((root / 'sessions').iterdir())
meta = json.loads((session / 'meta.json').read_text())
rows = [json.loads(line) for line in (session / 'transcript.jsonl').read_text().splitlines()]
channels = sorted({row['ch'] for row in rows})
print(f"{label}: state={meta['state']} rows={len(rows)} channels={channels}")
sys.exit(0 if meta['state'] == 'closed' and channels == ['me', 'them'] else 1)
PY
}
mkdir -m 700 "$work/run-duration"
"$lml" run --test --root "$work/run-duration" --no-control --me-file "$work/me.aiff" --them-file "$work/them.aiff" --duration 20 >/dev/null 2>&1
check "$work/run-duration" "duration exit=0"
mkdir -m 700 "$work/run-signal"
"$lml" run --test --root "$work/run-signal" --no-control --me-file "$work/me.aiff" --them-file "$work/them.aiff" >/dev/null 2>&1 &
pid=$!
sleep 15
kill -TERM "$pid"
wait "$pid"
check "$work/run-signal" "sigterm exit=$?"
mkdir -m 700 "$work/run-pause-stop"
"$lml" run --test --root "$work/run-pause-stop" --no-sync --me-file "$work/me.aiff" --them-file "$work/them.aiff" --duration 30 >/dev/null 2>&1 &
pid=$!
sleep 12
python3 - "$work/run-pause-stop" <<'PY'
import json, pathlib, socket, sys, time
root = pathlib.Path(sys.argv[1])
def send(action):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(str(root / 'control.sock'))
        s.sendall(json.dumps({'action': action}).encode() + b'\n')
        return s.makefile().readline().strip()
paused = send('pause')
held = (root / 'pause.json').exists()
stopped = send('stop')
time.sleep(1)
cleared = not (root / 'pause.json').exists()
print(f"pause-stop: pause={paused} paused={held} stop={stopped} pause_cleared={cleared}")
sys.exit(0 if (paused, held, stopped, cleared) == ('pause', True, 'stop', True) else 1)
PY
wait "$pid"
