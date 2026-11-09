import json
import os
from datetime import timedelta
from pathlib import Path

import pytest

from conftest import event, make_session
from live_meeting_brief import (MAX_BYTES, Sources, Vault, build_brief, load_vault, main, maintenance, recorder_settings,
                                run, vault_context)
from lml_common import atomic_write, config, dt, forgotten, read_json
from lml_events import current, owned, window_start
from lml_notes import front_matter
from lml_records import Record, records


def sources_for(raw, **changes):
    values = dict(events=lambda minutes: (raw, {'ok': True, 'status': 'ok'}), attendees=lambda e: e.get('attendees', []),
                  key=lambda e, start: e['id'], parse_dt=lambda value: dt(value) if value and 'T' in str(value) else None,
                  terms=lambda e, attendees: ['budget'], gmail=lambda terms, attendees: [],
                  vault=Vault, shared=lambda event: '')
    return Sources(**{**values, **changes})


def raw_event(now, **changes):
    return {**dict(id='upcoming', summary='PRIVATE TITLE', start=(now + timedelta(minutes=5)).isoformat(),
                   end=(now + timedelta(minutes=65)).isoformat(), attendees=[{'name': 'PRIVATE NAME', 'email': 'kim@example.test'},
                                                                            {'email': 'sam@example.test'}]), **changes}


def test_schedule_carries_panel_fields_but_no_emails_and_fingerprint_rewrite(root, now, hermes):
    raw = raw_event(now, description='PRIVATE DESCRIPTION')
    sources = sources_for([raw])
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    schedule = read_json(root / 'schedule.json')
    upcoming = next(e for e in schedule['events'] if e['key'] == 'upcoming')
    assert set(upcoming) == {'key', 'start', 'end', 'window_start', 'has_conference', 'attendee_count', 'others',
                             'title', 'meeting_url', 'event_id', 'vocabulary', 'people'}
    assert upcoming['window_start'] == (now + timedelta(minutes=3)).isoformat()
    assert (upcoming['title'], upcoming['meeting_url'], upcoming['event_id']) == ('PRIVATE TITLE', None, 'upcoming')
    assert upcoming['vocabulary'] == ['PRIVATE NAME']
    assert '@' not in json.dumps(schedule) and 'DESCRIPTION' not in json.dumps(schedule)
    brief = root / 'briefs/upcoming.md'
    assert 'PRIVATE TITLE' in brief.read_text()
    timestamp = brief.stat().st_mtime_ns
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    assert brief.stat().st_mtime_ns == timestamp
    raw['description'] = 'changed'
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    assert brief.stat().st_mtime_ns != timestamp


def test_all_day_solo_and_distant_briefs_skipped(root, now, hermes):
    raw = [raw_event(now, id='all-day', start='2026-10-13', end='2026-10-14'),
           raw_event(now, id='solo', attendees=[{'email': 'sam@example.test'}]),
           raw_event(now, id='late', start=(now + timedelta(minutes=11)).isoformat())]
    run(root=root, now=now, sources=sources_for(raw), settings={'retention_days': 14}, runner=hermes)
    assert not (root / 'briefs/all-day.md').exists()
    assert not (root / 'briefs/solo.md').exists()
    assert not (root / 'briefs/late.md').exists()


@pytest.mark.parametrize('status,still_in_fetch', [('partial', False), ('ok', True)])
def test_schedule_rewrite_keeps_ongoing_event_and_saved_boundary(root, now, hermes, status, still_in_fetch):
    earlier = event('earlier', '2026-10-13T09:00:00-05:00', '2026-10-13T09:59:30-05:00')
    ongoing = event()
    boundary = window_start(ongoing, [earlier, ongoing]).isoformat()
    ongoing['window_start'] = boundary
    atomic_write(root / 'schedule.json', {'events': [earlier, ongoing]})
    brief = (root / 'briefs/event.md').read_text()
    raw = [raw_event(now, id='event', start=ongoing['start'], end=ongoing['end'])] if still_in_fetch else []
    sources = sources_for(raw, events=lambda minutes: (raw, {'ok': True, 'status': status}))
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    schedule = read_json(root / 'schedule.json')
    assert [{k: e[k] for k in ongoing} for e in schedule['events']] == [ongoing]
    assert {k: current(now, schedule['events']).event[k] for k in ongoing} == ongoing
    assert (root / 'briefs/event.md').read_text() == brief
    before = dict(t0='2026-10-13T09:59:00-05:00', t1='2026-10-13T09:59:20-05:00', text='Earlier meeting')
    assert owned([before], ongoing, schedule['events']) == []
    run(root=root, now=now + timedelta(minutes=1), sources=sources,
        settings={'retention_days': 14}, runner=hermes)
    assert [{k: e[k] for k in ongoing} for e in read_json(root / 'schedule.json')['events']] == [ongoing]


