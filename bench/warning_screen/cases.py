#!/usr/bin/env python3
"""Synthetic warning cases with ground truth, run through the real tick to get the exact packets."""
import json
import shutil
import sys
from datetime import timedelta

from common import DATA, atomic_write, capture_tick, dt, judge, write_jsonl

from lml_records import Record

NOW = dt('2026-10-23T16:45:00-05:00')
STARTED = '2026-10-23T16:30:00-05:00'
EVENT = {'key': 'synthetic-sync', 'start': '2026-10-23T16:30:00-05:00', 'end': '2026-10-23T17:30:00-05:00',
         'has_conference': True, 'attendee_count': 2}
SYNC = '/vault/06 - Contacts/Meetings/2026-10-16 1500 Weekly Sync — Sam & Dana.md'
OLDER = '/vault/06 - Contacts/Meetings/2026-10-09 1500 Weekly Sync — Sam & Dana.md'
RECORDS = [
    Record(SYNC, '2026-10-16', '2026-10-16 1500 Weekly Sync — Sam & Dana\nRetainer confirmed at $3,800 per month from November. '
           'Bramble calendar to cover 12 emails in November. Candles agreed as the new product line.'),
    Record(SYNC, '2026-10-16', 'Sam to send Dana the inventory report', 'action_item', '2026-10-20'),
    Record(SYNC, '2026-10-16', 'Sam to deliver the Bramble copy review', 'action_item', '2026-10-28'),
    Record(SYNC, '2026-10-16', 'Sam to send the partner pricing proposal to Dana', 'action_item', '2026-10-21'),
    Record(OLDER, '2026-10-09', '2026-10-09 1500 Weekly Sync — Sam & Dana\nBilling export fixed. Reports to be rebuilt '
           'with a separate read-only account. Priya handoff and Larkspur issues.'),
    Record('email:dana@orchard.example:3', '2026-10-12', 'Re: Phase one\nPhase one budget is $42,500, invoiced in two parts.', 'email'),
]
CONTEXT = [
    ('them', 'Hey, sorry I am a couple minutes late, the last call ran over.'),
    ('me', 'No worries at all, I just got set up myself.'),
    ('them', 'Priya says hi, she has been buried in the Larkspur stuff all week.'),
    ('me', 'Yeah I saw her message about that this morning.'),
]


def part(text, start, seconds, *, xo=0.0, words='aligned'):
    end = start + timedelta(seconds=seconds)
    if words == 'aligned':
        count = len(text.split())
        words = [[round(seconds * i / count, 2), round(seconds * (i + 1) / count, 2)] for i in range(count)]
    return {'t0': start.isoformat(), 't1': end.isoformat(), 'text': text, 'xo': xo, 'words': words}


def transcript(lines):
    rows, clock = [], NOW - timedelta(seconds=150)
    for seq, line in enumerate(CONTEXT + lines, 1):
        ch, text, *options = line
        options = options[0] if options else {}
        seconds = max(2.0, len(text.split()) * 0.4)
        p = part(text, clock, seconds, **options)
        rows.append({'seq': seq, 'ch': ch, 'ts0': p['t0'], 'ts1': p['t1'], 'text': text, 'parts': [p], 'xo': p['xo'],
                     'at': (clock + timedelta(seconds=seconds + 2)).isoformat(), 'v': 1})
        clock += timedelta(seconds=seconds + 1.5)
    return rows


def truth(kind, quote, seq, record, record_quote, subject, text):
    return {'nudge': True, 'kind': kind, 'current_quote': quote, 'current_seq': seq, 'record_quote': record_quote,
            'record_source': record.source, 'record_date': record.date, 'subject': subject, 'text': text}


