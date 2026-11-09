import json
from datetime import timedelta
from types import SimpleNamespace

import pytest

from conftest import event, make_session, part, row
from lml_common import append_jsonl, atomic_write, dt, now_local, read_json, read_jsonl, root_path
from lml_hermes import header
from lml_records import Record
from lml_screen import ScreenFailed
import live_meeting_nudge
from live_meeting_nudge import instructions, gate, main, throttle, tick
from test_health import call, heartbeat, schedule


def candidate(**changes):
    value = dict(nudge=True, kind='wrong_number', current_quote='The budget is $70,000.', current_seq=1,
                 record_quote='The budget is $90,000.', record_source='last.md', record_date='2026-09-30',
                 subject='budget', text='The prior budget was $90,000.')
    return {**value, **changes}


def final_parts(**changes):
    return [dict(part(), ch='me', seq=1, partial=False, boundary=False, **changes)]


def old_records(**changes):
    return [Record(**dict(source='last.md', date='2026-09-30', text='The budget is $90,000.', **changes))]


def test_valid_grounded_wrong_number(now):
    assert gate(candidate(), final_parts(), {1}, old_records(), now.date()) == ''


@pytest.mark.parametrize('kind', ['wrong_number', 'contradiction', 'missed_commitment'])
@pytest.mark.parametrize('amount', ['425', '25', '42-5', '42 5', '42.5', '425000'])
def test_shorthand_suppressed_for_every_kind(now, kind, amount):
    current = f'We said {amount} for phase one'
    prior = 'We said 42,500 for phase one'
    parts = [dict(part(current), ch='me', seq=1, partial=False, boundary=False)]
    record = Record('last.md', '2026-09-30', prior, 'action_item', '2026-10-12')
    value = candidate(kind=kind, current_quote=current, record_quote=prior, subject='phase')
    assert gate(value, parts, {1}, [record], now.date()) == 'shorthand'


def test_contradiction_without_numbers_passes(now):
    current = 'We agreed to cancel the Salesforce rollout'
    prior = 'We agreed to continue the Salesforce rollout'
    parts = [dict(part(current), ch='me', seq=1, partial=False, boundary=False)]
    record = Record('last.md', '2026-09-30', prior)
    value = candidate(kind='contradiction', current_quote=current, record_quote=prior, subject='Salesforce rollout')
    assert gate(value, parts, {1}, [record], now.date()) == ''


@pytest.mark.parametrize('kind,reason', [('wrong_number', 'number'), ('contradiction', ''), ('missed_commitment', '')])
def test_shorthand_requires_a_matching_unit(now, kind, reason):
    current = 'The phase budget is £42.5'
    prior = 'The phase budget is $42,500'
    parts = [dict(part(current), ch='me', seq=1, partial=False, boundary=False)]
    record = Record('last.md', '2026-09-30', prior, 'action_item', '2026-10-12')
    value = candidate(kind=kind, current_quote=current, record_quote=prior, subject='phase budget')
    assert gate(value, parts, {1}, [record], now.date()) == reason


def test_shorthand_contradiction_tick_is_suppressed(root, now, hermes):
    current = 'We said 425 for phase one'
    prior = 'We said 42,500 for phase one'
    make_session(root, now, rows=[row(text=current)])
    atomic_write(root / 'briefs/event.md', Record('last.md', '2026-09-30', prior).render())
    hermes.reply = json.dumps(candidate(kind='contradiction', current_quote=current,
                                       record_quote=prior, subject='phase'))
    delivered = []
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, deliver=delivered.append) == ''
    assert not delivered
    assert read_jsonl(root / 'nudges/20261013-100000-abcd.jsonl')[0]['gate'] == 'shorthand'


@pytest.mark.parametrize('label', ['me?', 'bleed'])
def test_unreliable_attribution_fails(label, now):
    parts = final_parts()
    parts[0]['ch'] = label
    assert gate(candidate(), parts, {1}, old_records(), now.date()) == 'current_quote'