@pytest.mark.parametrize('status', ['ok', 'partial'])
def test_schedule_reconciles_cancelled_and_moved_slots(root, now, hermes, status):
    cancelled = event('cancelled', (now + timedelta(minutes=5)).isoformat())
    moved = event('moved', (now + timedelta(minutes=10)).isoformat())
    ongoing = event()
    atomic_write(root / 'schedule.json', {'events': [cancelled, moved, ongoing]})
    raw = [raw_event(now, id='moved', start=(now + timedelta(hours=2)).isoformat(),
                     end=(now + timedelta(hours=3)).isoformat())]
    sources = sources_for(raw, events=lambda minutes: (raw, {'ok': True, 'status': status}))
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    saved = {e['key']: e for e in read_json(root / 'schedule.json')['events']}
    if status == 'ok':
        assert set(saved) == {'moved'}
        assert saved['moved']['start'] == raw[0]['start']
    else:
        assert set(saved) == {'cancelled', 'moved', 'event'}
        assert saved['moved']['start'] == moved['start']


@pytest.mark.parametrize('status', ['ok', 'partial'])
def test_schedule_ended_event_expiry(root, now, hermes, status):
    cached = [event(str(age), (now - timedelta(hours=1)).isoformat(),
                    (now - timedelta(minutes=age)).isoformat()) for age in [0, 10, 11]]
    atomic_write(root / 'schedule.json', {'events': cached})
    sources = sources_for([], events=lambda minutes: ([], {'ok': True, 'status': status}))
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    assert {e['key'] for e in read_json(root / 'schedule.json')['events']} == {'0', '10'}


def test_failed_calendar_refresh_leaves_schedule_bytes_untouched(root, now, hermes):
    path = root / 'schedule.json'
    before = path.read_bytes()
    sources = sources_for([], events=lambda minutes: ([], {'ok': False, 'status': 'failed'}))
    with pytest.raises(RuntimeError, match='Calendar unavailable'):
        run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    assert path.read_bytes() == before


def test_partial_refresh_preserves_cached_rows_and_freshness(root, now, hermes):
    cached = {'v': 1, 'at': (now - timedelta(minutes=20)).isoformat(),
              'retention_days': 14, 'events': [event(window_start='2026-10-13T09:59:30-05:00')]}
    atomic_write(root / 'schedule.json', cached)
    raw = [raw_event(now)]
    sources = sources_for(raw, events=lambda minutes: (raw, {'ok': True, 'status': 'partial'}))
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    assert read_json(root / 'schedule.json') == cached


def test_daily_retention_reads_settings_and_deletes_mapped_tagged(root, now, hermes, tmp_path):
    (tmp_path / 'xdg/hereby').mkdir(parents=True)
    (tmp_path / 'xdg/hereby/recorder.toml').write_text('retention_days = 2\n')
    old = make_session(root, now - timedelta(days=3), started_at=(now - timedelta(days=3)).isoformat(), state='closed',
                       ended_at=(now - timedelta(days=3)).isoformat())
    atomic_write(root / 'hermes_map' / (old.name + '.jsonl'), json.dumps({'id': 'old-mapped'}) + '\n')
    hermes.ids = {'old-tagged'}
    expired_brief = root / 'briefs/expired.md'
    atomic_write(expired_brief, 'OLD CONTENT')
    os.utime(expired_brief, (0, 0))
    maintenance(root, now, settings=recorder_settings(), runner=hermes)
    assert not old.exists() and not expired_brief.exists() and not hermes.ids
    assert forgotten(root, old.name)
    assert {'old-mapped', 'old-tagged'} <= {argv[3] for argv, _ in hermes.calls if 'delete' in argv}
    assert read_json(root / 'maintenance.json')['date'] == now.date().isoformat()


