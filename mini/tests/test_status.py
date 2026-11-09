import json
import os
from datetime import timedelta
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest

from conftest import event, make_session, part, row
from lml_common import atomic_write, dt
from lml_records import Record
from lml_hermes import forget
from lml_status import status

OFF = {'state': 'off', 'chat': False, 'error': None}
from live_meeting_nudge import tick
from test_nudge import candidate

TZ = ZoneInfo('America/Chicago')
MEETINGS = '06 - Contacts/Meetings'
SID = '20261013-083000-aaaa'
STATES = {'waiting', 'filing', 'filed', 'skipped', 'failed'}


@pytest.fixture
def paths(tmp_path):
    return SimpleNamespace(root=tmp_path / 'live-meeting-test', processing=tmp_path / 'processing.json',
                           calendar=tmp_path / 'calendar-sync.json', vault=tmp_path / 'vault')


def feed(paths, now):
    return status(paths.root, now, processing=paths.processing, calendar=paths.calendar, vault=paths.vault, tz=TZ)


def ended(paths, now, sid=SID, minutes_ago=30, length=30, arrived_minutes_ago=None, **meta):
    end = now - timedelta(minutes=minutes_ago)
    path = make_session(paths.root, now, sid=sid, state='closed', started_at=(end - timedelta(minutes=length)).isoformat(),
                        ended_at=end.isoformat(), heartbeat_at=end.isoformat(), **meta)
    arrived = (now - timedelta(minutes=minutes_ago if arrived_minutes_ago is None else arrived_minutes_ago)).timestamp()
    os.utime(path / 'meta.json', (arrived, arrived))
    return path


def note(paths, name, start, end, extra='', body=''):
    atomic_write(paths.vault / MEETINGS / name, f'---\nstart: {start}\nend: {end}\n{extra}---\n{body}')


def review(note_id, delivery='photon', tasks=2, **changes):
    return {'note_id': note_id, 'meeting': '2026-10-13 0900 Budget & Plans.md', 'title': 'Budget review with Kim',
            'tasks': {str(i): {'title': f'task {i}'} for i in range(tasks)}, 'delivery': delivery,
            'created_at': '2026-10-13T10:00:00', **changes}


def processing(paths, *, processed=(), skipped=(), reviews=(), filed=None):
    atomic_write(paths.processing, {'listener': {'processed': list(processed), 'skipped': {k: 'not a meeting' for k in skipped}},
                                    'granola': {'reviews': {f'slug{i}': r for i, r in enumerate(reviews)}},
                                    'filed': filed or {}})


def test_status_has_the_c4_shape_key_for_key(paths, now):
    atomic_write(paths.root / 'schedule.json', {'events': [event('next', (now + timedelta(minutes=30)).isoformat(),
                                                                 (now + timedelta(minutes=60)).isoformat(),
                                                                 title='Budget', meeting_url='https://meet.google.com/x',
                                                                 event_id='evt')]})
    ended(paths, now)
    processing(paths, reviews=[review('lm-' + SID)])
    result = json.loads(json.dumps(feed(paths, now)))
    assert set(result) == {'v', 'at', 'next', 'today', 'recent', 'live'}
    assert result['v'] == 1 and dt(result['at']) == now and '.' not in result['at']
    assert set(result['next']) == {'title', 'start', 'end', 'meeting_url', 'note', 'note_url', 'brief', 'owed', 'with', 'hermes', 'key'}
    assert (result['next']['title'], result['next']['meeting_url'], result['next']['brief']) == ('Budget', 'https://meet.google.com/x', [])
    assert dt(result['next']['start']) == now + timedelta(minutes=30) and dt(result['next']['end']) == now + timedelta(minutes=60)
    [recent] = result['recent']
    assert set(recent) == {'sid', 'title', 'ended_at', 'duration_s', 'marks', 'state', 'note', 'note_url', 'review',
                           'snippet', 'summary', 'marked_moments'}
    assert recent['sid'] == SID and isinstance(recent['title'], str) and recent['state'] in STATES
    assert dt(recent['ended_at']) == now - timedelta(minutes=30) and recent['duration_s'] == 1800 and recent['marks'] == 0
    assert recent['review'] == {'sent': True, 'tasks': 2, 'answered': False}


def test_status_with_no_sources_is_empty_not_an_error(paths, now):
    assert feed(paths, now) == {'v': 1, 'at': now.isoformat(), 'next': None, 'today': [], 'recent': [], 'live': None}


