"""Time status.json generation: status() in process, then the whole live-meeting-sync-status command.

Usage: LML_ROOT=<copy of ~/.local/state/live-meeting> python3 bench/status_timing.py [runs]
Reads the vault and Hermes state where status() normally does. Writes heartbeat.json and status.json
only under LML_ROOT, so it refuses the production root.
"""
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

MINI = Path(__file__).resolve().parents[1] / 'mini'
sys.path.insert(0, str(MINI))

from lml_common import now_local, production_root, root_path
from lml_status import status


def report(label, samples):
    ordered = sorted(samples)
    p90 = ordered[max(0, round(len(ordered) * 0.9) - 1)]
    print(f'{label}: n={len(ordered)} first={samples[0]:.1f} median={statistics.median(ordered):.1f} '
          f'min={ordered[0]:.1f} p90={p90:.1f} max={ordered[-1]:.1f} ms')


def timed(action):
    start = time.perf_counter()
    action()
    return (time.perf_counter() - start) * 1000


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    root = root_path()
    if root.resolve() == production_root().resolve():
        sys.exit('Point LML_ROOT at a copy: the command writes heartbeat.json and status.json there.')
    beat = json.dumps({'at': now_local().isoformat(), 'app_version': 'bench', 'state': 'idle', 'sid': None,
                       'mic_ok': True, 'audio_ok': True}).encode()
    inline = [timed(lambda: status(root, now_local())) for _ in range(runs)]
    command = [timed(lambda: subprocess.run([str(MINI / 'live-meeting-sync-status')], input=beat,
                                            capture_output=True, check=True)) for _ in range(runs)]
    report('status()', inline)
    report('live-meeting-sync-status', command)
    print(json.dumps(status(root, now_local()), ensure_ascii=False))


if __name__ == '__main__':
    main()