def test_forgotten_push_removed_on_next_tick_same_day(root, now, hermes):
    sid = next((root / 'sessions').iterdir()).name
    atomic_write(root / 'maintenance.json', {'date': now.date().isoformat()})
    atomic_write(root / 'forgotten.jsonl', json.dumps({'sid': sid, 'at': now.isoformat()}) + '\n')
    maintenance(root, now, settings={'retention_days': 14}, runner=hermes)
    assert not (root / 'sessions' / sid).exists()


def test_vault_people_meetings_actions_project_map(tmp_path):
    vault = tmp_path / 'vault'
    contacts = vault / '06 - Contacts'
    atomic_write(contacts / 'Work/Kim.md', '---\ntypes: [person]\norg: Example\nrole: Lead\nemail: kim@example.test\n---\nKim works here.')
    for index, date in enumerate(['2026-09-28', '2026-09-29', '2026-09-30', '2026-10-01']):
        atomic_write(contacts / f'Meetings/{index}.md', f'''---
date: {date}
people: ["[[Kim]]"]
project: "[[Budget]]"
---
## Summary
The budget is $42,500.
## Action items
- [ ] Send the pricing sheet by 2026-10-02.
- [x] Old completed action.
## Notes
Private irrelevant notes.
''')
    atomic_write(vault / 'Projects/Budget.md', 'PROJECT STATE ' * 300)
    hq = tmp_path / 'hq'
    atomic_write(hq / 'status.md', 'CLIENT HQ STATE ' * 300)
    project_map = tmp_path / 'map.tsv'
    atomic_write(project_map, f'vault_note\tclient\troute\ttarget\tcode_surface\tnote\nProjects/Budget.md\tExample\tx\t{hq}\t\tx\n')
    people, projects, items = vault_context(dict(event(), title='Budget', attendees=[{'email': 'kim@example.test'}]),
                                           load_vault(vault, project_map))
    assert 'Kim, org: Example, role: Lead' in people[0]
    assert any('PROJECT STATE' in text for text in projects)
    assert any('CLIENT HQ STATE' in text for text in projects)
    assert {r.date for r in items} == {'2026-09-29', '2026-09-30', '2026-10-01'}
    assert any(r.kind == 'action_item' and r.due == '2026-10-02' for r in items)
    assert not any('completed action' in r.text or 'irrelevant' in r.text for r in items)


def test_front_matter_block_lists():
    meta, body = front_matter('---\ntypes:\n  - person\npeople:\n  - "[[Kim]]"\n---\nBody')
    assert meta['types'] == ['person'] and meta['people'] == ['[[Kim]]'] and body == 'Body'


def test_brief_limits_email_first_and_recent_eight(now):
    raw = raw_event(now)
    e = dict(event(), title=raw['summary'], attendees=raw['attendees'], raw=raw)
    emails = [{'date': '2026-10-12', 'subject': f'email {i}', 'snippet': 'E' * 2000, 'account': 'fixture'} for i in range(10)]
    sources = sources_for([raw], gmail=lambda terms, attendees: emails)
    brief = build_brief(e, sources, now, (['PERSON' * 1500], [], [Record('old.md', '2026-09-30', 'Confirmed amount 42,500')]))
    assert len(brief.encode()) <= MAX_BYTES
    assert 'Confirmed amount' in brief
    assert sum(r.kind == 'email' for r in records(brief)) <= 8
    sources.gmail = lambda terms, attendees: [{'date': '2026-09-01', 'subject': 'old email'},
                                            {'date': '2026-10-14', 'subject': 'future email'}] + [dict(x, snippet='short') for x in emails]
    brief = build_brief(e, sources, now, ([], [], []))
    assert 'old email' not in brief and 'future email' not in brief
    assert sum(r.kind == 'email' for r in records(brief)) == 8