@pytest.mark.parametrize('field,value,expected', [
    ('nudge', False, 'no_nudge'), ('current_seq', 0, 'current_quote'),
    ('current_seq', True, 'current_quote'), ('current_quote', 'invented budget', 'current_quote'),
    ('record_source', 'current transcript', 'record_quote'),
    ('record_quote', 'An invented record', 'record_quote'),
    ('record_date', '2026-10-13', 'record_quote'),
    ('subject', 'unrelated', 'subject'), ('kind', 'other', 'kind'),
    ('text', 'x' * 161, 'schema'), ('text', 'first\nsecond', 'schema'),
    ('subject', None, 'schema'),
])
def test_gate_rejections(field, value, expected, now):
    assert gate(candidate(**{field: value}), final_parts(), {1}, old_records(), now.date()) == expected


@pytest.mark.parametrize('change', [{'boundary': True}, {'partial': True}])
def test_partials_and_boundary_quotes_fail(change, now):
    parts = final_parts()
    parts[0].update(change)
    assert gate(candidate(), parts, {1}, old_records(), now.date()) == 'current_quote'


def test_just_today_record_and_transcript_record_fail(now):
    record = Record('last.md', now.date().isoformat(), 'The budget is $90,000.')
    assert gate(candidate(record_date=record.date), final_parts(), {1}, [record], now.date()) == 'record_date'
    record = Record('last.md', '2026-09-30', 'The budget is $90,000.', 'transcript')
    assert gate(candidate(), final_parts(), {1}, [record], now.date()) == 'record_quote'


@pytest.mark.parametrize('current,prior,reason', [
    ('The budget is $90,000.', 'The budget is $90,000.', 'number'),
    ('The budget is 40%.', 'The budget is $90,000.', 'number'),
    ('The price is $70,000.', 'The budget is $90,000.', 'subject'),
    ('The budget is 425.', 'The budget is $42,500.', 'shorthand'),
    ('The budget is 25.', 'The budget is $42,500.', 'shorthand'),
    ('The budget is 42-5.', 'The budget is $42,500.', 'shorthand'),
    ('The budget is 42 5.', 'The budget is $42,500.', 'shorthand'),
    ('The budget is 42.5.', 'The budget is $42,500.', 'shorthand'),
    ('The budget is 900.', 'The budget is $90,000.', 'shorthand'),
])
def test_wrong_number_variants(current, prior, reason, now):
    parts = final_parts()
    parts[0]['text'] = current
    record = Record('last.md', '2026-09-30', prior)
    assert gate(candidate(current_quote=current, record_quote=prior), parts, {1}, [record], now.date()) == reason


def test_normalized_agreement_fails_contradiction(now):
    parts = final_parts()
    parts[0]['text'] = 'THE budget IS $90,000!'
    assert gate(candidate(kind='contradiction', current_quote=parts[0]['text']), parts, {1}, old_records(), now.date()) == 'equivalent'


@pytest.mark.parametrize('kind,due,expected', [
    ('action_item', '2026-10-12', ''), ('action_item', '2026-10-13', ''),
    ('action_item', '2026-10-14', 'due_date'), ('prior_meeting', '2026-10-12', 'due_date'),
    ('action_item', '', 'due_date'),
])
def test_missed_commitment_requires_due_action(kind, due, expected, now):
    record = Record('last.md', '2026-09-30', 'The budget is $90,000.', kind, due)
    assert gate(candidate(kind='missed_commitment'), final_parts(), {1}, [record], now.date()) == expected


