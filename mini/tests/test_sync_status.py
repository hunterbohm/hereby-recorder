import json
import os
import shutil
import subprocess
import time
from datetime import timedelta
from pathlib import Path

import pytest

from conftest import event, make_session
from lml_common import atomic_write, dt, now_local, read_json

MINI = Path(__file__).resolve().parents[1]
COMMAND = 'live-meeting-sync-status'
BEAT = {'at': '2026-10-24T07:53:23.123Z', 'app_version': '2.0.0', 'state': 'recording',
        'sid': '20261024-075000-abcd', 'mic_ok': True, 'audio_ok': False}


@pytest.fixture
def env(tmp_path):
    values = {key: value for key, value in os.environ.items() if key != 'PYTHONPATH'}
    return {**values, 'MEETING_PROCESSING_STATE': str(tmp_path / 'processing.json'),
            'CALENDAR_SYNC_STATE': str(tmp_path / 'calendar-sync.json'), 'MEETING_VAULT': str(tmp_path / 'vault')}


def sync(env, stdin, directory=MINI):
    return subprocess.run([str(directory / COMMAND)], input=stdin, capture_output=True, env=env, timeout=20)


def test_valid_heartbeat_is_stored_and_answered_with_schedule_and_status(env):
    root = Path(env['LML_ROOT'])
    upcoming = event('next', (now_local() + timedelta(minutes=20)).isoformat(timespec='seconds'),
                     (now_local() + timedelta(minutes=50)).isoformat(timespec='seconds'), title='Budget')
    schedule = {'v': 1, 'at': now_local().isoformat(), 'retention_days': 14, 'events': [upcoming]}
    atomic_write(root / 'schedule.json', schedule)
    before = now_local().replace(microsecond=0)
    result = sync(env, json.dumps({**BEAT, 'extra': 'ignored'}).encode())
    assert result.returncode == 0, result.stderr
    [line] = result.stdout.decode().splitlines()
    reply = json.loads(line)
    assert set(reply) == {'schedule', 'status'} and reply['schedule'] == schedule
    assert reply['status'] == read_json(root / 'status.json')
    assert reply['status']['next']['title'] == 'Budget' and reply['status']['recent'] == []
    stored = read_json(root / 'heartbeat.json')
    assert {k: v for k, v in stored.items() if k != 'received_at'} == BEAT
    assert before <= dt(stored['received_at']) <= now_local()


def test_missing_schedule_is_an_empty_object(env):
    result = sync(env, json.dumps({**BEAT, 'sid': None, 'state': 'idle'}).encode())
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['schedule'] == {}


@pytest.mark.parametrize('stdin', [
    b'', b'not json', b'\xff', b'[]', b'"text"', json.dumps({k: v for k, v in BEAT.items() if k != 'sid'}).encode(),
    json.dumps({**BEAT, 'state': 'stopped'}).encode(), json.dumps({**BEAT, 'state': ['idle']}).encode(),
    json.dumps({**BEAT, 'sid': 5}).encode(), json.dumps({**BEAT, 'mic_ok': 'yes'}).encode(),
    json.dumps({**BEAT, 'audio_ok': 1}).encode(), json.dumps({**BEAT, 'at': '2026-10-24T07:53:23'}).encode(),
    json.dumps({**BEAT, 'at': 20261024}).encode(), json.dumps({**BEAT, 'app_version': None}).encode()])
def test_invalid_heartbeat_exits_2_and_writes_nothing(env, stdin):
    root = Path(env['LML_ROOT'])
    atomic_write(root / 'schedule.json', {'events': []})
    before = sorted(p.name for p in root.iterdir())
    result = sync(env, stdin)
    assert (result.returncode, result.stdout) == (2, b'')
    assert sorted(p.name for p in root.iterdir()) == before


def test_command_runs_through_a_symlink_in_another_directory(tmp_path, env):
    links, copies = tmp_path / 'links', tmp_path / 'copies'
    links.mkdir()
    copies.mkdir()
    (links / COMMAND).symlink_to(MINI / COMMAND)
    shutil.copy2(MINI / COMMAND, copies / COMMAND)
    linked = subprocess.run([str(links / COMMAND)], input=json.dumps(BEAT).encode(), capture_output=True,
                            cwd=tmp_path, env=env, timeout=20)
    copied = subprocess.run([str(copies / COMMAND)], input=json.dumps(BEAT).encode(), capture_output=True,
                            cwd=tmp_path, env=env, timeout=20)
    assert linked.returncode == 0 and json.loads(linked.stdout)['status']['v'] == 1, linked.stderr
    assert copied.returncode == 1 and b'ModuleNotFoundError' in copied.stderr


def test_every_reply_is_stamped_at_its_call_and_carries_the_panel_fields(env):
    root, vault = Path(env['LML_ROOT']), Path(env['MEETING_VAULT'])
    now = now_local()
    start = (now + timedelta(minutes=20)).replace(second=0, microsecond=0)
    name = f'06 - Contacts/Meetings/{start:%Y-%m-%d %H%M} Budget.md'
    atomic_write(root / 'schedule.json', {'events': [event('next', start.isoformat(), (start + timedelta(minutes=30)).isoformat(),
                                                           title='Budget', event_id='evt')]})
    atomic_write(env['CALENDAR_SYNC_STATE'], {'events': {'evt': {'path': name}}})
    atomic_write(vault / name, f'---\nstart: {start.isoformat()}\n---\n')
    end = now - timedelta(minutes=5)
    session = make_session(root, now, sid='20261024-070000-abcd', state='closed', started_at=(end - timedelta(minutes=25)).isoformat(),
                           ended_at=end.isoformat(), heartbeat_at=end.isoformat())
    atomic_write(session / 'marks.jsonl', ''.join(json.dumps({'at': end.isoformat(), 'note': n}) + '\n' for n in (None, 'price')))
    atomic_write(root / 'status.json', {'v': 1, 'at': '2026-01-01T00:00:00-06:00', 'next': None, 'recent': []})
    stamps = []
    for attempt in range(2):
        if attempt:
            time.sleep(1.1)
        before = now_local().replace(microsecond=0)
        result = sync(env, json.dumps(BEAT).encode())
        after = now_local()
        assert result.returncode == 0, result.stderr
        feed = json.loads(result.stdout)['status']
        assert feed == read_json(root / 'status.json')
        assert before <= dt(feed['at']) <= after
        stamps.append(dt(feed['at']))
        [recent] = feed['recent']
        assert (recent['duration_s'], recent['marks']) == (1500, 2)
        assert feed['next']['note_url'] == ('obsidian://open?vault=vault&file=06%20-%20Contacts%2FMeetings%2F'
                                            + f'{start:%Y-%m-%d}%20{start:%H%M}%20Budget')
    assert stamps[1] > stamps[0]