def test_cron_failure_logs_no_content(monkeypatch, capsys):
    def failure():
        raise RuntimeError('PRIVATE TRANSCRIPT')
    monkeypatch.setattr('live_meeting_brief.run', failure)
    assert main() == 1
    captured = capsys.readouterr()
    assert captured.out == '' and captured.err == 'Meeting brief tick failed.\n'


def test_retention_defaults_to_14_days_and_ignores_config_json(tmp_path):
    atomic_write(tmp_path / 'config.json', {'retention_days': 3})
    assert recorder_settings() == {'retention_days': 14}
    assert config(tmp_path / 'config.json')['retention_days'] == 3


def test_maintenance_retries_failed_deletions_without_mirror(root, now, hermes):
    atomic_write(root / 'maintenance.json', {'date': now.date().isoformat()})
    sid = '20261001-100000-abcd'
    atomic_write(root / 'deletions' / (sid + '.json'), {'ids': ['retained-failed-id']})
    maintenance(root, now, settings={'retention_days': 14}, runner=hermes)
    assert any(argv[3] == 'retained-failed-id' for argv, _ in hermes.calls if 'delete' in argv)
    assert not (root / 'deletions' / (sid + '.json')).exists()


def test_idless_calendar_key_never_contains_title(root, now, hermes):
    raw = raw_event(now)
    raw.pop('id')
    sources = sources_for([raw], key=lambda event, start: event['summary'] + start.isoformat())
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    assert all('PRIVATE' not in e['key'] for e in read_json(root / 'schedule.json')['events'])


def test_shared_brief_included_via_injected_source(now):
    raw = raw_event(now)
    e = dict(event(), title=raw['summary'], attendees=raw['attendees'], raw=raw)
    sources = sources_for([raw], shared=lambda event: Record('shared:commitments', '2026-10-01', 'Send pricing sheet.', 'commitment').render())
    brief = build_brief(e, sources, now, ([], [], []))
    assert any(r.source == 'shared:commitments' and r.kind == 'commitment' for r in records(brief))


def test_orphan_query_files_expire(root, now, hermes):
    query = root / 'queries/orphan-query'
    atomic_write(query, 'SECRET')
    os.utime(query, (0, 0))
    maintenance(root, now, settings={'retention_days': 14}, runner=hermes)
    assert not query.exists()


def test_plain_shared_commitments_become_dated_records(now):
    raw = raw_event(now)
    e = dict(event(), title=raw['summary'], attendees=raw['attendees'], raw=raw)
    sources = sources_for([raw], shared=lambda event: '---\ndate: 2026-10-01\n---\n## Your open commitments\nSend the pricing sheet.')
    brief = build_brief(e, sources, now, ([], [], []))
    assert any(r.source == 'shared:commitments' and r.date == '2026-10-01' and 'pricing sheet' in r.text for r in records(brief))



def test_retention_deletes_expired_mapping_without_mirror(root, now, hermes):
    sid = '20261001-100000-abcd'
    mapping = root / 'hermes_map' / (sid + '.jsonl')
    atomic_write(mapping, json.dumps({'id': 'orphan-mapped', 'at': (now - timedelta(days=3)).isoformat()}) + '\n')
    hermes.ids.add('orphan-tagged')
    maintenance(root, now, settings={'retention_days': 2}, runner=hermes)
    assert forgotten(root, sid) and not mapping.exists()
    assert not hermes.ids
    assert {'orphan-mapped', 'orphan-tagged'} <= {argv[3] for argv, _ in hermes.calls if 'delete' in argv}


def test_forgotten_mapping_without_mirror_is_deleted_on_same_day_tick(root, now, hermes):
    sid = '20261001-100000-abcd'
    atomic_write(root / 'maintenance.json', {'date': now.date().isoformat()})
    atomic_write(root / 'forgotten.jsonl', json.dumps({'sid': sid, 'at': now.isoformat()}) + '\n')
    mapping = root / 'hermes_map' / (sid + '.jsonl')
    atomic_write(mapping, '{"id":"orphan-mapped"}\n')
    maintenance(root, now, settings={'retention_days': 14}, runner=hermes)
    assert not mapping.exists()
    assert any(argv[3] == 'orphan-mapped' for argv, _ in hermes.calls if 'delete' in argv)