@pytest.mark.parametrize('state,age,expected', [
    ({}, 179, 'first_three_minutes'), ({'sent': 3}, 900, 'session_limit'),
    ({'last_sent': '2026-10-13T10:06:00-05:00'}, 900, 'ten_minutes'),
    ({'records_sent': ['the budget is 90 000']}, 900, 'duplicate'),
    ({'last_sent': '2026-10-13T10:05:00-05:00'}, 900, ''),
])
def test_throttle(state, age, expected, now):
    session = SimpleNamespace(meta={'started_at': (now - timedelta(seconds=age)).isoformat()})
    assert throttle(state, candidate(), session, now) == expected


def test_tick_sends_then_dedupes_new_seq(root, now, hermes):
    hermes.reply = json.dumps(candidate())
    message = tick(root=root, now=now, runner=hermes, hermes_runner=hermes)
    assert message == 'Heads up: The prior budget was $90,000. (on record: 2026-09-30, last.md)'
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes) == ''
    assert hermes.count == 1
    new_now = now + timedelta(minutes=11)
    make_session(root, new_now, rows=[row(seq=2, parts=[part(start=(new_now-timedelta(seconds=10)).isoformat(), end=new_now.isoformat())])])
    hermes.reply = json.dumps(candidate(current_seq=2))
    assert tick(root=root, now=new_now, runner=hermes, hermes_runner=hermes) == ''
    logs = read_jsonl(next((root / 'nudges').glob('*.jsonl')))
    assert [entry['gate'] for entry in logs] == ['sent', 'duplicate']
    assert set(logs[0]) == {'at', 'current_quote', 'record_quote', 'gate', 'stage', 'screen_error', 'text'}
    assert logs[0]['text'] == 'The prior budget was $90,000.' and 'text' not in logs[1]


def test_print_only_uses_stderr(root, now, hermes, capsys):
    hermes.reply = json.dumps(candidate())
    assert tick(root=root, now=now, print_only=True, runner=hermes, hermes_runner=hermes) == ''
    captured = capsys.readouterr()
    assert captured.out == ''
    assert captured.err.startswith('[NUDGE WOULD SEND] Heads up:')


def test_test_session_in_production_root_is_refused(tmp_path, now, hermes, capsys):
    root = tmp_path / 'production'
    make_session(root, now, test=True)
    assert tick(root=root, now=now, runner=hermes) == ''
    assert hermes.calls == []
    captured = capsys.readouterr()
    assert captured.out == ''
    assert 'refused: test session' in captured.err


@pytest.mark.parametrize('why', ['ambiguous', 'no_event', 'stale', 'no_brief', 'no_finals', 'no_prefilter', 'only_partial', 'boundary'])
def test_tick_no_call_without_prerequisites(root, now, hermes, why):
    if why == 'ambiguous':
        atomic_write(root / 'schedule.json', {'events': [event(), event('other', '2026-10-13T10:05:00-05:00')]})
    elif why == 'no_event':
        atomic_write(root / 'schedule.json', {'events': []})
    elif why == 'stale':
        make_session(root, now - timedelta(seconds=90))
    elif why == 'no_brief':
        (root / 'briefs/event.md').unlink()
    elif why == 'no_finals':
        make_session(root, now, rows=[])
    elif why == 'no_prefilter':
        make_session(root, now, rows=[row(text='Hello there')])
    elif why == 'only_partial':
        make_session(root, now, rows=[], partials={'me': row()})
    elif why == 'boundary':
        make_session(root, now, rows=[row(parts=[part(start='2026-10-13T09:57:00-05:00', end=now.isoformat())])])
    assert tick(root=root, now=now, runner=hermes) == ''
    assert hermes.calls == []
    if why == 'no_event':
        assert not list((root / 'nudges').glob('*.jsonl'))


def test_no_prefilter_advances_cursor(root, now, hermes):
    make_session(root, now, rows=[row(text='Hello there')])
    tick(root=root, now=now, runner=hermes)
    state = read_json(next((root / 'nudges').glob('*.state.json')))
    assert state['cursor'] == 1


