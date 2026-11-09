#!/usr/bin/env python3
"""Merge raw rows into one file for the report and the published raw artifact.

Drops OpenRouter rows that failed with the 402 billing error (counted, not hidden), restores full prompt token
counts on early CLIProxy rows whose usage put the prompt in cache fields, and strips model text from replay rows."""
import json
from collections import Counter

from common import DATA, read_rows, write_jsonl

from screens import HAIKU_PRICE

SOURCES = ('raw-openrouter.jsonl', 'raw.jsonl', 'raw-hermes.jsonl', 'raw-hermes-replay.jsonl')


def main():
    counts = json.loads((DATA / 'token_counts.json').read_text())
    rows, dropped = [], Counter()
    for name in SOURCES:
        path = DATA / name
        if not path.exists():
            continue
        for row in read_rows(path):
            row['source_file'] = name
            if row['screen'].startswith('haiku') and not row.get('route'):
                row['route'] = 'openrouter'
            if name == 'raw-openrouter.jsonl' and row.get('error') == 'api':
                dropped[(row['set'], row['screen'])] += 1
                continue
            if name == 'raw-openrouter.jsonl' and row['screen'] == 'jev' and row['set'] == 'replay':
                dropped[('replay', 'jev-partial-rerun')] += 1
                continue
            if row.get('route') == 'cliproxy' and row.get('input_tokens') is not None and row['input_tokens'] < 100:
                row['input_tokens'] = counts[row['id']]['claude-haiku-5-5']
                row['input_tokens_source'] = 'count_tokens'
                row['cost_usd'] = (row['input_tokens'] * HAIKU_PRICE[0] + row['output_tokens'] * HAIKU_PRICE[1]) / 1e6
            if row['set'] == 'replay':
                row.pop('raw_text', None)
            rows.append(row)
    write_jsonl(DATA / 'warning-eval-raw.jsonl', rows)
    print(json.dumps({'rows': len(rows), 'by': Counter(f"{r['set']}:{r['screen']}:{r.get('route', '')}" for r in rows),
                      'dropped': {f'{a}:{b}': n for (a, b), n in dropped.items()}}, indent=1, default=str))


if __name__ == '__main__':
    main()
