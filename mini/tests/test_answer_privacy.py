import json
import os
import stat
import subprocess
import sys
import threading
import time
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest

from conftest import event, make_session, part, row
from live_answer import NO_MEETING, answer, context
from live_meeting_nudge import tick
from lml_common import (atomic_write, config, dt, forgotten, read_json, read_jsonl,
                        select_session)
from lml_hermes import header, CallFailed, call, forget, run_command, session_ids
from lml_records import Record
from test_nudge import candidate


@pytest.mark.parametrize('age,live', [(89, True), (90, False), (-1, False)])
def test_heartbeat_boundary(root, now, age, live):
    make_session(root, now - timedelta(seconds=age))
    assert bool(select_session(root, now)) == live


@pytest.mark.parametrize('beat,live', [
    ({}, True), ({'state': 'paused'}, True), ({'age': 90}, False), ({'age': -1}, False),
    ({'state': 'idle'}, False), ({'state': 'armed'}, False), ({'sid': '20261013-090000-other'}, False),
    ({'sid': None}, False), ({'session_state': 'closed'}, False), ({'received_at': 'soon'}, False)])
def test_mac_heartbeat_naming_the_session_keeps_it_live(root, now, beat, live):
    make_session(root, now - timedelta(minutes=5), state=beat.pop('session_state', 'active'))
    received = (now - timedelta(seconds=beat.pop('age', 89))).isoformat()
    atomic_write(root / 'heartbeat.json', {'at': now.isoformat(), 'app_version': '2.0.0', 'state': 'recording',
                                           'sid': '20261013-100000-abcd', 'mic_ok': True, 'audio_ok': True,
                                           'received_at': received, **beat})
    assert bool(select_session(root, now)) == live


@pytest.mark.parametrize('heartbeat', ['[]', '"text"', '{"received_at": 5}', '{not json'])
def test_unreadable_mac_heartbeat_is_not_live_and_not_an_error(root, now, heartbeat):
    make_session(root, now - timedelta(minutes=5))
    atomic_write(root / 'heartbeat.json', heartbeat)
    assert select_session(root, now) is None
    assert select_session(root, now - timedelta(minutes=5)).sid == '20261013-100000-abcd'


def test_recent_ended_selection_and_cutoff(root, now, hermes):
    make_session(root, now, state='closed', ended_at=(now - timedelta(minutes=29)).isoformat())
    assert 'Session ended at 09:46' in context(root, select_session(root, now, recent=True), now, 'Budget?')
    make_session(root, now - timedelta(minutes=30), state='closed', ended_at=(now - timedelta(minutes=30)).isoformat())
    assert answer('Budget?', root=root, now=now, runner=hermes) == NO_MEETING
    assert not hermes.calls


def test_no_session_no_call(tmp_path, now, hermes):
    assert answer('Budget?', root=tmp_path, now=now, runner=hermes) == NO_MEETING
    assert not hermes.calls


def test_test_session_answer_only_in_test_root(root, tmp_path, now, hermes):
    make_session(root, now, test=True)
    assert answer('Budget?', root=root, now=now, runner=hermes) == 'Budget answer.'
    prod = tmp_path / 'production'
    make_session(prod, now, test=True)
    assert answer('Budget?', root=prod, now=now, runner=hermes) == NO_MEETING


def test_answer_partial_annotation_and_boundary_context(root, now, hermes):
    make_session(root, now, rows=[], partials={'me': row(parts=[part('25 for phase one')])})
    atomic_write(root / 'briefs/event.md', Record('last.md', '2026-09-30', 'Budget is $42,500.').render())
    assert answer('What amount?', root=root, now=now, runner=hermes) == 'Budget answer.'
    prompt = hermes.prompts[0]
    assert '[10:14:00] me: 25⟨unconfirmed⟩' in prompt
    assert 'may be spoken shorthand for $42,500 (brief, 2026-09-30)' in prompt
    assert '(still being transcribed)' in prompt
    assert 'Never state an ⟨unconfirmed⟩ number as fact' in prompt


def test_context_reads_finals_from_the_transcript_not_live_json(root, now):
    session = select_session(root, now)
    live = read_json(session.path / 'live.json')
    atomic_write(session.path / 'live.json', {**live, 'finals': [row(text='STALE LIVE FINAL')]})
    atomic_write(session.path / 'transcript.jsonl', json.dumps(row(text='The durable budget is $80,000.')) + '\n')
    packet = context(root, select_session(root, now), now, 'Budget?')
    assert '[10:14:00] me: The durable budget is $80,000.' in packet
    assert 'STALE LIVE FINAL' not in packet and '70,000' not in packet