def test_bad_json_and_failures_never_log_transcript(root, now, hermes, capsys, monkeypatch):
    hermes.reply = 'PRIVATE TRANSCRIPT BUDGET 999'
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes) == ''
    assert 'PRIVATE' not in capsys.readouterr().err
    assert 'PRIVATE' not in next((root / 'nudges').glob('*.jsonl')).read_text()
    def failure(**kwargs):
        raise RuntimeError('PRIVATE TRANSCRIPT')
    monkeypatch.setattr('live_meeting_nudge.tick', failure)
    monkeypatch.setattr('sys.argv', ['nudge'])
    assert main() == 0
    captured = capsys.readouterr()
    assert captured.out == '' and 'PRIVATE' not in captured.err


def test_nudge_call_timeout_header_source_and_mapping(root, now, hermes):
    import os
    from pathlib import Path
    from lml_hermes import header
    hermes.reply = json.dumps(candidate())
    def checked(argv, timeout):
        assert timeout == 40
        assert argv[argv.index('--source') + 1] == 'tool'
        assert (root / 'locks/20261013-100000-abcd.lock').exists()
        query = Path(argv[argv.index('--query-file') + 1]).read_text()
        assert query[:80] == header()[:80]
        return hermes(argv, timeout)
    assert tick(root=root, now=now, runner=checked, hermes_runner=hermes)
    assert read_jsonl(root / 'hermes_map/20261013-100000-abcd.jsonl')[0]['id'] == 'session-1'


def test_remote_partial_is_attributed_but_never_nudge_evidence(root, now, hermes):
    local = row(parts=[part('The budget is $70,000.', xo=1)])
    remote = row(ch='them', parts=[part('The budget is $70,000.', end='2026-10-13T10:14:08-05:00')])
    make_session(root, now, rows=[local], partials={'them': remote}, speech={'them': [[local['ts0'], local['ts1']]]})
    assert tick(root=root, now=now, runner=hermes) == ''
    assert not hermes.calls


@pytest.mark.parametrize('fresh', [False, True])
def test_boundary_fallback_excludes_nudge_evidence(root, now, hermes, fresh):
    earlier = event('earlier', '2026-10-13T09:00:00-05:00', '2026-10-13T10:14:00-05:00')
    later = event('event', '2026-10-13T10:14:00-05:00')
    atomic_write(root / 'schedule.json', {'events': [earlier, later]})
    crossing = part('The budget is $70,000.', '2026-10-13T10:13:59-05:00',
                    '2026-10-13T10:14:05-05:00', words=None)
    make_session(root, now, rows=[row(ch='them', parts=[crossing], schedule_fresh=fresh)])
    assert tick(root=root, now=now, runner=hermes) == ''
    assert not hermes.calls
    assert read_json(root / 'nudges/20261013-100000-abcd.state.json')['cursor'] == 1


class Screen:
    def __init__(self, result):
        self.result = result
        self.prompts = []

    def __call__(self, prompt):
        self.prompts.append(prompt)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result() if callable(self.result) else self.result


SID = '20261013-100000-abcd'


def nudge_log(root):
    return [(entry['stage'], entry['gate']) for entry in read_jsonl(root / f'nudges/{SID}.jsonl')]


def cursor(root):
    return read_json(root / f'nudges/{SID}.state.json')['cursor']


def test_negative_screen_skips_the_strong_model_and_advances_the_cursor(root, now, hermes):
    screen = Screen({'nudge': False})
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=screen) == ''
    assert screen.prompts[0].startswith(header()) and 'The budget is $70,000.' in screen.prompts[0]
    assert hermes.calls == []
    assert cursor(root) == 1
    assert nudge_log(root) == [('screen', 'no_nudge')]


def test_screen_positive_failing_the_gate_skips_the_strong_model(root, now, hermes):
    screen = Screen(candidate(current_quote='an invented budget'))
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=screen) == ''
    assert hermes.calls == []
    assert cursor(root) == 1
    assert nudge_log(root) == [('screen', 'current_quote')]