def test_others_counts_the_voices_on_the_other_side_of_the_call(root, now, hermes):
    attendees = [{'name': 'Kim', 'email': 'kim@example.test'}, {'name': 'Lee', 'email': 'lee@example.test'},
                 {'email': 'sam@example.test', 'self': True}, {'email': 'sam.lee@example.org'},
                 {'email': 'pat@example.test', 'response': 'declined'},
                 {'name': 'Room 4', 'email': 'c_123@resource.calendar.google.com'}]
    run(root=root, now=now, sources=sources_for([raw_event(now, attendees=attendees)], emails=frozenset({'sam.lee@example.org'})),
        settings={'retention_days': 14}, runner=hermes)
    upcoming = next(e for e in read_json(root / 'schedule.json')['events'] if e['key'] == 'upcoming')
    assert (upcoming['attendee_count'], upcoming['others']) == (6, 2)


def far_event(now, **changes):
    return raw_event(now, **{**dict(id='far', summary='Weekly sync', start=(now + timedelta(hours=27)).isoformat(),
                                    end=(now + timedelta(hours=28)).isoformat()), **changes})


def test_next_records_first_meeting_beyond_24h_without_changing_events(root, now, hermes):
    raw = [far_event(now, id='later', start=(now + timedelta(days=3)).isoformat(), end=(now + timedelta(days=3, hours=1)).isoformat()),
           far_event(now),
           far_event(now, id='solo', start=(now + timedelta(hours=26)).isoformat(), end=(now + timedelta(hours=27)).isoformat(),
                     attendees=[{'email': 'sam@example.test'}])]
    asked = []
    sources = sources_for(raw, events=lambda minutes: (asked.append(minutes), (raw, {'ok': True, 'status': 'ok'}))[1])
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    schedule = read_json(root / 'schedule.json')
    assert asked == [7 * 24 * 60]
    assert schedule['events'] == []
    assert schedule['next'] == {'key': 'far', 'start': far_event(now)['start'], 'end': far_event(now)['end'], 'has_conference': False,
                                'attendee_count': 2, 'title': 'Weekly sync', 'meeting_url': None, 'event_id': 'far',
                                'people': ['PRIVATE NAME', 'sam']}
    assert not (root / 'briefs/far.md').exists()


def test_next_absent_when_a_meeting_is_within_24h(root, now, hermes):
    raw = [far_event(now), raw_event(now, start=(now + timedelta(hours=20)).isoformat(), end=(now + timedelta(hours=21)).isoformat())]
    run(root=root, now=now, sources=sources_for(raw), settings={'retention_days': 14}, runner=hermes)
    schedule = read_json(root / 'schedule.json')
    assert [e['key'] for e in schedule['events']] == ['upcoming'] and 'next' not in schedule


def test_next_dropped_once_its_meeting_enters_the_24h_window(root, now, hermes):
    atomic_write(root / 'schedule.json', {'v': 1, 'events': [], 'next': {'key': 'far'}})
    raw = [far_event(now, start=(now + timedelta(hours=23)).isoformat(), end=(now + timedelta(hours=24)).isoformat())]
    run(root=root, now=now, sources=sources_for(raw), settings={'retention_days': 14}, runner=hermes)
    schedule = read_json(root / 'schedule.json')
    assert [e['key'] for e in schedule['events']] == ['far'] and 'next' not in schedule


def test_partial_refresh_keeps_cached_next(root, now, hermes):
    cached = {'v': 1, 'at': now.isoformat(), 'retention_days': 14, 'events': [], 'next': {'key': 'far'}}
    atomic_write(root / 'schedule.json', cached)
    raw = [far_event(now, id='other', start=(now + timedelta(days=2)).isoformat(), end=(now + timedelta(days=2, hours=1)).isoformat())]
    sources = sources_for(raw, events=lambda minutes: (raw, {'ok': True, 'status': 'partial'}))
    run(root=root, now=now, sources=sources, settings={'retention_days': 14}, runner=hermes)
    assert read_json(root / 'schedule.json') == cached