K = len(CONTEXT)
CASES = [
    {'id': 'P1-wrong-retainer', 'problem': True, 'kind': 'wrong_number', 'lines': [
        ('me', 'So I wanted to lock in the November plan today.'),
        ('them', 'So just to confirm, the retainer is $3,500 a month starting November.'),
        ('me', 'Okay, let me pull that up.')],
     'truth': truth('wrong_number', 'the retainer is $3,500 a month starting November', K + 2, RECORDS[0],
                    'Retainer confirmed at $3,800 per month from November', 'retainer',
                    'Retainer on record is $3,800/month from November, not $3,500 (Oct 16 sync).')},
    {'id': 'P2-wrong-email-count', 'problem': True, 'kind': 'wrong_number', 'lines': [
        ('them', 'Where are we on the Bramble calendar?'),
        ('me', 'The November calendar is 8 emails, like we planned.'),
        ('them', 'Okay good.')],
     'truth': truth('wrong_number', 'The November calendar is 8 emails', K + 2, RECORDS[0],
                    'Bramble calendar to cover 12 emails in November', 'calendar',
                    'Oct 16 sync set the Bramble November calendar at 12 emails, not 8.')},
    {'id': 'P3-contradiction-brand', 'problem': True, 'kind': 'contradiction', 'lines': [
        ('me', 'On the new product line, where did you land?'),
        ('them', 'We agreed to go with soap for the new product line instead of candles.'),
        ('me', 'Interesting.')],
     'truth': truth('contradiction', 'We agreed to go with soap for the new product line instead of candles', K + 2,
                    RECORDS[0], 'Candles agreed as the new product line', 'product line',
                    'Oct 16 sync agreed candles as the new product line, not soap.')},
    {'id': 'P4-contradiction-reports', 'problem': True, 'kind': 'contradiction', 'lines': [
        ('them', 'On the reports, last time you said we would keep the current reports and just patch them.'),
        ('me', 'Right, let me think about that.')],
     'truth': truth('contradiction', 'last time you said we would keep the current reports and just patch them', K + 1,
                    RECORDS[4], 'Reports to be rebuilt with a separate read-only account', 'reports',
                    'Oct 9 sync: reports to be rebuilt, not patched.')},
    {'id': 'P5-missed-report', 'problem': True, 'kind': 'missed_commitment', 'lines': [
        ('them', 'Did you send the inventory report? I still have not seen it since last time.'),
        ('me', 'Let me check my sent folder.')],
     'truth': truth('missed_commitment', 'Did you send the inventory report', K + 1, RECORDS[1],
                    'Sam to send Dana the inventory report', 'inventory report',
                    'You owed Dana the inventory report by Oct 20 (Oct 16 sync).')},
    {'id': 'P6-missed-proposal', 'problem': True, 'kind': 'missed_commitment', 'lines': [
        ('them', 'Also, you were going to send us the partner proposal by Wednesday.'),
        ('me', 'Yes, that is on my list.')],
     'truth': truth('missed_commitment', 'you were going to send us the partner proposal by Wednesday', K + 1, RECORDS[3],
                    'Sam to send the partner pricing proposal to Dana', 'partner proposal',
                    'Partner pricing proposal was due to Dana Oct 21 (Oct 16 sync).')},
    {'id': 'B1-consistent-retainer', 'problem': False, 'lines': [
        ('me', 'For November the retainer stays where we set it.'),
        ('them', 'Great, $3,800 a month from November works for us.'),
        ('me', 'Perfect.')]},
    {'id': 'B2-smalltalk-numbers', 'problem': False, 'lines': [
        ('them', 'My daughter turned 7 on Saturday, we had like 20 kids at the house.'),
        ('me', 'Ha, 20 kids, that is brave.'),
        ('them', 'Never again, honestly.')]},
    {'id': 'B3-spoken-shorthand', 'problem': False, 'lines': [
        ('them', 'What did we land on for phase one?'),
        ('me', 'Phase one is still 42.5, same as the email.'),
        ('them', 'Okay, perfect.')]},
    {'id': 'B4-unreliable-me', 'problem': False, 'lines': [
        ('them', 'Okay, pulling up the November numbers now, give me 2 seconds.'),
        ('me', 'The retainer is $3,500 a month.', {'xo': 0.7, 'words': None}),
        ('them', 'Give me one second.')]},
    {'id': 'B5-commitment-not-due', 'problem': False, 'lines': [
        ('them', 'Are we still on for the Bramble copy review next Tuesday?'),
        ('me', 'Yes, that is still the plan.')]},
    {'id': 'B6-restatement', 'problem': False, 'lines': [
        ('me', 'Like we agreed last time, the billing export is fixed and the reports get rebuilt.'),
        ('them', 'Good, that matches what I remember.')]},
]


def build(case):
    root = DATA / 'cases-test' / case['id']
    shutil.rmtree(root, ignore_errors=True)
    rows = transcript(case['lines'])
    sid = '20261023-163000-' + case['id'][:2].lower()
    path = root / 'sessions' / sid
    atomic_write(path / 'meta.json', {'v': 1, 'sid': sid, 'state': 'active', 'started_at': STARTED, 'ended_at': None,
                                      'heartbeat_at': NOW.isoformat(), 'test': False})
    atomic_write(path / 'live.json', {'v': 1, 'sid': sid, 'at': NOW.isoformat(), 'finals': rows,
                                      'seq_hi': rows[-1]['seq'], 'partials': {}, 'speech': {}})
    atomic_write(path / 'transcript.jsonl', ''.join(json.dumps(r) + '\n' for r in rows))
    atomic_write(root / 'schedule.json', {'events': [EVENT]})
    atomic_write(root / 'briefs' / (EVENT['key'] + '.md'), '# Weekly Sync — Sam & Dana\n\n' +
                 '\n\n'.join(r.render() for r in RECORDS))
    return root


def main():
    rows = []
    for case in CASES:
        captured = capture_tick(build(case), NOW)
        if len(captured) != 1:
            raise SystemExit(f"{case['id']}: tick produced {len(captured)} packets")
        row = dict(captured[0], case=case['id'], problem=case['problem'], kind=case.get('kind'),
                   truth=case.get('truth'))
        if case['problem']:
            reason = judge(case['truth'], row)
            if reason:
                raise SystemExit(f"{case['id']}: true candidate fails gate ({reason})")
        rows.append(row)
        print(case['id'], 'problem' if case['problem'] else 'benign', 'hits', len(row['packet']['hits']),
              'chars', len(row['prompt']))
    write_jsonl(DATA / 'synthetic_packets.jsonl', rows)


if __name__ == '__main__':
    sys.exit(main())