def test_unreadable_sources_give_nulls(paths, now):
    atomic_write(paths.root / 'schedule.json', '{not json')
    atomic_write(paths.processing, '[1, 2]')
    atomic_write(paths.calendar, '"events"')
    session = ended(paths, now, minutes_ago=80)
    atomic_write(session / 'done.json', '["at"]')
    atomic_write(session / 'marks.jsonl', '{"at": "2026-10-13T08:40:00-05:00", "note": null}\nnot json\n{"at": "partial')
    atomic_write(paths.vault / MEETINGS / '2026-10-13 0800 Broken.md', '---\nstart: soon\n---\n')
    result = feed(paths, now)
    assert result['next'] is None
    assert result['recent'] == [{'sid': SID, 'title': 'Call 2026-10-13 0825', 'ended_at': '2026-10-13T08:55:00-05:00',
                                 'duration_s': 1800, 'marks': 1, 'state': 'failed', 'note': None, 'note_url': None,
                                 'review': None, 'snippet': None, 'summary': [],
                                 'marked_moments': [{'at': '2026-10-13T08:40:00-05:00', 'text': ''}]}]


@pytest.mark.parametrize('case,expected', [
    ('processed', 'filed'), ('skipped', 'skipped'), ('done_recently', 'filing'), ('done_long_ago', 'failed'),
    ('ended_recently', 'waiting'), ('ended_long_ago', 'failed')])
def test_recent_state(paths, now, case, expected):
    minutes_ago = 70 if case == 'ended_recently' else 80
    session = ended(paths, now, minutes_ago=minutes_ago)
    if case in {'done_recently', 'done_long_ago'}:
        atomic_write(session / 'done.json', {'at': (now - timedelta(minutes=70 if case == 'done_recently' else 76)).isoformat()})
    processing(paths, processed=['lm-' + SID] if case == 'processed' else [], skipped=['lm-' + SID] if case == 'skipped' else [])
    assert feed(paths, now)['recent'][0]['state'] == expected


@pytest.mark.parametrize('arrived,expected', [(0, 'waiting'), (74, 'waiting'), (76, 'failed'), (None, 'failed')])
def test_late_import_waits_from_its_arrival_not_its_end(paths, now, arrived, expected):
    ended(paths, now, minutes_ago=6 * 60, arrived_minutes_ago=arrived, source='phone')
    assert feed(paths, now)['recent'][0]['state'] == expected


def test_late_import_is_filing_once_its_done_signal_lands(paths, now):
    session = ended(paths, now, minutes_ago=6 * 60, arrived_minutes_ago=0, source='file')
    atomic_write(session / 'done.json', {'at': now.isoformat(), 'transcript_bytes': 10})
    assert feed(paths, now)['recent'][0]['state'] == 'filing'


@pytest.mark.parametrize('title,expected', [('Call with Omar', 'Call with Omar'), ('  ', 'Call 2026-10-13 0825'),
                                            (None, 'Call 2026-10-13 0825'), (['Omar'], 'Call 2026-10-13 0825')])
def test_meta_title_names_a_capture_with_no_note(paths, now, title, expected):
    ended(paths, now, minutes_ago=80, title=title)
    assert feed(paths, now)['recent'][0]['title'] == expected


def test_review_filed_note_and_calendar_match_outrank_the_meta_title(paths, now):
    ended(paths, now, minutes_ago=80, title='Call with Omar')
    note(paths, '2026-10-13 0825 Kim call.md', '2026-10-13T08:25:00-05:00', '2026-10-13T08:55:00-05:00')
    assert feed(paths, now)['recent'][0]['title'] == 'Kim call'
    atomic_write(paths.vault / MEETINGS / '2026-10-13 0900 Filed.md', 'filed')
    processing(paths, filed={'2026-10-13 0900 Filed.md': {'source': 'listener', 'note_id': 'lm-' + SID}})
    assert feed(paths, now)['recent'][0]['title'] == 'Filed'
    processing(paths, reviews=[review('lm-' + SID)])
    assert feed(paths, now)['recent'][0]['title'] == 'Budget review with Kim'


