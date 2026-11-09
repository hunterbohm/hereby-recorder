from datetime import timedelta

from conftest import event
from live_meeting_brief import Sources, load_vault, meeting_url, run, vocabulary
from lml_common import atomic_write, dt, read_json

TSV = 'vault_note\tclient\troute\ttarget\tcode_surface\tnote\n'


def write_vault(tmp_path):
    vault = tmp_path / 'vault'
    contacts = vault / '06 - Contacts'
    atomic_write(contacts / 'Work/Kay Porter.md', '---\ntypes: [person]\norg: "[[Example Co]]"\nemail: kim@example.test\n---\nKim.')
    atomic_write(contacts / 'Work/Lee Park.md', '---\ntypes:\n  - person\norg: Example Co\nemail: lee@example.test\n---\nLee.')
    atomic_write(contacts / 'Work/Not A Person.md', '---\ntypes: [company]\nemail: kim@example.test\n---\n')
    atomic_write(contacts / 'Meetings/2026-10-13 1000 Budget.md',
                 '---\ndate: 2026-10-13\nevent_id: "evt-1"\nproject: "[[Budget|Budget work]]"\norg: "[[Example Co]]"\n---\n')
    atomic_write(contacts / 'Meetings/2026-10-01 1000 Earlier.md',
                 '---\ndate: 2026-10-01\npeople: ["[[Kay Porter]]"]\nproject: [[Ops Relief]]\n---\n## Summary\nEarlier.')
    project_map = tmp_path / 'map.tsv'
    atomic_write(project_map, TSV + 'Projects/Budget.md\tExample\tclient-hq\t-\t-\tx\n')
    return vault, project_map


def upcoming(**changes):
    return {**event(), 'title': 'Budget', 'event_id': 'evt-1',
            'attendees': [{'name': 'Kay Porter', 'email': 'kim@example.test'},
                          {'name': 'kay porter', 'email': 'kim@example.test'},
                          {'name': 'lee', 'email': 'lee@example.test'},
                          {'name': 'Sam', 'email': 'sam@example.test'}], **changes}


def test_vocabulary_orders_people_companies_projects_and_dedupes(tmp_path):
    vault, project_map = write_vault(tmp_path)
    terms = vocabulary(upcoming(), load_vault(vault, project_map))
    assert terms == ['Kay Porter', 'Sam', 'Lee Park', 'Example Co', 'Budget', 'Ops Relief', 'Example']
    assert not any('@' in term or '[' in term for term in terms)


def test_vocabulary_caps_at_one_hundred_in_order(tmp_path):
    attendees = [{'name': f'Person {i}', 'email': ''} for i in range(150)]
    terms = vocabulary(upcoming(attendees=attendees), load_vault(tmp_path / 'missing', tmp_path / 'missing.tsv'))
    assert terms == [f'Person {i}' for i in range(100)]


def test_meeting_url_prefers_hangout_then_video_entry_then_call_link_in_location():
    video = {'conferenceData': {'entryPoints': [{'entryPointType': 'phone', 'uri': 'tel:+1555'},
                                                {'entryPointType': 'video', 'uri': 'https://zoom.us/j/9'}]}}
    assert meeting_url({'hangoutLink': 'https://meet.google.com/abc', **video}) == 'https://meet.google.com/abc'
    assert meeting_url(video) == 'https://zoom.us/j/9'
    assert meeting_url({'location': 'Join: https://us02web.zoom.us/j/123?pwd=x (Zoom)'}) == 'https://us02web.zoom.us/j/123?pwd=x'
    assert meeting_url({'location': 'https://teams.microsoft.com/l/meetup-join/1'}) == 'https://teams.microsoft.com/l/meetup-join/1'
    assert meeting_url({'location': 'https://maps.example.test/office'}) is None
    assert meeting_url({'location': '123 Main St', 'conferenceData': 'bad'}) is None


