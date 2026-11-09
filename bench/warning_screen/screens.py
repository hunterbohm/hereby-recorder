import json
import re
import sqlite3
import subprocess
import sys
import time
from datetime import date, timedelta
from pathlib import Path

from common import DATA, judge

import lml_hermes
import lml_screen
from live_meeting_nudge import salient
from lml_common import dt, read_jsonl
from lml_numbers import numbers, same_unit

HAIKU_PRICE = (0.10, 0.50)
OPUS_PRICE = {'input': 4.00, 'output': 20.00, 'cache_read': 0.20, 'cache_write': 5.00}
JEV_PRICE_INPUT = 0.042
JEV_BATCH = Path.home() / 'command-center/scripts/jev/batch.py'
HERMES_DB = Path.home() / '.hermes/state.db'
ROUTES = {
    'openrouter': {'model': 'anthropic/claude-haiku-5.5', 'base_url': 'https://openrouter.ai/api',
                   'secret': 'OPENROUTER_API_KEY', 'auth': 'bearer'},
    'cliproxy': dict(lml_screen.SETTINGS),
}
ROUTE = {'name': 'openrouter'}


def use_route(name):
    ROUTE['name'] = name
    lml_screen.settings = lambda: ROUTES[name]


HAIKU_VARIANTS = {'nothink': {'thinking': {'type': 'disabled'}, 'max_tokens': 1024}, 'adaptive': {}}


def outcome(candidate, row):
    positive = isinstance(candidate, dict) and candidate.get('nudge') is True
    return {'screen_positive': positive, 'gate': judge(candidate, row) if positive else 'no_nudge',
            'kind': candidate.get('kind') if positive else None,
            'current_quote': candidate.get('current_quote') if positive else None,
            'record_quote': candidate.get('record_quote') if positive else None}


def haiku(row, variant='nothink'):
    prompt = lml_hermes.header() + row['prompt']
    key_start = time.monotonic()
    lml_screen.credential(lml_screen.settings()['secret'], 15)
    key_seconds = time.monotonic() - key_start
    start = time.monotonic()
    message = candidate = error = None
    try:
        message = lml_screen.ask(prompt, options=HAIKU_VARIANTS[variant])
        candidate = lml_screen.parse(message)
    except lml_screen.ScreenFailed as exc:
        error = exc.reason
    seconds = time.monotonic() - start
    usage = getattr(message, 'usage', None)
    cached = (getattr(usage, 'cache_read_input_tokens', 0) or 0, getattr(usage, 'cache_creation_input_tokens', 0) or 0)
    tokens_in = getattr(usage, 'input_tokens', 0) + sum(cached) if usage else None
    tokens_out = getattr(usage, 'output_tokens', None)
    cost = (tokens_in * HAIKU_PRICE[0] + tokens_out * HAIKU_PRICE[1]) / 1e6 if usage else None
    raw = ''.join(b.text for b in message.content if b.type == 'text')[:400] if error == 'format' else None
    return {'screen': 'haiku-' + variant, 'route': ROUTE['name'], 'seconds': round(seconds, 3), 'credential_seconds': round(key_seconds, 3),
            'input_tokens': tokens_in, 'output_tokens': tokens_out, 'cost_usd': cost, 'error': error, 'raw_text': raw,
            'stop_reason': getattr(message, 'stop_reason', None), 'cache_read_tokens': cached[0] if usage else None,
            'generation_id': getattr(message, 'id', None), **outcome(candidate, row)}


def sentences(text):
    return [s.strip() for s in re.split(r'[.;\n]+', text) if s.strip()]


def pair_candidates(row):
    packet, today = row['packet'], date.fromisoformat(row['today'])
    parts = [p for p in packet['finals'] if p['ch'] in {'me', 'them'} and not p['partial'] and not p.get('boundary')]
    seen = set()
    for hit in packet['hits']:
        if (hit['seq'], hit['t0']) in seen:
            continue
        seen.add((hit['seq'], hit['t0']))
        lead = dt(hit['t0']) - timedelta(seconds=20)
        nearby = salient(' '.join(p['text'] for p in parts if lead <= dt(p['t1']) and dt(p['t0']) <= dt(hit['t1'])))
        for record in packet['records']:
            if record['kind'] not in {'prior_meeting', 'action_item', 'commitment', 'email'}:
                continue
            if record['date'] >= row['today']:
                continue
            scored = [(len(nearby & salient(s)), s) for s in sentences(record['text'])]
            overlap, sentence = max(scored, default=(0, ''))
            if not overlap:
                continue
            pairs = [(a, b) for a in numbers(hit['text']) for b in numbers(sentence) if same_unit(a, b)]
            due = record.get('due') or ''
            if any(a.value != b.value for a, b in pairs):
                kind = 'wrong_number'
            elif record['kind'] == 'action_item' and due and date.fromisoformat(due) <= today:
                kind = 'missed_commitment'
            else:
                kind = 'contradiction'
            subject = ' '.join(sorted(nearby & salient(sentence)))
            yield {'nudge': True, 'kind': kind, 'current_quote': hit['text'], 'current_seq': hit['seq'],
                   'record_quote': sentence, 'record_source': record['source'], 'record_date': record['date'],
                   'subject': subject, 'text': ('Possible ' + kind.replace('_', ' ') + ': ' + subject)[:160]}


