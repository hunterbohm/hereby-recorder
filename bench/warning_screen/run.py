#!/usr/bin/env python3
"""Run screens over saved packets and append one raw row per check.

  run.py fast synthetic --trials 5 --variants nothink,adaptive --screens haiku [--route cliproxy]
  run.py fast replay --variants nothink,adaptive --screens jev,haiku
  run.py hermes synthetic|replay [--ticks 8,9,13] [--out FILE]
"""
import argparse
import json
import time

from common import DATA, read_rows

import screens


def meta(packet_set, row, trial):
    base = {'set': packet_set, 'trial': trial, 'at': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
            'hits': len(row['packet']['hits']), 'prompt_chars': len(row['prompt'])}
    if packet_set == 'synthetic':
        return dict(base, id=row['case'], problem=row['problem'], expected_kind=row['kind'])
    return dict(base, id=f"tick-{row['tick']:03d}", tick=row['tick'], tick_at=row['at'])


def emit(out, record):
    with open(out, 'a', encoding='utf-8') as stream:
        stream.write(json.dumps(record, ensure_ascii=False) + '\n')
    flag = 'POS' if record.get('screen_positive') else 'neg'
    print(record['id'], record['screen'], flag, record.get('gate'), record.get('seconds'), record.get('error') or '', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('screen', choices=['fast', 'hermes'])
    parser.add_argument('packets', choices=['synthetic', 'replay'])
    parser.add_argument('--trials', type=int, default=1)
    parser.add_argument('--variants', default='nothink')
    parser.add_argument('--ticks', default='')
    parser.add_argument('--route', default='cliproxy', choices=sorted(screens.ROUTES))
    parser.add_argument('--screens', default='jev,haiku')
    parser.add_argument('--out', default=str(DATA / 'raw.jsonl'))
    args = parser.parse_args()
    screens.use_route(args.route)
    rows = read_rows(DATA / f'{args.packets}_packets.jsonl')
    if args.ticks:
        wanted = {int(t) for t in args.ticks.split(',')}
        rows = [r for r in rows if r['tick'] in wanted]
    for trial in range(args.trials):
        for index, row in enumerate(rows):
            if args.screen == 'hermes':
                sid = f"ws-{args.packets[:3]}-{index:03d}-{trial}-{int(time.time())}"
                emit(args.out, dict(meta(args.packets, row, trial), **screens.hermes(row, sid)))
                continue
            chosen = args.screens.split(',')
            runs = ([('jev', None)] if 'jev' in chosen else []) + \
                   ([('haiku', v) for v in args.variants.split(',')] if 'haiku' in chosen else [])
            if (index + trial) % 2:
                runs.reverse()
            for order, (name, variant) in enumerate(runs):
                result = screens.jev(row) if name == 'jev' else screens.haiku(row, variant)
                emit(args.out, dict(meta(args.packets, row, trial), order=order, **result))


if __name__ == '__main__':
    main()