def test_recent_is_ended_sessions_newest_first_at_most_five(paths, now):
    for i in range(7):
        ended(paths, now, sid=f'20261013-0{i}0000-aaaa', minutes_ago=100 - i)
    make_session(paths.root, now, sid='20261013-100000-live')
    ended(paths, now, sid='20261013-095000-test', minutes_ago=1, test=True)
    ended(paths, now, sid='20261013-095500-gone', minutes_ago=1)
    atomic_write(paths.root / 'forgotten.jsonl', json.dumps({'sid': '20261013-095500-gone', 'at': now.isoformat()}) + '\n')
    assert [r['sid'] for r in feed(paths, now)['recent']] == [f'20261013-0{i}0000-aaaa' for i in (6, 5, 4, 3, 2)]


def test_filed_note_and_url_come_from_the_review(paths, now):
    ended(paths, now, minutes_ago=80)
    note(paths, '2026-10-13 0900 Budget & Plans.md', '2026-10-13T09:00:00-05:00', '2026-10-13T09:30:00-05:00')
    processing(paths, processed=['lm-' + SID], reviews=[review('lm-' + SID, tasks=3)])
    [recent] = feed(paths, now)['recent']
    assert recent['title'] == 'Budget review with Kim'
    assert recent['note'] == '2026-10-13 0900 Budget & Plans'
    assert recent['note_url'] == ('obsidian://open?vault=vault&file='
                                  '06%20-%20Contacts%2FMeetings%2F2026-10-13%200900%20Budget%20%26%20Plans')
    assert recent['review'] == {'sent': True, 'tasks': 3, 'answered': False}


def test_review_answered_once_its_tasks_were_applied(paths, now):
    ended(paths, now, minutes_ago=80)
    processing(paths, processed=['lm-' + SID], reviews=[review('lm-' + SID, tasks=3, applied_at='2026-10-13T10:20:00')])
    assert feed(paths, now)['recent'][0]['review'] == {'sent': True, 'tasks': 3, 'answered': True}


def test_filed_note_from_registry_then_session_marker_then_calendar_match(paths, now):
    ended(paths, now, minutes_ago=80)
    note(paths, '2026-10-13 0800 Kim call.md', '2026-10-13T08:00:00-05:00', '2026-10-13T08:30:00-05:00')
    note(paths, '2026-10-13 0815 Notes.md', '2026-10-13T07:00:00-05:00', '2026-10-13T07:05:00-05:00',
         body='## Transcript\nRecorded by the meeting listener (session ' + SID + ')\n')
    atomic_write(paths.vault / MEETINGS / '2026-10-13 0900 Filed.md', 'filed')
    processing(paths, processed=['lm-' + SID], filed={'2026-10-13 0900 Filed.md': {'source': 'listener', 'note_id': 'lm-' + SID}})
    assert (feed(paths, now)['recent'][0]['title'], feed(paths, now)['recent'][0]['note']) == ('Filed', '2026-10-13 0900 Filed')
    processing(paths, processed=['lm-' + SID])
    assert (feed(paths, now)['recent'][0]['title'], feed(paths, now)['recent'][0]['note']) == ('Notes', '2026-10-13 0815 Notes')
    (paths.vault / MEETINGS / '2026-10-13 0815 Notes.md').unlink()
    assert (feed(paths, now)['recent'][0]['title'], feed(paths, now)['recent'][0]['note']) == ('Kim call', '2026-10-13 0800 Kim call')


def test_unfiled_capture_is_titled_by_calendar_match_and_has_no_note(paths, now):
    ended(paths, now, minutes_ago=80, length=40)
    note(paths, '2026-10-13 0800 Cancelled.md', '2026-10-13T08:00:00-05:00', '2026-10-13T09:00:00-05:00',
         extra='tags:\n  - meeting/cancelled\n')
    note(paths, '2026-10-13 0630 Ran late.md', '2026-10-13T06:30:00-05:00', '2026-10-13T07:00:00-05:00')
    note(paths, '2026-10-13 0745 Kim call.md', '2026-10-13T07:45:00-05:00', '2026-10-13T08:15:00-05:00')
    [recent] = feed(paths, now)['recent']
    assert (recent['title'], recent['state'], recent['note'], recent['note_url']) == ('Kim call', 'failed', None, None)


def test_capture_that_starts_late_matches_a_note_up_to_two_hours_earlier(paths, now):
    ended(paths, now, minutes_ago=20, length=10)
    note(paths, '2026-10-13 0800 Long call.md', '2026-10-13T08:00:00-05:00', '2026-10-13T08:30:00-05:00')
    assert feed(paths, now)['recent'][0]['title'] == 'Long call'


