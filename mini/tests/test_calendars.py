import json
from datetime import timedelta
from types import SimpleNamespace

import pytest

import live_meeting_brief
from live_meeting_brief import Sources, Vault, normalize_events, people, run
from lml_common import dt, read_json
from lml_settings import Settings, SettingsError, load


def fake_collector(fetched, raw):
    def collect_events(minutes):
        fetched.append(list(module.ACCOUNTS))
        return raw, {'ok': True, 'status': 'ok'}
    module = SimpleNamespace(ACCOUNTS=['gmail-only@example.test'], collect_events=collect_events,
                             normalize_attendees=lambda e: e.get('attendees', []), event_key=lambda e, start: e['id'],
                             parse_event_dt=lambda value: dt(value) if value and 'T' in str(value) else None,
                             extract_terms=lambda e, attendees: [], collect_gmail_context=lambda terms, attendees: [])
    return module


def write(tmp_path, name, text):
    file = tmp_path / name
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(text)
    return file


def test_no_calendars_are_named_by_default(tmp_path):
    assert load(tmp_path / 'hereby/recorder.toml').calendars == ()


def test_calendars_in_recorder_toml_are_normalised(tmp_path):
    file = write(tmp_path, 'hereby/recorder.toml', 'calendars = [" Ana@Example.test ", "bo@example.test", "ana@example.test"]\n')
    assert load(file).calendars == ('ana@example.test', 'bo@example.test')


@pytest.mark.parametrize('value', ['"ana@example.test"', '["ana@example.test", 7]', '["not-an-address"]'])
def test_a_bad_calendars_value_names_its_field(tmp_path, value):
    file = write(tmp_path, 'hereby/recorder.toml', f'calendars = {value}\n')
    with pytest.raises(SettingsError, match='calendars'):
        load(file)


def test_config_json_calendars_name_no_one(tmp_path):
    write(tmp_path, 'live-meeting/config.json', json.dumps({'calendars': ['old@example.test']}))
    assert load(tmp_path / 'hereby/recorder.toml').calendars == ()
    assert load(write(tmp_path, 'hereby/recorder.toml', 'retention_days = 7\n')).calendars == ()
    assert load(write(tmp_path, 'hereby/recorder.toml', 'calendars = ["New@example.test"]\n')).calendars == ('new@example.test',)


def test_collector_fetches_the_configured_calendars_and_restores_its_own(monkeypatch):
    fetched = []
    module = fake_collector(fetched, [])
    monkeypatch.setattr(live_meeting_brief, 'collectors', lambda collector: module)
    sources = Sources.production(Settings(calendars=('ana@example.test', 'bo@example.test')))
    sources.events(60)
    assert fetched == [['ana@example.test', 'bo@example.test']]
    assert module.ACCOUNTS == ['gmail-only@example.test']


def test_collector_keeps_its_own_accounts_when_none_are_configured(monkeypatch):
    fetched = []
    module = fake_collector(fetched, [])
    monkeypatch.setattr(live_meeting_brief, 'collectors', lambda collector: module)
    Sources.production(Settings()).events(60)
    assert fetched == [['gmail-only@example.test']]


def test_tick_reads_the_calendars_from_the_settings_file_and_lists_a_second_account_event(root, now, hermes, monkeypatch, tmp_path):
    fetched = []
    raw = [{'id': 'pp-only', 'summary': 'Scoping call', 'source_account': 'ana@example.test',
            'attendees': [{'email': 'ana@example.test', 'name': 'Ana'}, {'email': 'kim@client.test', 'name': 'Kim'}],
            'start': (now + timedelta(minutes=5)).isoformat(), 'end': (now + timedelta(minutes=35)).isoformat()}]
    monkeypatch.setattr(live_meeting_brief, 'collectors', lambda collector: fake_collector(fetched, raw))
    write(tmp_path, 'xdg/hereby/recorder.toml', 'calendar_collector = "~/collect.py"\ncalendars = ["ana@example.test", "bo@example.test"]\n')
    run(root=root, now=now, runner=hermes)
    assert fetched == [['ana@example.test', 'bo@example.test']]
    saved = {e['key']: e for e in read_json(root / 'schedule.json')['events']}
    assert (saved['pp-only']['title'], saved['pp-only']['others'], saved['pp-only']['people']) == ('Scoping call', 1, ['Kim'])


def test_a_configured_calendar_address_is_never_the_other_side():
    attendees = [{'email': 'ana@example.test', 'name': 'Ana'}, {'email': 'kim@client.test', 'name': 'Kim'}]
    raw = [{'id': 'e', 'summary': 'Call', 'start': '2026-10-13T11:00:00-05:00', 'end': '2026-10-13T11:30:00-05:00',
            'attendees': attendees}]
    base = dict(events=None, attendees=lambda e: e['attendees'], key=lambda e, start: e['id'], parse_dt=dt, terms=None, gmail=None)
    assert normalize_events(raw, Sources(**base))[0]['others'] == 2
    configured = Sources(**base, emails=frozenset({'ana@example.test'}))
    event = normalize_events(raw, configured)[0]
    assert event['others'] == 1
    assert people(event, Vault(), configured.emails) == ['Kim']
