#!/usr/bin/env python3
"""Run the worktree nudge script print-only the way the Hermes cron would: Hermes's interpreter choice,
its secret-scrubbed environment, no stdin and no controlling terminal. Then clean up Hermes sessions."""
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERMES_REPO = Path.home() / '.hermes/candidates/hermes-agent-clean-20260602-212158'
sys.path.insert(0, str(HERMES_REPO))

from common import DATA, REPO, atomic_write, dt  # noqa: E402
import cases  # noqa: E402
import screens  # noqa: E402

import lml_hermes  # noqa: E402
from lml_common import read_jsonl  # noqa: E402

SCRIPT = REPO / 'mini/live_meeting_nudge.py'
NO_TTY_CHECK = REPO / 'bench/warning_screen/no_tty_check.py'
SECRETISH = ('KEY', 'TOKEN', 'SECRET', 'PASSWORD')


def shifted(value, delta):
    return (dt(value) + delta).isoformat()


def build(root, case, now):
    delta = now - cases.NOW
    shutil.rmtree(root, ignore_errors=True)
    rows = []
    for row in cases.transcript(case['lines']):
        parts = [dict(p, t0=shifted(p['t0'], delta), t1=shifted(p['t1'], delta)) for p in row['parts']]
        rows.append(dict(row, parts=parts, ts0=parts[0]['t0'], ts1=parts[-1]['t1'], at=shifted(row['at'], delta)))
    sid = now.strftime('%Y%m%d-%H%M%S-') + case['id'][:2].lower()
    path = root / 'sessions' / sid
    atomic_write(path / 'meta.json', {'v': 1, 'sid': sid, 'state': 'active', 'started_at': shifted(cases.STARTED, delta),
                                      'ended_at': None, 'heartbeat_at': now.isoformat(), 'test': False})
    atomic_write(path / 'live.json', {'v': 1, 'sid': sid, 'at': now.isoformat(), 'finals': rows,
                                      'seq_hi': rows[-1]['seq'], 'partials': {}, 'speech': {}})
    event = dict(cases.EVENT, start=shifted(cases.EVENT['start'], delta), end=shifted(cases.EVENT['end'], delta))
    atomic_write(root / 'schedule.json', {'events': [event]})
    atomic_write(root / 'briefs' / (event['key'] + '.md'), '\n\n'.join(r.render() for r in cases.RECORDS))
    return sid


def cron_spawn(script, args, env_mode, root, llm_cmd=None):
    from cron.scheduler_script import _script_argv
    argv, overlay, error = _script_argv(Path(script))
    if argv is None:
        raise SystemExit(error)
    if env_mode == 'hermes':
        from tools.environments.local import build_subprocess_env
        env = build_subprocess_env(strip_launch_profile=True)
        env.update(overlay)
    else:
        env = {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin', **overlay}
    env['LML_ROOT'] = str(root)
    if llm_cmd:
        env['LML_LLM_CMD'] = llm_cmd
    names = sorted(k for k in env if any(s in k.upper() for s in SECRETISH))
    start = time.monotonic()
    done = subprocess.run(argv + args, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env,
                          cwd=str(Path(script).parent), start_new_session=True, timeout=180)
    return {'argv0': argv[0], 'env_secretish_names': names, 'path': env.get('PATH'),
            'openrouter_key_in_env': 'OPENROUTER_API_KEY' in env, 'returncode': done.returncode,
            'seconds': round(time.monotonic() - start, 2), 'stdout': done.stdout.strip(), 'stderr': done.stderr.strip()}


LAZY_FIX = 'env -u HERMES_DISABLE_LAZY_INSTALLS hermes'


def main():
    env_mode = sys.argv[1] if len(sys.argv) > 1 else 'hermes'
    report = {'env_mode': env_mode, 'tty': cron_spawn(NO_TTY_CHECK, [], env_mode, DATA)}
    for llm_cmd in (None, LAZY_FIX):
        for case_id in ('P1-wrong-retainer', 'B2-smalltalk-numbers'):
            case = next(c for c in cases.CASES if c['id'] == case_id)
            root = DATA / f'cron-proof-test-{env_mode}'
            sid = build(root, case, datetime.now().astimezone())
            run = cron_spawn(SCRIPT, ['--print'], env_mode, root, llm_cmd)
            run['llm_cmd'] = llm_cmd or 'hermes (as deployed)'
            run['nudge_log'] = [{k: e.get(k) for k in ('stage', 'gate')} for e in read_jsonl(root / f'nudges/{sid}.jsonl')]
            run['hermes_ids'] = len({e['id'] for e in read_jsonl(root / f'hermes_map/{sid}.jsonl')})
            remaining, incomplete = lml_hermes.forget(root, sid)
            run['cleanup'] = {'remaining': len(remaining), 'incomplete': bool(incomplete),
                              'sessions_left_in_store': screens.sessions_left(sid)}
            for key in ('argv0', 'env_secretish_names', 'path'):
                report.setdefault(key, run.pop(key))
            report[f"{case_id} / {run['llm_cmd']}"] = run
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
