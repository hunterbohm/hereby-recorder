#!/usr/bin/env python3
"""Pick 20 replay packets for the Hermes path: every packet a cheap screen flagged through the gate (up to 10),
then fill by hit-count stratum (1, 2, 3+) in proportion to stratum size, evenly spaced in time within each."""
import json
import sys

from common import DATA, read_rows

SIZE = 20


def evenly(items, count):
    if count <= 0 or not items:
        return []
    if count >= len(items):
        return list(items)
    step = len(items) / count
    return [items[int(i * step + step / 2)] for i in range(count)]


def main():
    packets = read_rows(DATA / 'replay_packets.jsonl')
    raw = [r for r in read_rows(DATA / (sys.argv[1] if len(sys.argv) > 1 else 'raw.jsonl')) if r['set'] == 'replay']
    flagged = sorted({r['tick'] for r in raw if r.get('screen_positive') and not r.get('gate') and not r.get('error')})
    chosen = evenly(flagged, min(len(flagged), SIZE // 2))
    rest = [p for p in packets if p['tick'] not in chosen]
    strata = {'1': [p['tick'] for p in rest if len(p['packet']['hits']) == 1],
              '2': [p['tick'] for p in rest if len(p['packet']['hits']) == 2],
              '3+': [p['tick'] for p in rest if len(p['packet']['hits']) >= 3]}
    room = SIZE - len(chosen)
    total = sum(len(v) for v in strata.values())
    quota = {k: round(room * len(v) / total) for k, v in strata.items()}
    quota[max(quota, key=lambda k: len(strata[k]))] += room - sum(quota.values())
    picks = {k: evenly(v, quota[k]) for k, v in strata.items()}
    ticks = sorted(chosen + [t for v in picks.values() for t in v])
    print(json.dumps({'flagged_by_cheap_screens': flagged, 'flagged_included': chosen,
                      'strata_sizes': {k: len(v) for k, v in strata.items()}, 'strata_picks': picks,
                      'ticks': ticks, 'n': len(ticks)}, indent=1))


if __name__ == '__main__':
    main()