def test_gate_passing_screen_positive_is_confirmed_once_then_sent(root, now, hermes):
    hermes.reply = json.dumps(candidate())
    delivered = []
    screen = Screen(candidate(text='Screen wording.'))
    message = tick(root=root, now=now, runner=hermes, hermes_runner=hermes, deliver=delivered.append, screen=screen)
    assert message == 'Heads up: The prior budget was $90,000. (on record: 2026-09-30, last.md)'
    assert delivered == [message]
    assert hermes.count == 1
    confirm = hermes.prompts[0]
    assert 'A fast screen proposed the candidate below' in confirm
    payload = json.loads(confirm[confirm.index('{"candidate"'):])
    assert payload.pop('candidate')['text'] == 'Screen wording.'
    assert payload == json.loads(screen.prompts[0][len(header() + instructions()):])
    assert nudge_log(root) == [('confirm', 'sent')]


@pytest.mark.parametrize('reply,reason', [({'nudge': False}, 'no_nudge'),
                                          (candidate(record_quote='An invented record'), 'record_quote'),
                                          ('not json', 'no_nudge')])
def test_confirm_that_fails_sends_nothing(root, now, hermes, reply, reason):
    hermes.reply = reply if isinstance(reply, str) else json.dumps(reply)
    delivered = []
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, deliver=delivered.append,
                screen=Screen(candidate())) == ''
    assert delivered == []
    assert hermes.count == 1
    assert cursor(root) == 1
    assert nudge_log(root) == [('confirm', reason)]


def test_first_three_minutes_throttle_applies_before_the_strong_model(root, now, hermes):
    make_session(root, now, started_at=(now - timedelta(seconds=60)).isoformat())
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=Screen(candidate())) == ''
    assert hermes.calls == []
    assert nudge_log(root) == [('screen', 'first_three_minutes')]


def test_send_throttles_still_apply_after_a_confirmed_send(root, now, hermes):
    hermes.reply = json.dumps(candidate())
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=Screen(candidate()))
    later = now + timedelta(minutes=5)
    make_session(root, later, rows=[row(seq=2, parts=[part(start=(later - timedelta(seconds=10)).isoformat(),
                                                             end=later.isoformat())])])
    other = candidate(current_seq=2, record_quote='budget is $90,000')
    assert tick(root=root, now=later, runner=hermes, hermes_runner=hermes, screen=Screen(other)) == ''
    assert hermes.count == 1
    assert nudge_log(root) == [('confirm', 'sent'), ('screen', 'ten_minutes')]


@pytest.mark.parametrize('error,code', [(ScreenFailed('timeout'), 'timeout'), (RuntimeError('unexpected'), 'RuntimeError')])
def test_screen_error_falls_back_to_the_strong_path(root, now, hermes, error, code):
    hermes.reply = json.dumps(candidate())
    message = tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=Screen(error))
    assert message.startswith('Heads up:')
    assert hermes.count == 1
    assert 'A fast screen proposed' not in hermes.prompts[0]
    assert 'Check for an important grounded contradiction' in hermes.prompts[0]
    assert nudge_log(root) == [('strong', 'sent')]
    assert read_jsonl(root / f'nudges/{SID}.jsonl')[0]['screen_error'] == code


def test_error_judging_the_screen_candidate_falls_back_to_the_strong_path(root, now, hermes, monkeypatch):
    real_gate = live_meeting_nudge.gate
    def fragile(value, *args):
        if value.get('text') == 'unjudgeable':
            raise ArithmeticError('gate failed')
        return real_gate(value, *args)
    monkeypatch.setattr(live_meeting_nudge, 'gate', fragile)
    hermes.reply = json.dumps(candidate())
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes,
                screen=Screen(candidate(text='unjudgeable'))).startswith('Heads up:')
    assert 'A fast screen proposed' not in hermes.prompts[0]
    assert nudge_log(root) == [('strong', 'sent')]