def window_row(text, seq, end):
    return row(seq=seq, parts=[part(text, (dt(end) - timedelta(seconds=5)).isoformat(), end)])


def test_rows_are_transcript_finals_from_the_last_15_minutes_plus_live_partials(root, now):
    rows = [window_row('Just outside', 1, '2026-10-13T09:59:59-05:00'), window_row('Exactly 15 minutes', 2, '2026-10-13T10:00:00-05:00'),
            window_row('Recent', 3, '2026-10-13T10:14:00-05:00')]
    path = make_session(root, now, rows=rows, partials={'them': row(ch='them', parts=[part('Still talking', words=None)])})
    assert read_json(path / 'live.json')['finals'] == []
    session = select_session(root, now)
    assert [(r['text'], r['ch'], r['partial']) for r in session.rows(now)] == [
        ('Exactly 15 minutes', 'me', False), ('Recent', 'me', False), ('Still talking', 'them', True)]


def test_ended_session_rows_are_the_15_minutes_before_it_ended(root, now):
    rows = [window_row('Before the window', 1, '2026-10-13T09:49:59-05:00'), window_row('Last words', 2, '2026-10-13T10:04:00-05:00')]
    make_session(root, now, rows=rows, state='closed', ended_at='2026-10-13T10:05:00-05:00')
    session = select_session(root, now, recent=True)
    assert [r['text'] for r in session.rows(now)] == ['Last words']
    packet = context(root, session, now, 'What was said last?')
    assert 'me: Last words' in packet and 'Before the window' not in packet


@pytest.mark.parametrize('ch', ['me', 'them'])
@pytest.mark.parametrize('partial', [False, True])
def test_every_displayed_channel_compares_numbers_with_brief(root, now, ch, partial):
    text = '25 for phase one' if partial else '425 for phase one'
    spoken = row(ch=ch, parts=[part(text)])
    make_session(root, now, rows=[] if partial else [spoken],
                 partials={ch: spoken} if partial else {})
    atomic_write(root / 'briefs/event.md', Record('last.md', '2026-09-30', '42,500 for phase one').render())
    packet = context(root, select_session(root, now), now, 'What amount?')
    number = '25⟨unconfirmed⟩' if partial else '425'
    assert f'{ch}: {number} [as transcribed; may be spoken shorthand for 42,500 (brief, 2026-09-30)]' in packet


def test_ad_hoc_context_has_recent_finals_and_partials_without_brief(root, now):
    atomic_write(root / 'schedule.json', {'events': []})
    recent = row(text='Recent call discussion')
    old = row(seq=2, parts=[part('OLD CALL CONTENT', '2026-10-13T10:04:00-05:00',
                                 '2026-10-13T10:05:00-05:00')])
    future = row(seq=3, parts=[part('FUTURE CONTENT', '2026-10-13T10:16:00-05:00',
                                    '2026-10-13T10:16:05-05:00')])
    partial = row(ch='them', parts=[part('Current unfinished thought', words=None)])
    make_session(root, now, rows=[old, recent, future], partials={'them': partial})
    packet = context(root, select_session(root, now), now, 'What did they say?')
    assert 'No calendar event (ad-hoc call)' in packet
    assert '[10:14:00] me: Recent call discussion' in packet
    assert '[10:14:00] them: Current unfinished thought (still being transcribed)' in packet
    assert 'OLD CALL CONTENT' not in packet and 'FUTURE CONTENT' not in packet
    assert 'Budget meeting' not in packet and 'Event event' not in packet


def test_ambiguous_shows_labelled_briefs(root, now, hermes):
    atomic_write(root / 'schedule.json', {'events': [event(), event('other', '2026-10-13T10:05:00-05:00')]})
    atomic_write(root / 'briefs/other.md', '# Other brief')
    answer('Budget?', root=root, now=now, runner=hermes)
    assert 'Overlapping events: event, other' in hermes.prompts[0]
    assert 'Event event' in hermes.prompts[0] and 'Event other\n# Other brief' in hermes.prompts[0]


def test_them_silent_suffix(root, now, hermes):
    make_session(root, now, warnings=['them_silent'])
    assert answer('Budget?', root=root, now=now, runner=hermes).endswith("(their audio isn't reaching me; check `lml doctor`)")