@pytest.mark.parametrize('delivery,sent', [('photon', True), ('discord-fallback', True), ('photon-failed', False),
                                           ('none', False), ('local', False)])
def test_review_sent_follows_delivery(paths, now, delivery, sent):
    ended(paths, now)
    processing(paths, reviews=[review('lm-' + SID, delivery=delivery, tasks=0)])
    assert feed(paths, now)['recent'][0]['review'] == {'sent': sent, 'tasks': 0, 'answered': False}


def test_latest_review_for_the_capture_wins_and_others_are_ignored(paths, now):
    ended(paths, now)
    processing(paths, reviews=[review('lm-' + SID, tasks=1, created_at='2026-10-13T11:00:00'),
                               review('lm-' + SID, tasks=4, delivery='none', created_at='2026-10-13T09:00:00'),
                               review('not_granola', tasks=9)])
    assert feed(paths, now)['recent'][0]['review'] == {'sent': True, 'tasks': 1, 'answered': False}
    processing(paths, reviews=[review('not_granola', tasks=9)])
    assert feed(paths, now)['recent'][0]['review'] is None


def test_next_is_the_first_unfinished_real_meeting(paths, now):
    events = [event('later', (now + timedelta(hours=2)).isoformat(), (now + timedelta(hours=3)).isoformat(), title='Later'),
              event('over', (now - timedelta(hours=1)).isoformat(), now.isoformat(), title='Over'),
              {**event('solo', (now - timedelta(minutes=5)).isoformat(), (now + timedelta(hours=1)).isoformat(),
                       title='Focus block'), 'attendee_count': 1},
              {**event('solo-call', (now + timedelta(hours=1)).isoformat(), (now + timedelta(hours=2)).isoformat(),
                       title='Solo call'), 'attendee_count': 1, 'has_conference': True}]
    atomic_write(paths.root / 'schedule.json', {'events': events})
    assert feed(paths, now)['next']['title'] == 'Solo call'
    events.append(event('ongoing', (now - timedelta(minutes=15)).isoformat(), (now + timedelta(minutes=15)).isoformat()))
    atomic_write(paths.root / 'schedule.json', {'events': events})
    assert feed(paths, now)['next'] == {'title': 'Untitled meeting', 'start': events[-1]['start'], 'end': events[-1]['end'],
                                        'meeting_url': None, 'note': None, 'note_url': None, 'brief': [], 'owed': [],
                                        'with': None, 'hermes': OFF, 'key': 'ongoing'}


def test_next_note_comes_from_calendar_sync_by_event_id(paths, now):
    atomic_write(paths.root / 'schedule.json', {'events': [event('k', (now + timedelta(minutes=5)).isoformat(),
                                                                 (now + timedelta(minutes=35)).isoformat(), title='Sync', event_id='evt')]})
    atomic_write(paths.calendar, {'events': {'evt': {'path': f'{MEETINGS}/2026-10-13 1020 Sync.md', 'hash': 'x'}}})
    assert feed(paths, now)['next']['note'] is None
    note(paths, '2026-10-13 1020 Sync.md', '2026-10-13T10:20:00-05:00', '2026-10-13T10:50:00-05:00')
    upcoming = feed(paths, now)['next']
    assert upcoming['note'] == '2026-10-13 1020 Sync'
    assert upcoming['note_url'] == 'obsidian://open?vault=vault&file=06%20-%20Contacts%2FMeetings%2F2026-10-13%201020%20Sync'


def test_next_brief_lines_are_plain_and_short(paths, now):
    atomic_write(paths.root / 'schedule.json', {'events': [event('k', (now + timedelta(minutes=5)).isoformat(),
                                                                 (now + timedelta(minutes=35)).isoformat(), title='Sync')]})
    long = 'Agreed the **pilot** with [[Kay Porter|Kim]] and [[Projects/Budget#Plan]]; ' + 'details ' * 30
    brief = '\n\n'.join([
        '# Sync',
        Record('a.md', '2026-09-29', '2026-09-29 Older\nOlder summary.').render(),
        Record('b.md', '2026-10-06', '2026-10-06 Sync\n> [!note]\n> ' + long).render(),
        Record('b.md', '2026-10-06', '![[TaskNotes/Views/meeting-tasks.base#All]]', 'action_item').render(),
        Record('b.md', '2026-10-06', '- [ ] Send the `pricing` sheet to [[Kay Porter]] by 2026-10-20', 'action_item').render(),
        Record('email:x:1', '2026-10-08', 'Re: pricing\nsnippet', 'email').render(),
        Record('email:x:2', '2026-10-11', 'Contract draft\nsnippet', 'email').render(),
    ])
    atomic_write(paths.root / 'briefs/k.md', brief)
    lines = feed(paths, now)['next']['brief']
    assert lines[0].startswith('Last met Oct 6: Agreed the pilot with Kim and Budget; details') and lines[0].endswith('…')
    assert lines[1:] == ['Open: Send the pricing sheet to Kay Porter by 2026-10-20', 'Email Oct 11: Contract draft']
    assert all(len(line) <= 140 and not any(mark in line for mark in ('[[', '**', '`', '> ')) for line in lines)