def test_negative_screen_advances_the_cursor_past_every_new_seq(root, now, hermes):
    later = part('Hello there', start='2026-10-13T10:14:06-05:00', end='2026-10-13T10:14:08-05:00')
    make_session(root, now, rows=[row(), row(seq=2, parts=[later])])
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=Screen({'nudge': False})) == ''
    assert cursor(root) == 2


def test_default_screen_without_network_falls_back_to_the_strong_path(root, now, hermes):
    hermes.reply = json.dumps(candidate())
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes).startswith('Heads up:')
    assert nudge_log(root) == [('strong', 'sent')]
    assert read_jsonl(root / f'nudges/{SID}.jsonl')[0]['screen_error'] == 'offline'


@pytest.mark.parametrize('verdict', [candidate(), {'nudge': False}])
def test_meeting_forgotten_during_the_screen_sends_and_logs_nothing(root, now, hermes, verdict):
    def forget_then_answer():
        append_jsonl(root / 'forgotten.jsonl', {'sid': SID, 'at': now.isoformat()})
        return verdict
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=Screen(forget_then_answer)) == ''
    assert hermes.calls == []
    assert not (root / f'nudges/{SID}.jsonl').exists()
    assert not (root / f'nudges/{SID}.state.json').exists()


def test_print_only_confirmed_nudge_goes_to_stderr(root, now, hermes, capsys):
    hermes.reply = json.dumps(candidate())
    assert tick(root=root, now=now, print_only=True, runner=hermes, hermes_runner=hermes, screen=Screen(candidate())) == ''
    captured = capsys.readouterr()
    assert captured.out == ''
    assert captured.err.startswith('[NUDGE WOULD SEND] Heads up:')


def run_main(monkeypatch, capsys, *args):
    monkeypatch.setattr('sys.argv', ['live_meeting_nudge.py', *args])
    assert main() == 0
    return capsys.readouterr()


@pytest.fixture
def stale_before_a_call():
    root, now = root_path(), now_local()
    schedule(root, now, call(now))
    heartbeat(root, now, age=7 * 60)
    return root


def test_main_texts_a_recorder_alert_once_before_a_call(stale_before_a_call, monkeypatch, capsys):
    first = run_main(monkeypatch, capsys)
    assert first.out.startswith('Recorder problem before Budget sync at ') and first.out.count('\n') == 1
    assert 'the recorder on the MacBook last checked in 7 minutes ago.' in first.out and first.err == ''
    assert run_main(monkeypatch, capsys).out == ''


def test_main_print_only_previews_the_alert_on_stderr(stale_before_a_call, monkeypatch, capsys):
    preview = run_main(monkeypatch, capsys, '--print')
    assert preview.out == '' and preview.err.startswith('[ALERT WOULD SEND] Recorder problem before Budget sync at ')
    assert not (stale_before_a_call / 'health.json').exists()
    assert run_main(monkeypatch, capsys).out == preview.err.removeprefix('[ALERT WOULD SEND] ')


def test_main_alert_and_tick_fail_independently(stale_before_a_call, monkeypatch, capsys):
    def failing_tick(**kwargs):
        raise RuntimeError('PRIVATE TRANSCRIPT')
    monkeypatch.setattr('live_meeting_nudge.tick', failing_tick)
    alert = run_main(monkeypatch, capsys)
    assert alert.out.startswith('Recorder problem before ') and alert.err == 'Meeting nudge tick failed.\n'
    def failing_check(*args, **kwargs):
        raise OSError('PRIVATE')
    monkeypatch.setattr('live_meeting_nudge.health_check', failing_check)
    monkeypatch.setattr('live_meeting_nudge.tick', lambda deliver, **kwargs: deliver('Heads up: nudge.'))
    nudge = run_main(monkeypatch, capsys)
    assert (nudge.out, nudge.err) == ('Heads up: nudge.\n', 'Recorder health check failed.\n')