def test_prompt_preview_and_lock_mapping(root, hermes):
    sid = next((root / 'sessions').iterdir()).name
    def checked(argv, timeout):
        assert (root / 'locks' / (sid + '.lock')).exists()
        path = Path(argv[argv.index('--query-file') + 1])
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert argv[argv.index('--source') + 1] == 'tool'
        assert all(flag in argv for flag in ['-Q', '--oneshot', '--ignore-rules'])
        assert argv[argv.index('-t') + 1] == 'todo'
        assert timeout == 45
        assert not (root / 'hermes_map' / (sid + '.jsonl')).exists()
        prompt = path.read_text()
        assert len(header()) > 80
        assert prompt[:80] == header()[:80]
        assert 'PRIVATE TRANSCRIPT' not in prompt[:80]
        return hermes(argv, timeout)
    assert call(root, sid, 'PRIVATE TRANSCRIPT', runner=checked) == 'Budget answer.'
    assert read_jsonl(root / 'hermes_map' / (sid + '.jsonl'))[0]['id'] == 'session-1'
    assert not list((root / 'inflight').glob('*'))
    assert not list((root / 'queries').glob('*'))
    for path in [root, root / 'locks', root / 'queries', root / 'sessions' / sid]:
        assert stat.S_IMODE(path.stat().st_mode) == 0o700


def test_forget_deletes_mapped_and_tagged_ids(root, hermes):
    sid = next((root / 'sessions').iterdir()).name
    atomic_write(root / 'hermes_map' / (sid + '.jsonl'), json.dumps({'id': 'mapped-only'}) + '\n')
    atomic_write(root / 'nudges' / (sid + '.jsonl'), 'QUOTE')
    hermes.ids.add('tag-only')
    remaining, waiting = forget(root, sid, runner=hermes)
    assert not remaining and not waiting
    deleted = {argv[3] for argv, _ in hermes.calls if 'delete' in argv}
    assert deleted == {'mapped-only', 'tag-only'}
    assert forgotten(root, sid)
    assert not (root / 'sessions' / sid).exists()
    assert not list((root / 'nudges').glob(sid + '.*'))
    assert not hermes.ids


@pytest.mark.parametrize('which', ['answer', 'nudge'])
def test_forget_during_paused_call_waits_and_discards_late_answer(root, now, hermes, which):
    sid = next((root / 'sessions').iterdir()).name
    if which == 'nudge':
        hermes.reply = json.dumps(candidate())
    entered, release = threading.Event(), threading.Event()
    outputs, errors, forget_results = [], [], []
    def paused(argv, timeout):
        entered.set()
        assert release.wait(5)
        return hermes(argv, timeout)
    def caller():
        try:
            if which == 'answer':
                outputs.append(answer('Budget?', root=root, now=now, runner=paused, hermes_runner=hermes))
            else:
                outputs.append(tick(root=root, now=now, runner=paused, hermes_runner=hermes))
        except Exception as exc:
            errors.append(type(exc).__name__)
    thread = threading.Thread(target=caller)
    thread.start()
    assert entered.wait(5)
    deleting = threading.Thread(target=lambda: forget_results.append(forget(root, sid, runner=hermes, wait_seconds=5)))
    deleting.start()
    deadline = time.monotonic() + 3
    while not forgotten(root, sid) and time.monotonic() < deadline:
        time.sleep(0.01)
    assert forgotten(root, sid)
    assert deleting.is_alive()
    release.set()
    thread.join(5)
    deleting.join(5)
    assert not thread.is_alive() and not deleting.is_alive() and not errors
    assert outputs == (['That meeting was forgotten.'] if which == 'answer' else [''])
    assert forget_results == [(set(), False)]
    assert not hermes.ids
    assert not list((root / 'inflight').glob('*'))
    assert not (root / 'sessions' / sid).exists()
    assert not list((root / 'nudges').glob(sid + '.*'))


def test_failure_is_sanitized_and_query_removed(root, now, capsys):
    def failure(argv, timeout):
        raise RuntimeError('PRIVATE TRANSCRIPT')
    with pytest.raises(CallFailed) as raised:
        answer('Budget?', root=root, now=now, runner=failure)
    assert 'PRIVATE' not in str(raised.value) and 'PRIVATE TRANSCRIPT' not in capsys.readouterr().err
    assert not list((root / 'queries').glob('*'))
    assert not list((root / 'inflight').glob('*'))