def test_old_schedule_events_without_new_fields_do_not_break_status(paths, now):
    atomic_write(paths.root / 'schedule.json', {'events': [{'key': 'old', 'start': (now + timedelta(minutes=5)).isoformat(),
                                                            'end': (now + timedelta(minutes=35)).isoformat(),
                                                            'has_conference': True, 'attendee_count': 2}, {'key': 'broken'}]})
    assert feed(paths, now)['next']['title'] == 'Untitled meeting'


SUMMARY_BODY = '''## Summary
Agreed the [[Kay Porter|Kim]] pilot starts in **November**. Pricing waits for the board on Nov 12.

## Decisions
- Pilot scope is the [[Projects/Budget#Plan|budget]] dashboard only.
- Sam sends the SOW by Friday.

## Action items
![[TaskNotes/Views/meeting-tasks.base#All]]
- [ ] Not a summary line

## Transcript
[08:30:00] Kim: Not a summary line either.
'''


def filed_capture(paths, now, body=SUMMARY_BODY, **ledger):
    ended(paths, now, minutes_ago=80)
    note(paths, '2026-10-13 0825 Kim call.md', '2026-10-13T08:25:00-05:00', '2026-10-13T08:55:00-05:00', body=body)
    atomic_write(paths.processing, {'listener': ledger})
    [recent] = feed(paths, now)['recent']
    return recent


def test_filed_note_gives_a_snippet_and_three_plain_summary_bullets(paths, now):
    recent = filed_capture(paths, now, processed=['lm-' + SID])
    assert recent['state'] == 'filed' and recent['note'] == '2026-10-13 0825 Kim call'
    assert recent['snippet'] == 'Agreed the Kim pilot starts in November.'
    assert recent['summary'] == ['Agreed the Kim pilot starts in November.', 'Pricing waits for the board on Nov 12.',
                                 'Pilot scope is the budget dashboard only.']


def test_long_summary_lines_are_clipped(paths, now):
    long = 'Weekly sync with Kim: ' + ', '.join(f'item number {i} moved forward' for i in range(12)) + '.'
    recent = filed_capture(paths, now, body=f'## Summary\n{long}\n\n## Decisions\n- One.\n', processed=['lm-' + SID])
    assert recent['snippet'].startswith('Weekly sync with Kim: item number 0') and recent['snippet'].endswith('…')
    assert len(recent['snippet']) <= 90
    assert recent['summary'][0].endswith('…') and len(recent['summary'][0]) <= 140 and recent['summary'][1] == 'One.'


def test_lead_in_lines_are_not_summary_bullets(paths, now):
    body = "## Summary\nAgreed the pilot.\n\n## Decisions\nAs recorded in Granola's notes:\n- Pilot starts in November.\n- Key points:\n"
    recent = filed_capture(paths, now, body=body, processed=['lm-' + SID])
    assert recent['summary'] == ['Agreed the pilot.', 'Pilot starts in November.']


def test_a_note_with_no_summary_or_decisions_gives_none(paths, now):
    recent = filed_capture(paths, now, body='## Summary\n\n## Decisions\n\n## Notes\nSomething.\n', processed=['lm-' + SID])
    assert (recent['state'], recent['snippet'], recent['summary']) == ('filed', None, [])


def test_an_unfiled_capture_has_no_summary_even_with_a_matching_note(paths, now):
    recent = filed_capture(paths, now)
    assert (recent['state'], recent['title'], recent['snippet'], recent['summary']) == ('failed', 'Kim call', None, [])


@pytest.mark.parametrize('reason', ['duplicate of 2026-10-13 0825 Kim call.md (filed from granola:abc123)',
                                    'duplicate of 2026-10-13 0825 Kim call', 'Duplicate of [[2026-10-13 0825 Kim call]].',
                                    'duplicate of [[2026-10-13 0825 Kim call|Kim call]]'])
