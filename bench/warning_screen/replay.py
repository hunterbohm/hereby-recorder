#!/usr/bin/env python3
"""Replay the Oct 23 session minute by minute through the real tick and save every packet it would send."""
import json
import shutil
import sys
from collections import Counter
from datetime import timedelta
from pathlib import Path

from common import DATA, atomic_write, capture_tick, dt, write_jsonl

from lml_attribute import attribute
from lml_common import read_jsonl

SID = '20261023-163204-440d'
PRODUCTION = Path.home() / '.local/state/live-meeting'
BRIEF_KEY = '011d80iutr1muco7gsqsi4ae9k_20261023T200000Z::2026-10-23T15:00:00-05:00'
EVENT = {'key': BRIEF_KEY, 'start': '2026-10-23T16:30:00-05:00', 'end': '2026-10-23T18:30:00-05:00',
         'has_conference': True, 'attendee_count': 2}


def word_intervals(rows, channel, since, until):
    spans = []
    for row in rows:
        if row['ch'] != channel:
            continue
        for part in row['parts']:
            start = dt(part['t0'])
            for a, b in part.get('words') or []:
                lo, hi = start + timedelta(seconds=a), start + timedelta(seconds=b)
                if hi >= since and lo <= until:
                    spans.append([lo, hi])
    spans.sort()
    merged = []
    for lo, hi in spans:
        if merged and lo <= merged[-1][1] + timedelta(seconds=0.3):
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return [[a.isoformat(), b.isoformat()] for a, b in merged]


def proxy_speech(rows, now):
    since = now - timedelta(seconds=900)
    return {ch: word_intervals(rows, ch, since, now) for ch in ('me', 'them')}


def labels(rows, speech):
    finals = [dict(r, partial=False) for r in rows]
    return Counter((p['seq'], p['t0'], p['ch']) for p in attribute(finals, speech))


def calibrate(source):
    live = json.loads((source / 'live.json').read_text())
    now = dt(live['at'])
    finals = live['finals']
    real = labels(finals, live['speech'])
    proxy = labels(finals, proxy_speech(finals, now))
    parts = {(seq, t0) for seq, t0, _ in real} | {(seq, t0) for seq, t0, _ in proxy}
    def label(counter, key):
        found = [ch for (seq, t0, ch) in counter if (seq, t0) == key]
        return found[0] if found else 'dropped'
    pairs = Counter((label(real, k), label(proxy, k)) for k in parts)
    agree = sum(n for (a, b), n in pairs.items() if a == b)
    return {'window_start': (now - timedelta(seconds=900)).isoformat(), 'window_end': now.isoformat(),
            'parts': len(parts), 'agree': agree, 'confusion': {f'{a}->{b}': n for (a, b), n in sorted(pairs.items())}}


def main():
    source = DATA / 'source'
    if not source.exists():
        source.mkdir(parents=True, mode=0o700)
        for name in ('meta.json', 'live.json', 'transcript.jsonl'):
            shutil.copy2(PRODUCTION / 'sessions' / SID / name, source / name)
        shutil.copy2(PRODUCTION / 'briefs' / (BRIEF_KEY + '.md'), source / 'brief.md')
    root = DATA / 'replay-test'
    shutil.rmtree(root, ignore_errors=True)
    atomic_write(root / 'schedule.json', {'events': [EVENT]})
    atomic_write(root / 'briefs' / (BRIEF_KEY + '.md'), (source / 'brief.md').read_text())
    meta = json.loads((source / 'meta.json').read_text())
    rows = read_jsonl(source / 'transcript.jsonl')
    started, ended = dt(meta['started_at']), dt(meta['ended_at'])
    session = root / 'sessions' / SID
    packets, ticks, now = [], 0, started + timedelta(seconds=60)
    while now <= ended + timedelta(seconds=60):
        finals = [r for r in rows if dt(r['at']) <= now and dt(r['ts1']) >= now - timedelta(seconds=900)]
        atomic_write(session / 'meta.json', dict(meta, state='active', ended_at=None, heartbeat_at=now.isoformat()))
        atomic_write(session / 'live.json', {'v': 1, 'sid': SID, 'at': now.isoformat(), 'finals': finals,
                                             'seq_hi': max([r['seq'] for r in finals], default=0),
                                             'partials': {}, 'speech': proxy_speech(finals, now)})
        for packet in capture_tick(root, now.astimezone(dt(EVENT['start']).tzinfo)):
            packet['tick'] = ticks
            packets.append(packet)
        ticks += 1
        now += timedelta(seconds=60)
    write_jsonl(DATA / 'replay_packets.jsonl', packets)
    hours = (ended - started).total_seconds() / 3600
    summary = {'ticks': ticks, 'packets': len(packets), 'session_hours': round(hours, 3),
               'packets_per_hour': round(len(packets) / hours, 2),
               'mean_hits': round(sum(len(p['packet']['hits']) for p in packets) / max(1, len(packets)), 2),
               'mean_prompt_chars': round(sum(len(p['prompt']) for p in packets) / max(1, len(packets))),
               'calibration': calibrate(source)}
    (DATA / 'replay_summary.json').write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))


if __name__ == '__main__':
    sys.exit(main())