def test_failed_call_still_maps_id(root, hermes):
    sid = next((root / 'sessions').iterdir()).name
    def failure(argv, timeout):
        return SimpleNamespace(returncode=1, stdout='PRIVATE TRANSCRIPT', stderr='Session: failed-id\n')
    with pytest.raises(CallFailed, match='Meeting model call failed'):
        call(root, sid, 'SECRET', runner=failure, hermes_runner=hermes)
    assert read_jsonl(root / 'hermes_map' / (sid + '.jsonl'))[0]['id'] == 'failed-id'


def test_live_answer_command_end_to_end_stub(root, now, tmp_path):
    from lml_common import now_local
    current_now = now_local()
    make_session(root, current_now, test=True)
    stub = tmp_path / 'stub.py'
    proof = root / 'proof.json'
    stub.write_text('''import json, os, sys
from pathlib import Path
argv = sys.argv
root = Path(os.environ['LML_ROOT'])
query = Path(argv[argv.index('--query-file') + 1])
assert list((root / 'locks').glob('*.lock')) and query.stat().st_mode & 0o777 == 0o600
(root / 'proof.json').write_text(json.dumps({'source': argv[argv.index('--source') + 1], 'preview': query.read_text()[:80]}))
print('Session: e2e-id', file=sys.stderr)
print(json.dumps({'type': 'result', 'text': 'The last confirmed budget was $90,000.'}))
''')
    env = {**os.environ, 'LML_ROOT': str(root), 'LML_LLM_CMD': sys.executable + ' ' + str(stub)}
    command = [sys.executable, str(Path(__file__).parents[1] / 'live_answer.py'), 'What budget?']
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0
    assert result.stdout == 'The last confirmed budget was $90,000.\n'
    assert result.stderr == ''
    assert read_json(proof)['source'] == 'tool'
    assert read_json(proof)['preview'] == header()[:80]
    assert read_jsonl(next((root / 'hermes_map').glob('*.jsonl')))[0]['id'] == 'e2e-id'


@pytest.mark.parametrize('output,expected', [
    ('[{"id":"abc"}]', {'abc'}), ('{"sessions":[{"session_id":"abc"}]}', {'abc'}),
    ('session_id: abc\n', {'abc'}), ('ID Source\n 550e8400-e29b-41d4-a716-446655440000 lm-test', {'550e8400-e29b-41d4-a716-446655440000'}),
])
def test_hermes_listing_formats(output, expected):
    assert session_ids(output) == expected


HERMES_TABLE = (
    'Title                          Workspace       Last Active    ID\n'
    + '─' * 110 + '\n'
    + 'Listener meeting nudge         live-meeting    5m ago         cron_6b0e8b7624d7_20261023_220010\n'
    + 'Budget question, the session   —               2h ago         20261024_034039_4487c4\n'
    + '\n  … more not shown (use --limit 6 to see more)\n')


@pytest.mark.parametrize('output,expected', [
    (HERMES_TABLE, {'cron_6b0e8b7624d7_20261023_220010', '20261024_034039_4487c4'}),
    ('Title  Preview  Last Active  ID\n' + '─' * 40 + '\n' + 'x  y  1m ago  20261019_200006_3ed510\n',
     {'20261019_200006_3ed510'}),
    ('No sessions found.\n', set()),
])
def test_hermes_session_table_ids(output, expected):
    assert session_ids(output) == expected


def test_forget_deletes_sessions_listed_in_the_hermes_table(root):
    sid = next((root / 'sessions').iterdir()).name
    listed = {'cron_6b0e8b7624d7_20261023_220010', '20261024_034039_4487c4'}
    deleted = []
    def table(argv, timeout):
        if 'list' in argv:
            remaining = HERMES_TABLE if not deleted else 'No sessions found.\n'
            return SimpleNamespace(returncode=0, stdout=remaining, stderr='')
        deleted.append(argv[3])
        return SimpleNamespace(returncode=0, stdout='', stderr='')
    assert forget(root, sid, runner=table) == (set(), False)
    assert set(deleted) == listed


def test_number_references_are_inside_selected_event(root, now, hermes):
    previous = event('previous', '2026-10-13T09:00:00-05:00', '2026-10-13T10:10:00-05:00')
    selected = event('current', '2026-10-13T10:10:00-05:00')
    atomic_write(root / 'schedule.json', {'events': [previous, selected]})
    atomic_write(root / 'briefs/current.md', '# Current meeting')
    local = row(parts=[part('425 for phase one')])
    old = row(ch='them', seq=2, parts=[part('Budget was $42,500.', '2026-10-13T10:09:00-05:00', '2026-10-13T10:09:05-05:00')])
    make_session(root, now, rows=[old, local])
    answer('Budget?', root=root, now=now, runner=hermes)
    assert '$42,500' not in hermes.prompts[0]
    assert '[10:14:00] me: 425 for phase one' in hermes.prompts[0]