def test_a_duplicate_skip_carries_the_note_filed_from_the_other_source(paths, now, reason):
    recent = filed_capture(paths, now, skipped={'lm-' + SID: reason})
    assert (recent['state'], recent['note']) == ('skipped', '2026-10-13 0825 Kim call')
    assert recent['note_url'] == 'obsidian://open?vault=vault&file=06%20-%20Contacts%2FMeetings%2F2026-10-13%200825%20Kim%20call'
    assert recent['snippet'] == 'Agreed the Kim pilot starts in November.' and len(recent['summary']) == 3


@pytest.mark.parametrize('reason', ['not a meeting: a video', 'duplicate of 2026-10-13 0900 Missing.md', None])
def test_other_skips_have_no_summary(paths, now, reason):
    recent = filed_capture(paths, now, skipped={'lm-' + SID: reason})
    assert (recent['state'], recent['note'], recent['note_url'], recent['snippet'], recent['summary']) == (
        'skipped', None, None, None, [])


def line(text, seq, ch, start, end):
    return row(text, seq=seq, ch=ch, parts=[part(text, f'2026-10-13T{start}-05:00', f'2026-10-13T{end}-05:00')])


def test_each_mark_shows_the_line_spoken_at_its_time(paths, now):
    rows = [line('Alpha line', 1, 'me', '08:30:00', '08:30:10'), line('Bravo line', 2, 'them', '08:30:05', '08:30:20'),
            line('Charlie line', 3, 'them', '08:31:00', '08:31:05'), line('x ' * 200, 4, 'me', '08:32:00', '08:32:30'),
            line(' ', 5, 'them', '08:33:00', '08:33:10')]
    session = ended(paths, now, minutes_ago=80, rows=rows)
    marks = ['2026-10-13T08:30:02-05:00', '2026-10-13T13:30:07Z', '2026-10-13T08:30:40-05:00', '2026-10-13T08:31:05-05:00',
             '2026-10-13T08:25:00-05:00', 'not a time', '2026-10-13T08:32:10-05:00', '2026-10-13T08:33:05-05:00']
    atomic_write(session / 'marks.jsonl', ''.join(json.dumps({'at': at, 'note': None}) + '\n' for at in marks))
    [recent] = feed(paths, now)['recent']
    moments = recent['marked_moments']
    assert [m['text'] for m in moments[:5]] == ['Alpha line', 'Bravo line', 'Bravo line', 'Charlie line', '']
    assert [m['at'] for m in moments[:5]] == ['2026-10-13T08:30:02-05:00', '2026-10-13T08:30:07-05:00',
                                              '2026-10-13T08:30:40-05:00', '2026-10-13T08:31:05-05:00',
                                              '2026-10-13T08:25:00-05:00']
    assert len(moments) == 7 and moments[5]['text'].startswith('x x') and len(moments[5]['text']) <= 140
    assert moments[6]['text'] == moments[5]['text']
    assert recent['marks'] == 8


TASKS = '02 - Planning/Task Records'


def task(paths, name, status, people=(), **fields):
    lines = ['---', 'types:', '  - task', f'status: {status}', *(f'{key}: {value}' for key, value in fields.items())]
    lines += ['people:', *(f'  - "[[{person}]]"' for person in people)] if people else []
    atomic_write(paths.vault / TASKS / f'{name}.md', '\n'.join(lines + ['---', 'Body.', '']))


def next_with_people(paths, now, people):
    atomic_write(paths.root / 'schedule.json', {'events': [event('k', (now + timedelta(minutes=5)).isoformat(),
                                                                 (now + timedelta(minutes=35)).isoformat(), title='Sync', event_id='evt')]})
    atomic_write(paths.calendar, {'events': {'evt': {'path': f'{MEETINGS}/2026-10-13 1020 Sync.md'}}})
    roster = ''.join(f'  - "[[{person}]]"\n' for person in people)
    note(paths, '2026-10-13 1020 Sync.md', '2026-10-13T10:20:00-05:00', '2026-10-13T10:50:00-05:00',
         extra=f'people:\n{roster}' if people else '')
    return feed(paths, now)['next']['owed']