def jev_case(candidate, row):
    if candidate['kind'] == 'missed_commitment':
        hit = next(p for p in row['packet']['hits'] if p['seq'] == candidate['current_seq'])
        return {'profile': 'commitment', 'state': {'messages': [
            {'speaker': 'me', 'text': f"Action item from the {candidate['record_date']} meeting: {candidate['record_quote']}"},
            {'speaker': 'me' if hit['ch'] == 'me' else 'other', 'text': candidate['current_quote']}]}}
    return {'profile': 'quality', 'state': {'claim': candidate['current_quote'], 'source': candidate['record_quote']}}


def jev_positive(case, result):
    choice = (result.get('decisions') or {}).get('state' if case['profile'] == 'commitment' else 'grounding', {}).get('choice')
    if case['profile'] == 'commitment':
        return choice in {'reply', 'waiting'}, choice
    return choice == 'unsupported', choice


def jev(row, deadline_s=10):
    start = time.monotonic()
    built = list(pair_candidates(row))
    survivors = [c for c in built if not judge(c, row)]
    cases = [jev_case(c, row) for c in survivors]
    results, error, tokens_in = [], None, 0
    for offset in range(0, len(cases), 8):
        chunk = cases[offset:offset + 8]
        remaining = deadline_s - (time.monotonic() - start)
        try:
            done = subprocess.run([sys.executable, str(JEV_BATCH), "--no-log"], input=json.dumps(chunk), text=True,
                                  capture_output=True, timeout=max(0.5, remaining))
            results.extend(json.loads(done.stdout)['results'])
        except subprocess.TimeoutExpired:
            error = 'timeout'
            break
        except (ValueError, KeyError):
            error = 'batch'
            break
    seconds = time.monotonic() - start
    labels, positive, unknown = [], None, False
    for candidate, case, result in zip(survivors, cases, results):
        hit, choice = jev_positive(case, result)
        labels.append(choice)
        unknown = unknown or bool(result.get('fallback'))
        tokens_in += result.get('input_tokens') or 0
        if hit and positive is None:
            positive = candidate
    if results and any(r.get('input_tokens') is None and not r.get('reused') for r in results):
        tokens_in = None
    row_out = {'screen': 'jev', 'seconds': round(seconds, 3), 'pairs_built': len(built), 'pairs_gated': len(survivors),
               'jev_requests': sum(1 for r in results if not r.get('reused')), 'labels': labels,
               'jev_unknown': unknown, 'input_tokens': tokens_in, 'output_tokens': 0 if results else None,
               'cost_usd': (tokens_in or 0) * JEV_PRICE_INPUT / 1e6 if tokens_in is not None else None,
               'error': error}
    row_out.update(outcome(positive, row))
    return row_out


def hermes_usage(ids):
    if not ids:
        return {}
    db = sqlite3.connect(f'file:{HERMES_DB}?mode=ro', uri=True, timeout=10)
    try:
        marks = ','.join('?' * len(ids))
        found = db.execute(f'select model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, '
                           f'reasoning_tokens, api_call_count, estimated_cost_usd, ended_at - started_at, billing_mode '
                           f'from sessions where id in ({marks})', list(ids)).fetchall()
    finally:
        db.close()
    keys = ('model', 'input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens', 'reasoning_tokens',
            'api_call_count', 'hermes_estimated_cost_usd', 'session_seconds', 'billing_mode')
    return dict(zip(keys, found[0])) if len(found) == 1 else {'sessions_found': len(found)}


def sessions_left(sid):
    db = sqlite3.connect(f'file:{HERMES_DB}?mode=ro', uri=True, timeout=10)
    try:
        return db.execute('select count(*) from sessions where source = ?', ['lm-' + sid]).fetchone()[0]
    finally:
        db.close()


def hermes(row, sid, timeout=40):
    root = DATA / 'hermes-test'
    start = time.monotonic()
    try:
        answer, error = lml_hermes.call(root, sid, row['prompt'], timeout=timeout), None
    except lml_hermes.CallFailed:
        answer, error = None, 'call_failed'
    seconds = time.monotonic() - start
    ids = sorted({item['id'] for item in read_jsonl(root / 'hermes_map' / (sid + '.jsonl')) if item.get('id')})
    usage = hermes_usage(ids)
    remaining, incomplete = lml_hermes.forget(root, sid)
    try:
        candidate = json.loads(answer) if answer is not None else None
    except ValueError:
        candidate, error = None, 'format'
    cost = None
    if usage.get('input_tokens') is not None:
        cost = (usage['input_tokens'] * OPUS_PRICE['input'] + usage['output_tokens'] * OPUS_PRICE['output'] +
                (usage['cache_read_tokens'] or 0) * OPUS_PRICE['cache_read'] +
                (usage['cache_write_tokens'] or 0) * OPUS_PRICE['cache_write']) / 1e6
    return {'screen': 'hermes', 'seconds': round(seconds, 3), 'error': error, 'cost_usd': cost,
            'hermes_sessions': len(ids), 'cleanup_remaining': len(remaining), 'cleanup_incomplete': bool(incomplete),
            'sessions_left_in_store': sessions_left(sid),
            **usage, **outcome(candidate, row)}
