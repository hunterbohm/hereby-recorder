import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'mini'))
DATA = REPO / 'bench/data/warning_screen'

import live_meeting_nudge  # noqa: E402
from lml_common import atomic_write, dt, read_json  # noqa: E402
from lml_records import records  # noqa: E402

NEGATIVE = json.dumps({'nudge': False})


def capture_tick(root, now):
    """Run the real tick with call() replaced by a recorder that answers no-nudge.

    Returns the packets tick would have sent, each with what gate() needs to judge a reply."""
    root = Path(root)
    captured = []
    session_dirs = list((root / 'sessions').glob('*'))
    sid = session_dirs[0].name
    state = read_json(root / 'nudges' / (sid + '.state.json'), {'cursor': 0})
    finals = read_json(session_dirs[0] / 'live.json', {}).get('finals', [])
    new_seqs = sorted({r['seq'] for r in finals if r['seq'] > state['cursor']})

    def recorder(root_, sid_, prompt, *, timeout, runner, hermes_runner, deliver):
        packet = json.loads(prompt[len(live_meeting_nudge.INSTRUCTIONS):])
        captured.append({'at': now.isoformat(), 'sid': sid_, 'today': now.date().isoformat(),
                         'new_seqs': new_seqs, 'prompt': prompt, 'packet': packet, 'timeout': timeout})
        return deliver(NEGATIVE)

    original = live_meeting_nudge.call
    live_meeting_nudge.call = recorder
    try:
        live_meeting_nudge.tick(root=root, now=now)
    finally:
        live_meeting_nudge.call = original
    return captured


def judge(candidate, row):
    from datetime import date
    from lml_records import Record
    record_items = [Record(**r) for r in row['packet']['records']]
    return live_meeting_nudge.gate(candidate if isinstance(candidate, dict) else {}, row['packet']['finals'],
                                   set(row['new_seqs']), record_items, date.fromisoformat(row['today']))


def write_jsonl(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(path, 'w', encoding='utf-8') as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')
    path.chmod(0o600)


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text(encoding='utf-8').splitlines() if line.strip()]