def test_owed_lists_open_tasks_linked_to_the_attendees_soonest_first(paths, now):
    task(paths, 'Send the SOP list', 'open', ['Dana Whitfield'], scheduled='2026-10-20')
    task(paths, 'Share the onboarding draft', 'in-progress', ['Kay Porter|Kim'], due='2026-10-15', scheduled='2026-10-30')
    task(paths, 'Fix the helper', 'blocked', ['Dana Whitfield'])
    task(paths, 'file-name', 'open', ['Dana Whitfield'], title='Titled task', scheduled='2026-10-14')
    for status in ('parked', 'done', 'backlog', 'triage', 'canceled'):
        task(paths, f'A {status} task', status, ['Dana Whitfield'], scheduled='2026-10-01')
    task(paths, 'Someone else', 'open', ['Jay Moore'], scheduled='2026-10-01')
    task(paths, 'Nobody', 'open', scheduled='2026-10-01')
    assert next_with_people(paths, now, ['Dana Whitfield', 'Kay Porter']) == [
        'Titled task', 'Share the onboarding draft', 'Send the SOP list', 'Fix the helper']
    for day in range(21, 25):
        task(paths, f'Extra {day}', 'open', ['Dana Whitfield'], scheduled=f'2026-10-{day}')
    assert next_with_people(paths, now, ['Dana Whitfield', 'Kay Porter']) == [
        'Titled task', 'Share the onboarding draft', 'Send the SOP list', 'Extra 21', 'Extra 22']


def test_owed_reads_the_new_status_words_too(paths, now):
    task(paths, 'Plan the call', 'todo', ['Dana Whitfield'], scheduled='2026-10-14')
    task(paths, 'Review the SOP', 'in-review', ['Dana Whitfield'], scheduled='2026-10-15')
    task(paths, 'Hear back', 'waiting', ['Dana Whitfield'], scheduled='2026-10-16')
    for status in ('backlog', 'triage', 'canceled', 'done'):
        task(paths, f'A {status} task', status, ['Dana Whitfield'], scheduled='2026-10-01')
    assert next_with_people(paths, now, ['Dana Whitfield']) == ['Plan the call', 'Review the SOP', 'Hear back']


def test_owed_is_empty_without_a_note_or_attendees(paths, now):
    task(paths, 'Send the SOP list', 'open', ['Dana Whitfield'])
    assert next_with_people(paths, now, []) == []
    (paths.vault / MEETINGS / '2026-10-13 1020 Sync.md').unlink()
    assert feed(paths, now)['next']['owed'] == []


LIVE = '20261013-100000-abcd'


def test_live_lists_the_warnings_texted_during_the_recording_in_order(root, paths, now, hermes):
    brief = (root / 'briefs/event.md').read_text() + '\n\n' + Record('older.md', '2026-09-23', 'The budget is $80,000.').render()
    atomic_write(root / 'briefs/event.md', brief)
    brief += '\n\n' + Record('oldest.md', '2026-09-16', 'The budget is $60,000.').render()
    atomic_write(root / 'briefs/event.md', brief)
    second = dict(record_quote='The budget is $80,000.', record_source='older.md', record_date='2026-09-23',
                  text='Earlier the budget was $80,000.')
    third = dict(record_quote='The budget is $60,000.', record_source='oldest.md', record_date='2026-09-16',
                 text='In September the budget was $60,000.')
    for minutes, seq, reply in ((0, 1, candidate()), (11, 2, candidate(current_seq=2, **second)),
                                (22, 3, candidate(current_seq=3)), (33, 4, candidate(current_seq=4, **third)),
                                (44, 5, candidate(current_seq=5))):
        at = now + timedelta(minutes=minutes)
        start = (at - timedelta(seconds=10)).isoformat()
        make_session(root, at, rows=[row(seq=seq, parts=[part(start=start, end=at.isoformat())])])
        hermes.reply = json.dumps(reply)
        tick(root=root, now=at, runner=hermes, hermes_runner=hermes)
    later = now + timedelta(minutes=44)
    assert feed(paths, later)['live'] == {'sid': LIVE, 'warnings': [
        {'at': now.isoformat(), 'text': 'The prior budget was $90,000.', 'n': 1},
        {'at': (now + timedelta(minutes=11)).isoformat(), 'text': 'Earlier the budget was $80,000.', 'n': 2},
        {'at': (now + timedelta(minutes=33)).isoformat(), 'text': 'In September the budget was $60,000.', 'n': 3}]}
    make_session(root, later, state='closed', ended_at=later.isoformat())
    assert feed(paths, later)['live'] is None


