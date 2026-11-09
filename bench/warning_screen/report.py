#!/usr/bin/env python3
"""Summarize raw rows: latency, tokens, cost, synthetic confusion matrix, replay screen and gate results."""
import json
import statistics
import sys
from collections import Counter, defaultdict

from common import DATA, read_rows


def pct(values, q):
    values = sorted(values)
    if not values:
        return None
    index = min(len(values) - 1, max(0, round(q * (len(values) - 1))))
    return values[index]


def mean(values):
    values = [v for v in values if v is not None]
    return statistics.fmean(values) if values else None


def label(row):
    return row['screen'] + ('/' + row['route'] if row.get('route') else '')


def summarize(rows, replay_hours, replay_packets):
    groups = defaultdict(list)
    for row in rows:
        groups[(label(row), row['set'])].append(row)
    out = {}
    for (name, packet_set), items in sorted(groups.items()):
        ok = [r for r in items if not r.get('error')]
        seconds = [r['seconds'] for r in ok]
        entry = {'n': len(items), 'errors': dict(Counter(r['error'] for r in items if r.get('error'))),
                 'p50_s': pct(seconds, .5), 'p95_s': pct(seconds, .95), 'max_s': max(seconds, default=None),
                 'mean_input_tokens': mean([r.get('input_tokens') for r in ok]),
                 'mean_output_tokens': mean([r.get('output_tokens') for r in ok]),
                 'mean_cost_usd': mean([r.get('cost_usd') for r in ok])}
        if packet_set == 'synthetic':
            tp = sum(1 for r in ok if r['problem'] and r['screen_positive'] and not r['gate'])
            fn = sum(1 for r in ok if r['problem'] and not (r['screen_positive'] and not r['gate']))
            fp = sum(1 for r in ok if not r['problem'] and r['screen_positive'] and not r['gate'])
            tn = sum(1 for r in ok if not r['problem'] and not (r['screen_positive'] and not r['gate']))
            raw_fp = sum(1 for r in ok if not r['problem'] and r['screen_positive'])
            entry.update(tp=tp, fp=fp, fn=fn, tn=tn, benign_flagged_before_gate=raw_fp,
                         gate_reasons_on_benign=dict(Counter(r['gate'] for r in ok if not r['problem'] and r['screen_positive'])),
                         misses=sorted(Counter(r['id'] for r in ok if r['problem'] and not (r['screen_positive'] and not r['gate'])).items()),
                         false_alarms=sorted(Counter(r['id'] for r in ok if not r['problem'] and r['screen_positive'] and not r['gate']).items()))
        else:
            positives = [r for r in ok if r['screen_positive']]
            passing = [r for r in positives if not r['gate']]
            fallback = len(items) - len(ok)
            entry.update(screen_positive=len(positives), gate_pass=len(passing),
                         gate_reasons=dict(Counter(r['gate'] for r in positives)),
                         strong_calls_implied=len(passing) + fallback,
                         checks_per_hour=round(replay_packets / replay_hours, 2))
            if entry['mean_cost_usd'] is not None:
                entry['cost_per_meeting_hour_usd'] = entry['mean_cost_usd'] * replay_packets / replay_hours
            entry['strong_calls_per_hour'] = round(entry['strong_calls_implied'] * (replay_packets / len(items)) / replay_hours, 2)
        out[f'{name} [{packet_set}]'] = entry
    return out


def fit(xs, ys):
    n = len(xs)
    if n < 3:
        return None
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    if not sxx:
        return None
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    intercept = my - slope * mx
    residual = sum((y - intercept - slope * x) ** 2 for x, y in zip(xs, ys))
    total = sum((y - my) ** 2 for y in ys)
    return {'intercept_s': round(intercept, 3), 'seconds_per_output_token': round(slope, 5),
            'r2': round(1 - residual / total, 3) if total else None, 'n': n}


def limiters(rows):
    out = {}
    groups = defaultdict(list)
    for row in rows:
        if not row.get('error'):
            groups[(label(row), row['set'])].append(row)
    for (name, packet_set), items in sorted(groups.items()):
        key = f'{name} [{packet_set}]'
        if name.startswith('haiku'):
            api = [r['seconds'] - r['credential_seconds'] for r in items]
            out[key] = {'credential_s_mean': round(statistics.fmean(r['credential_seconds'] for r in items), 3),
                        'api_s_p50': round(pct(api, .5), 3),
                        'credential_share_of_p50': round(statistics.median(r['credential_seconds'] / r['seconds'] for r in items), 3),
                        'api_vs_output_tokens': fit([r['output_tokens'] for r in items], api),
                        'output_tokens_p50': pct([r['output_tokens'] for r in items], .5),
                        'input_tokens_p50': pct([r['input_tokens'] for r in items], .5)}
        elif name == 'jev':
            by = defaultdict(list)
            for r in items:
                by[min(r['jev_requests'], 9)].append(r['seconds'])
            out[key] = {f'requests={k}': {'n': len(v), 'p50_s': round(pct(v, .5), 3)} for k, v in sorted(by.items())}
            out[key]['unknown_rate'] = round(sum(1 for r in items if r.get('jev_unknown')) / len(items), 3)
        elif name == 'hermes':
            overhead = [r['seconds'] - r['session_seconds'] for r in items if r.get('session_seconds') is not None]
            out[key] = {'wall_minus_session_s_p50': round(pct(overhead, .5), 2) if overhead else None,
                        'session_s_p50': pct([r['session_seconds'] for r in items if r.get('session_seconds')], .5),
                        'api_calls_mean': mean([r.get('api_call_count') for r in items]),
                        'reasoning_tokens_mean': mean([r.get('reasoning_tokens') for r in items]),
                        'cache_read_mean': mean([r.get('cache_read_tokens') for r in items]),
                        'cache_write_mean': mean([r.get('cache_write_tokens') for r in items]),
                        'hermes_estimated_cost_mean': mean([r.get('hermes_estimated_cost_usd') for r in items]),
                        'billing_modes': dict(Counter(r.get('billing_mode') for r in items))}
    return out


def main():
    files = sys.argv[1:] or ['raw.jsonl']
    rows = [r for f in files for r in read_rows(DATA / f)]
    summary = json.loads((DATA / 'replay_summary.json').read_text())
    result = summarize(rows, summary['session_hours'], summary['packets'])
    print(json.dumps({'screens': result, 'limiters': limiters(rows)}, indent=1))


if __name__ == '__main__':
    main()
