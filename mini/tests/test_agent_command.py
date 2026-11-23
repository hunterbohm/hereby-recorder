import os
import sys
import time
from pathlib import Path

import pytest

import any_answer
import live_answer
import live_quick
import lml_hermes
import lml_screen
from conftest import make_session
from lml_common import append_jsonl, now_local

AGENT = '''import os, sys, time
from pathlib import Path
prompt = sys.stdin.read()
Path(os.environ['AGENT_SEEN']).write_text(prompt)
Path(os.environ['AGENT_PID']).write_text(str(os.getpid()))
mode = os.environ.get('AGENT_MODE', 'answer')
if mode == 'slow':
    time.sleep(60)
if mode == 'fail':
    print('partial', flush=True)
    raise SystemExit(3)
if mode == 'empty':
    raise SystemExit(0)
print('Plain answer:', 'Question: ' in prompt)
'''


def never(argv, timeout):
    raise AssertionError('Hermes was called: ' + ' '.join(argv))


@pytest.fixture
def agent(tmp_path, monkeypatch):
    script = tmp_path / 'agent.py'
    script.write_text(AGENT)
    (tmp_path / 'xdg' / 'hereby').mkdir(parents=True)
    (tmp_path / 'xdg' / 'hereby' / 'recorder.toml').write_text(f'agent_command = "{sys.executable} {script}"\n')
    monkeypatch.setenv('AGENT_SEEN', str(tmp_path / 'seen.txt'))
    monkeypatch.setenv('AGENT_PID', str(tmp_path / 'agent.pid'))
    return tmp_path


def mode(monkeypatch, name):
    monkeypatch.setenv('AGENT_MODE', name)


def gone(pid_file):
    pid = int(Path(pid_file).read_text())
    for _ in range(50):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


def test_without_agent_command_model_calls_still_go_to_hermes():
    assert lml_hermes.agent_command() is None


def test_the_command_line_is_split_like_a_shell(agent):
    (agent / 'xdg/hereby/recorder.toml').write_text('agent_command = \'claude -p --tools ""\'\n')
    assert lml_hermes.agent_command() == ['claude', '-p', '--tools', '']


def test_a_live_answer_sends_the_prompt_on_stdin_and_keeps_nothing(agent, root, now):
    said = []
    live_answer.answer('What is the budget?', root=root, now=now, hermes_runner=never, deliver=said.append)
    assert said == ['Plain answer: True']
    prompt = (agent / 'seen.txt').read_text()
    assert prompt.startswith(lml_hermes.header()) and 'Question: What is the budget?' in prompt
    assert not (root / 'hermes_map').exists() and not any((root / 'queries').glob('*'))


@pytest.mark.parametrize('name', ['fail', 'empty'])
def test_a_nonzero_exit_or_no_answer_fails_the_call(agent, root, monkeypatch, name):
    mode(monkeypatch, name)
    with pytest.raises(lml_hermes.CallFailed):
        lml_hermes.call(root, '20261013-100000-abcd', 'Question: q', hermes_runner=never)


def test_a_forgotten_meeting_never_reaches_the_agent(agent, root):
    append_jsonl(root / 'forgotten.jsonl', {'sid': '20261013-100000-abcd'})
    with pytest.raises(lml_hermes.Forgotten):
        lml_hermes.call(root, '20261013-100000-abcd', 'Question: q', hermes_runner=never)
    assert not (agent / 'seen.txt').exists()


def test_ask_once_answers_and_maps_no_chat(agent, tmp_path):
    root = tmp_path / 'root'
    assert lml_hermes.ask_once(root, 'Question: q', hermes_runner=never) == 'Plain answer: True'
    assert not (root / 'hermes_map').exists()


def test_past_the_timeout_the_agent_is_killed_and_ask_once_times_out(agent, tmp_path, monkeypatch):
    mode(monkeypatch, 'slow')
    started = time.monotonic()
    with pytest.raises(lml_hermes.TimedOut):
        lml_hermes.ask_once(tmp_path / 'root', 'Question: q', timeout=1, hermes_runner=never)
    assert time.monotonic() - started < 10
    assert gone(agent / 'agent.pid')


def test_ask_any_meeting_uses_the_agent(agent, tmp_path):
    vault = tmp_path / 'vault'
    notes = vault / '06 - Contacts/Meetings'
    notes.mkdir(parents=True)
    (notes / '2026-10-06 1000 Weekly Sync with Kim.md').write_text('## Summary\nPoland launch moved to March.\n')
    reply = any_answer.answer('When is the Poland launch?', root=tmp_path / 'root', vault=vault, hermes_runner=never,
                              kb_runner=lambda argv, timeout: lml_hermes.subprocess.CompletedProcess(argv, 1, '', ''))
    assert reply == 'Plain answer: True'
    assert 'Poland launch moved to March.' in (agent / 'seen.txt').read_text()


def test_forget_deletes_only_chats_mapped_before_the_agent(agent, root):
    calls = []
    def hermes(argv, timeout):
        calls.append(argv)
        return lml_hermes.subprocess.CompletedProcess(argv, 0, '', '')
    sid = '20261013-100000-abcd'
    assert lml_hermes.forget(root, sid, runner=hermes) == (set(), False)
    assert calls == [] and not (root / 'sessions' / sid).exists()
    make_session(root, now_local(), sid=sid)
    append_jsonl(root / 'hermes_map' / (sid + '.jsonl'), {'id': 'old-chat'})
    assert lml_hermes.forget(root, sid, runner=hermes) == (set(), False)
    assert calls == [['hermes', 'sessions', 'delete', 'old-chat', '--yes']]


def test_live_buttons_get_the_agents_whole_answer_as_one_piece(agent, root, now):
    said = []
    live_quick.answer({'kind': 'recap', 'screen': None}, said.append, root=root, now=now)
    assert said == ['Plain answer: True']
    assert live_quick.KINDS['recap'] in (agent / 'seen.txt').read_text()


@pytest.mark.parametrize('name, reason', [('fail', 'agent'), ('empty', 'agent'), ('slow', 'timeout')])
def test_a_failed_agent_is_a_quick_failure(agent, root, now, monkeypatch, name, reason):
    mode(monkeypatch, name)
    monkeypatch.setattr(live_quick, 'DEADLINE_S', 1)
    with pytest.raises(live_quick.QuickFailed, match=reason):
        live_quick.answer({'kind': 'say'}, lambda text: None, root=root, now=now)
    if name == 'slow':
        assert gone(agent / 'agent.pid')


def test_read_screen_without_an_api_credential_says_it_needs_the_api(agent, root, now, monkeypatch):
    monkeypatch.setattr(lml_screen, 'SECRET_TOOL', agent / 'no-such-tool')
    request = {'kind': 'screen', 'screen': live_quick.base64.b64encode(JPEG).decode()}
    with pytest.raises(live_quick.QuickFailed, match='screen_needs_api'):
        live_quick.answer(request, lambda text: None, root=root, now=now)
    assert not (agent / 'seen.txt').exists()


def test_read_screen_with_a_credential_still_streams_from_the_api(agent, root, now, monkeypatch):
    sent = []
    def stream(text, emit, *, image=None):
        sent.append(image)
        emit('From the API.')
    monkeypatch.setattr(live_quick, 'stream', stream)
    said = []
    image = live_quick.base64.b64encode(JPEG).decode()
    live_quick.answer({'kind': 'screen', 'screen': image}, said.append, root=root, now=now)
    assert said == ['From the API.'] and sent == [image]


# The smallest JPEG the screen check accepts: start marker, a 1x1 frame header, end marker.
JPEG = b'\xff\xd8\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xd9'
