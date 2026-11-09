import subprocess
import sys
from datetime import timedelta
from pathlib import Path

import pytest

from conftest import event, make_session
from live_meeting_health import check
from lml_common import atomic_write, now_local, read_json

MINI = Path(__file__).resolve().parents[1]


@pytest.fixture
def root(tmp_path, now):
    root = tmp_path / 'live-meeting-test'
    schedule(root, now)
    return root


def schedule(root, now, *events):
    events = events or [call(now)]
    atomic_write(root / 'schedule.json', {'v': 1, 'at': now.isoformat(), 'events': list(events)})


def call(now, key='budget', minutes=5, **changes):
    start = now + timedelta(minutes=minutes)
    return {**event(key, start.isoformat(), (start + timedelta(minutes=30)).isoformat(), title='Budget sync',
                    meeting_url='https://meet.google.com/abc'), **changes}


def heartbeat(root, now, *, age=30, **changes):
    atomic_write(root / 'heartbeat.json', {'at': now.isoformat(), 'app_version': '2.0.0', 'state': 'idle', 'sid': None,
                                           'mic_ok': True, 'audio_ok': True,
                                           'received_at': (now - timedelta(seconds=age)).isoformat(), **changes})


def test_healthy_heartbeat_sends_nothing(root, now):
    heartbeat(root, now)
    assert check(root, now) == ''
    assert not (root / 'health.json').exists()


def test_missing_heartbeat_alerts_once_per_meeting(root, now):
    assert check(root, now) == 'Recorder problem before Budget sync at 10:20 AM: the recorder on the MacBook has not checked in.'
    assert check(root, now + timedelta(minutes=1)) == ''
    schedule(root, now, call(now), call(now, 'later', minutes=8, title='Kim intro'))
    assert check(root, now + timedelta(minutes=1)) == (
        'Recorder problem before Kim intro at 10:23 AM: the recorder on the MacBook has not checked in.')


def test_stale_heartbeat_alerts_with_its_age(root, now):
    heartbeat(root, now, age=170)
    assert check(root, now) == ''
    heartbeat(root, now, age=7 * 60 + 10)
    assert check(root, now) == ('Recorder problem before Budget sync at 10:20 AM: '
                                'the recorder on the MacBook last checked in 7 minutes ago.')


@pytest.mark.parametrize('changes,missing', [({'mic_ok': False}, 'microphone'), ({'audio_ok': False}, 'system audio'),
                                             ({'mic_ok': False, 'audio_ok': False}, 'microphone or system audio')])
def test_missing_access_alerts(root, now, changes, missing):
    heartbeat(root, now, **changes)
    assert check(root, now) == f'Recorder problem before Budget sync at 10:20 AM: the recorder has no {missing} access.'


def test_meeting_without_a_call_link_never_alerts(root, now):
    schedule(root, now, call(now, meeting_url=None, has_conference=False))
    assert check(root, now) == ''
    schedule(root, now, call(now, meeting_url=None, has_conference=True))
    assert check(root, now) != ''


@pytest.mark.parametrize('minutes,alerts', [(0, False), (0.5, True), (10, True), (10.5, False), (-5, False)])
def test_only_calls_starting_within_ten_minutes(root, now, minutes, alerts):
    schedule(root, now, call(now, minutes=minutes))
    assert check(root, now).startswith('Recorder problem before') == alerts


def test_dry_run_prints_and_keeps_no_state(root, now, capsys):
    before = sorted(p.name for p in root.iterdir())
    assert check(root, now, dry_run=True) == ''
    assert capsys.readouterr().err == ('[ALERT WOULD SEND] Recorder problem before Budget sync at 10:20 AM: '
                                       'the recorder on the MacBook has not checked in.\n')
    assert sorted(p.name for p in root.iterdir()) == before
    assert check(root, now) != ''


def test_alert_record_is_pruned_after_two_days(root, now):
    atomic_write(root / 'health.json', {'alerted': {'old': (now - timedelta(days=2, minutes=1)).isoformat(),
                                                    'recent': (now - timedelta(days=1)).isoformat(), 'bad': 'x'}})
    check(root, now)
    assert set(read_json(root / 'health.json')['alerted']) == {'recent', 'budget'}


def test_unreadable_schedule_and_heartbeat_do_not_raise(root, now):
    atomic_write(root / 'heartbeat.json', '[]')
    atomic_write(root / 'health.json', '{"alerted": []}')
    assert check(root, now) != ''
    atomic_write(root / 'schedule.json', '{"events": [{"key": "no start"}, 5]}')
    assert check(root, now) == ''