def test_dry_run_warnings_count_and_rejected_ones_do_not(root, paths, now, hermes):
    hermes.reply = json.dumps(candidate(current_quote='an invented budget'))
    tick(root=root, now=now, runner=hermes, hermes_runner=hermes)
    assert feed(paths, now)['live'] == {'sid': LIVE, 'warnings': []}
    later = now + timedelta(minutes=1)
    make_session(root, later, rows=[row(seq=2, parts=[part(start=(later - timedelta(seconds=10)).isoformat(), end=later.isoformat())])])
    hermes.reply = json.dumps(candidate(current_seq=2))
    tick(root=root, now=later, print_only=True, runner=hermes, hermes_runner=hermes)
    assert feed(paths, later)['live']['warnings'] == [{'at': later.isoformat(), 'text': 'The prior budget was $90,000.', 'n': 1}]


def test_forget_removes_the_status_copy_that_quotes_the_transcript(paths, now, hermes):
    session = ended(paths, now, rows=[line('Private line', 1, 'them', '09:30:00', '09:30:10')])
    atomic_write(session / 'marks.jsonl', json.dumps({'at': '2026-10-13T09:30:05-05:00', 'note': None}) + '\n')
    atomic_write(paths.root / 'status.json', feed(paths, now))
    assert 'Private line' in (paths.root / 'status.json').read_text()
    assert forget(paths.root, SID, runner=hermes) == (set(), False)
    assert not (paths.root / 'status.json').exists() and feed(paths, now)['recent'] == []


@pytest.mark.parametrize('people,expected', [(['Dana Whitfield'], 'Dana'), (['Dana Whitfield', 'Kay Porter'], None), ([], None),
                                             (None, None), ('Dana Whitfield', None), ([' ', 'Kim'], 'Kim')])
def test_next_with_names_the_one_other_attendee(paths, now, people, expected):
    upcoming = event('k', (now + timedelta(minutes=5)).isoformat(), (now + timedelta(minutes=35)).isoformat(), title='Sync')
    atomic_write(paths.root / 'schedule.json', {'events': [{**upcoming, **({} if people is None else {'people': people})}]})
    assert feed(paths, now)['next']['with'] == expected


def test_next_falls_back_to_the_schedule_next_when_no_meeting_is_within_24h(paths, now):
    far = event('far', (now + timedelta(hours=27)).isoformat(), (now + timedelta(hours=28)).isoformat(), title='Weekly sync',
                people=['Kim Lee'])
    atomic_write(paths.root / 'schedule.json', {'events': [], 'next': far})
    result = feed(paths, now)['next']
    assert (result['title'], result['start'], result['with']) == ('Weekly sync', far['start'], 'Kim')
    soon = event('soon', (now + timedelta(hours=2)).isoformat(), (now + timedelta(hours=3)).isoformat(), title='Soon')
    atomic_write(paths.root / 'schedule.json', {'events': [soon], 'next': far})
    assert feed(paths, now)['next']['title'] == 'Soon'
    atomic_write(paths.root / 'schedule.json', {'events': [], 'next': {**far, 'end': (now - timedelta(hours=1)).isoformat()}})
    assert feed(paths, now)['next'] is None
    atomic_write(paths.root / 'schedule.json', {'events': [], 'next': 'junk'})
    assert feed(paths, now)['next'] is None


def test_today_lists_the_rest_of_today_from_every_account_in_order(paths, now):
    at = lambda minutes: (now + timedelta(minutes=minutes)).isoformat()
    events = [event('later', at(120), at(150), title='Design review', meeting_url='https://zoom.us/j/1'),
              event('done', at(-90), at(-30), title='Over already'),
              {**event('now', at(-10), at(20), title='Focus block'), 'attendee_count': 1},
              event('tomorrow', (now + timedelta(days=1, hours=2)).isoformat(), (now + timedelta(days=1, hours=3)).isoformat()),
              event('blank', at(60), at(90), title='  ')]
    atomic_write(paths.root / 'schedule.json', {'events': events, 'next': events[0]})
    rows = feed(paths, now)['today']
    assert [r['title'] for r in rows] == ['Focus block', 'Untitled event', 'Design review']
    assert rows[0]['meeting'] is False and rows[2] == {'title': 'Design review', 'start': at(120), 'end': at(150),
                                                       'meeting_url': 'https://zoom.us/j/1', 'meeting': True,
                                                           'hermes': OFF, 'key': 'later'}