def sources(raw, vault, **changes):
    return Sources(**changes, events=lambda minutes: (raw, {'ok': True, 'status': 'ok'}), attendees=lambda e: e['attendees'],
                   key=lambda e, start: e['id'], parse_dt=lambda value: dt(value), terms=lambda e, attendees: [],
                   gmail=lambda terms, attendees: [], vault=vault, shared=lambda e: '')


def test_tick_reads_the_vault_once_and_writes_vocabulary_per_event(root, now, hermes, tmp_path):
    vault, project_map = write_vault(tmp_path)
    loads = []

    def counted():
        loads.append(1)
        return load_vault(vault, project_map)
    attendees = [{'name': 'Kay Porter', 'email': 'kim@example.test'}, {'name': 'Sam', 'email': 'sam@example.test'}]
    raw = [{'id': f'evt-{i}', 'summary': 'Budget', 'attendees': attendees, 'hangoutLink': 'https://meet.google.com/abc',
            'start': (now + timedelta(minutes=5 + 60 * i)).isoformat(), 'end': (now + timedelta(minutes=35 + 60 * i)).isoformat()}
           for i in range(1, 4)]
    raw[0]['start'] = (now + timedelta(minutes=5)).isoformat()
    run(root=root, now=now, sources=sources(raw, counted), settings={'retention_days': 14}, runner=hermes)
    assert len(loads) == 1
    assert (root / 'briefs/evt-1.md').exists()
    saved = {e['key']: e for e in read_json(root / 'schedule.json')['events']}
    assert saved['evt-1']['vocabulary'] == ['Kay Porter', 'Sam', 'Example Co', 'Budget', 'Ops Relief', 'Example']
    assert saved['evt-2']['meeting_url'] == 'https://meet.google.com/abc' and saved['evt-2']['event_id'] == 'evt-2'


def test_old_cached_events_without_new_fields_survive_a_tick(root, now, hermes, tmp_path):
    old = event('old', (now - timedelta(hours=1)).isoformat(), (now - timedelta(minutes=5)).isoformat())
    atomic_write(root / 'schedule.json', {'v': 1, 'at': now.isoformat(), 'events': [old]})
    run(root=root, now=now, sources=sources([], lambda: load_vault(tmp_path / 'missing', tmp_path / 'missing.tsv')),
        settings={'retention_days': 14}, runner=hermes)
    saved = read_json(root / 'schedule.json')['events']
    assert [(e['key'], e['title'], e['meeting_url'], e['event_id'], e['vocabulary']) for e in saved] == [('old', None, None, None, [])]


def test_schedule_events_list_the_attendees_besides_the_user(root, now, hermes, tmp_path):
    vault, project_map = write_vault(tmp_path)
    attendees = [{'name': 'lee', 'email': 'lee@example.test'}, {'name': 'Sam', 'email': 'sam.lee@example.org'},
                 {'name': 'Sam Lee', 'email': 'sam@example.com'}, {'name': 'Me', 'email': 'me@x.test', 'self': True},
                 {'name': 'Priya Shah', 'email': 'priya@meridian.test'}, {'name': '', 'email': 'jo@x.test'}]
    raw = [{'id': 'evt-1', 'summary': 'Budget', 'attendees': attendees,
            'start': (now + timedelta(minutes=5)).isoformat(), 'end': (now + timedelta(minutes=35)).isoformat()},
           {'id': 'evt-2', 'summary': 'Dana 1:1', 'attendees': attendees[1:3] + [{'name': 'Dana Whitfield', 'email': 'dana@orchard.test'}],
            'start': (now + timedelta(hours=2)).isoformat(), 'end': (now + timedelta(hours=3)).isoformat()}]
    run(root=root, now=now, sources=sources(raw, lambda: load_vault(vault, project_map), emails=frozenset({'sam.lee@example.org'}),
                                         domains=frozenset({'example.com'})),
        settings={'retention_days': 14}, runner=hermes)
    saved = {e['key']: e for e in read_json(root / 'schedule.json')['events']}
    assert saved['evt-1']['people'] == ['Lee Park', 'Priya Shah', 'jo']
    assert saved['evt-2']['people'] == ['Dana Whitfield']
