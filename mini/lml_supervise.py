#!/usr/bin/env python3
import argparse
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from lml_common import append_jsonl, now_local


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def relay(stream, map_path):
    """Pass the chat's stderr through, mapping its session id the moment Hermes prints it: a caller
    killed mid-answer never reads the id, and forget can only delete a session it can name."""
    for line in stream:
        match = re.match(r'Session:\s*([\w-]+)\s*$', line)
        if match and map_path:
            append_jsonl(map_path, {'id': match.group(1), 'at': now_local().isoformat()})
        sys.stderr.write(line)
        sys.stderr.flush()


def supervise(deadline_s, command, lockfd, map_path=None):
    deadline = time.monotonic() + deadline_s
    child = None
    expired = False

    def expire(signum, frame):
        nonlocal expired
        expired = True
        if child is not None:
            kill_group(child.pid)

    signal.signal(signal.SIGALRM, expire)
    signal.signal(signal.SIGTERM, expire)
    signal.setitimer(signal.ITIMER_REAL, max(0.000001, deadline - time.monotonic()))
    try:
        pause = float(os.environ.get('LML_SUPERVISE_PAUSE_SECONDS', '0'))
        ready = os.environ.get('LML_SUPERVISE_READY_FILE')
        if ready:
            Path(ready).write_text(str(os.getpid()), encoding='ascii')
        pause_end = min(deadline, time.monotonic() + pause)
        while not expired and time.monotonic() < pause_end:
            time.sleep(min(0.05, max(0, pause_end - time.monotonic())))
        if expired or time.monotonic() >= deadline:
            return 124
        child = subprocess.Popen(command, start_new_session=True, pass_fds=(lockfd,), stderr=subprocess.PIPE, text=True)
        print(f'lml_child_pid: {child.pid}', file=sys.stderr, flush=True)
        reader = threading.Thread(target=relay, args=(child.stderr, map_path), daemon=True)
        reader.start()
        # A signal can arrive while Popen is still assigning the child.
        if expired or time.monotonic() >= deadline:
            expired = True
            kill_group(child.pid)
        code = child.wait()
        reader.join(timeout=2)
        return 124 if expired else code
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        if child is not None:
            kill_group(child.pid)
            child.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('deadline_s', type=float)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if args.deadline_s <= 0 or not command:
        parser.error('A positive deadline and a command are required')
    try:
        return supervise(args.deadline_s, command, int(os.environ['LML_LOCK_FD']), os.environ.get('LML_HERMES_MAP'))
    except (OSError, ValueError, KeyError):
        print('Meeting supervisor failed.', file=sys.stderr)
        return 127


if __name__ == '__main__':
    code = main()
    raise SystemExit(code if code >= 0 else 128 - code)