def test_main_prints_the_alert_and_print_flag_only_previews_it(tmp_path, monkeypatch):
    root, now = tmp_path / 'live-meeting-test', now_local()
    schedule(root, now, call(now))
    monkeypatch.setenv('LML_ROOT', str(root))

    def run(*args):
        return subprocess.run([sys.executable, str(MINI / 'live_meeting_health.py'), *args], capture_output=True, text=True, timeout=20)
    preview = run('--print')
    assert (preview.returncode, preview.stdout) == (0, '')
    assert preview.stderr.startswith('[ALERT WOULD SEND] Recorder problem before Budget sync at ')
    assert not (root / 'health.json').exists()
    sent = run()
    assert (sent.returncode, sent.stdout, sent.stderr) == (0, preview.stderr.removeprefix('[ALERT WOULD SEND] '), '')
    assert run().stdout == ''


def underway_call(now, minutes_ago, **changes):
    return call(now, key='kim', minutes=-minutes_ago, title='Kim weekly', **changes)


def test_call_underway_with_no_recording_alerts_once(root, now):
    heartbeat(root, now)
    schedule(root, now, underway_call(now, 4))
    assert check(root, now) == ('The recorder is not recording Kim weekly (started 10:11 AM): no session is running. '
                                "If you are on the call, press Start in the recorder's menu bar.")
    assert check(root, now + timedelta(minutes=1)) == ''


def test_call_underway_and_recording_sends_nothing(root, now):
    heartbeat(root, now)
    schedule(root, now, underway_call(now, 4))
    make_session(root, now)
    assert check(root, now) == ''


def test_failed_session_during_a_call_alerts(root, now):
    heartbeat(root, now)
    schedule(root, now, underway_call(now, 4))
    make_session(root, now, state='failed', ended_at=now.isoformat())
    assert 'not recording Kim weekly' in check(root, now)


@pytest.mark.parametrize('minutes_ago,alerts', [(2.5, False), (3, True), (29, True), (31, False)])
def test_only_after_three_minutes_and_before_the_end(root, now, minutes_ago, alerts):
    heartbeat(root, now)
    schedule(root, now, underway_call(now, minutes_ago))
    assert bool(check(root, now)) == alerts


def test_call_underway_with_a_stale_recorder_names_the_cause(root, now):
    heartbeat(root, now, age=600)
    schedule(root, now, underway_call(now, 4))
    assert 'last checked in 10 minutes ago' in check(root, now)


def test_call_underway_without_a_link_never_alerts(root, now):
    heartbeat(root, now)
    schedule(root, now, underway_call(now, 4, meeting_url=None, has_conference=False))
    assert check(root, now) == ''


def test_recording_without_mic_audio_alerts_once_per_session(root, now):
    schedule(root, now, call(now, minutes=60))
    heartbeat(root, now, state='recording', sid='s1', mic_ok=False)
    assert check(root, now) == ('The recorder is recording but is getting no microphone audio. '
                                "Check the input device in Sound settings, or press Stop and then Start in the recorder's menu bar.")
    assert check(root, now + timedelta(minutes=1)) == ''
    heartbeat(root, now, state='recording', sid='s2', mic_ok=False)
    assert 'no microphone audio' in check(root, now)


def test_recording_heartbeat_that_is_stale_or_healthy_sends_no_capture_alert(root, now):
    heartbeat(root, now, state='recording', sid='s1', mic_ok=False, age=600)
    assert 'getting no' not in check(root, now)
    heartbeat(root, now, state='recording', sid='s1')
    assert check(root, now) == ''


def test_malformed_session_does_not_hide_a_missed_call(root, now):
    heartbeat(root, now)
    schedule(root, now, underway_call(now, 4))
    atomic_write(root / 'sessions' / 'broken' / 'meta.json', [])
    atomic_write(root / 'sessions' / 'broken2' / 'meta.json', {'state': 'active'})
    atomic_write(root / 'sessions' / 'broken2' / 'live.json', [])
    assert 'not recording Kim weekly' in check(root, now)


def test_malformed_live_file_still_counts_a_live_session(root, now):
    heartbeat(root, now)
    schedule(root, now, underway_call(now, 4))
    path = make_session(root, now)
    atomic_write(path / 'live.json', [])
    assert check(root, now) == ''