def test_forget_failure_keeps_mapped_ids_for_retry(root, hermes):
    sid = next((root / 'sessions').iterdir()).name
    atomic_write(root / 'hermes_map' / (sid + '.jsonl'), '{"id":"mapped-only"}\n')
    def failing_delete(argv, timeout):
        if 'delete' in argv:
            return SimpleNamespace(returncode=1, stdout='', stderr='temporary failure')
        return hermes(argv, timeout)
    remaining, waiting = forget(root, sid, runner=failing_delete)
    assert remaining == {'mapped-only'} and not waiting
    assert read_json(root / 'deletions' / (sid + '.json'))['ids'] == ['mapped-only']
    assert not (root / 'sessions' / sid).exists()
    assert forget(root, sid, runner=hermes) == (set(), False)
    assert any(argv[3] == 'mapped-only' for argv, _ in hermes.calls if 'delete' in argv)
    assert not (root / 'deletions' / (sid + '.json')).exists()


def test_forget_listing_failure_keeps_retry_request(root, hermes):
    sid = next((root / 'sessions').iterdir()).name
    def fail_list(argv, timeout):
        if 'list' in argv:
            return SimpleNamespace(returncode=1, stdout='', stderr='failure')
        return hermes(argv, timeout)
    with pytest.raises(CallFailed):
        forget(root, sid, runner=fail_list)
    assert (root / 'deletions' / (sid + '.json')).exists()
    hermes.ids.add('tagged-after-crash')
    assert forget(root, sid, runner=hermes) == (set(), False)
    assert not hermes.ids


@pytest.mark.parametrize('message', ['Session not found', "No session 'gone'. Run: hermes sessions list to find the id."])
def test_already_absent_delete_is_idempotent(root, message):
    sid = next((root / 'sessions').iterdir()).name
    atomic_write(root / 'hermes_map' / (sid + '.jsonl'), '{"id":"gone"}\n')
    def absent(argv, timeout):
        if 'list' in argv:
            return SimpleNamespace(returncode=0, stdout='[]', stderr='')
        return SimpleNamespace(returncode=1, stdout=message, stderr='')
    assert forget(root, sid, runner=absent) == (set(), False)


def test_timeout_keeps_printed_session_id_and_has_no_private_error(monkeypatch):
    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired('command', 45, output=b'session_id: timeout-id\nPRIVATE TRANSCRIPT')
    monkeypatch.setattr('lml_hermes.subprocess.run', timeout)
    result = run_command(['fake'], 45)
    assert result.returncode == 124
    assert 'timeout-id' in result.stdout
    assert result.stderr == ''


def test_forget_command_fails_if_ids_remain(monkeypatch, capsys):
    import runpy
    script = Path(__file__).parents[1] / 'live-meeting-forget'
    monkeypatch.setattr('lml_hermes.forget', lambda *args, **kwargs: ({'remaining-id'}, False))
    monkeypatch.setattr('sys.argv', ['live-meeting-forget', '20261013-100000-abcd'])
    with pytest.raises(SystemExit) as result:
        runpy.run_path(str(script), run_name='__main__')
    assert result.value.code == 1
    captured = capsys.readouterr()
    assert captured.out == '' and 'remaining-id' in captured.err


@pytest.mark.parametrize('bad_key', ['*', '../meeting', 'meeting?', '[all]', 'meeting\nother'])
def test_forget_rejects_path_and_glob_keys(root, hermes, bad_key):
    with pytest.raises(ValueError, match='Invalid storage key'):
        forget(root, bad_key, runner=hermes)
    assert next((root / 'sessions').iterdir()).exists()
    assert not hermes.calls


def test_hermes_skill_entry_still_prints_the_failure_on_stdout_and_exits_0(monkeypatch, capsys):
    import live_answer
    def failure(question, **kwargs):
        raise CallFailed()
    monkeypatch.setattr('live_answer.answer', failure)
    monkeypatch.setattr('sys.argv', ['live_answer.py', 'Budget?'])
    assert live_answer.main() == 0
    assert capsys.readouterr().out == 'The meeting answer is unavailable right now.\n'
