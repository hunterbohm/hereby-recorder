import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

import pytest

import lml_settings
from lml_common import atomic_write, read_json

REPO = Path(__file__).resolve().parents[2]
MINI = REPO / 'mini'
SCRIPT = REPO / 'handoff' / 'hereby-handoff.sh'
SID = '20261023-163204-440d'
TRANSCRIPT = b'{"seq": 1, "text": "hello"}\n{"seq": 2, "text": "world"}\n'


@pytest.fixture
def lml_root():
    return Path(os.environ['LML_ROOT'])


@pytest.fixture
def session(lml_root):
    return lml_root / 'sessions' / SID


@pytest.fixture(autouse=True)
def no_done_override(monkeypatch):
    monkeypatch.delenv('LML_DONE_CMD', raising=False)


def finish(session, state='closed', transcript=TRANSCRIPT):
    session.mkdir(parents=True, exist_ok=True)
    atomic_write(session / 'meta.json', {'sid': SID, 'state': state})
    (session / 'transcript.jsonl').write_bytes(transcript)
    return len(transcript)


def settings_file(tmp_path, text):
    folder = tmp_path / 'xdg' / 'hereby'
    folder.mkdir(parents=True)
    (folder / 'recorder.toml').write_text(text)


def done(size):
    return subprocess.run([str(MINI / 'live-meeting-done'), SID, str(size)], capture_output=True, text=True, timeout=20)


def handoff(session):
    return subprocess.run([str(SCRIPT), str(session)], capture_output=True, text=True, timeout=20)


def recording_command(tmp_path):
    calls = tmp_path / 'calls.jsonl'
    program = tmp_path / 'record.py'
    program.write_text(f'import json, sys\nopen({str(calls)!r}, "a").write(json.dumps(sys.argv[1:]) + "\\n")\n')

    def recorded():
        return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    return f'{shlex.quote(sys.executable)} {shlex.quote(str(program))}', recorded


def test_the_default_done_command_is_the_handoff_script_with_the_session_folder():
    assert shlex.split(lml_settings.Settings().done_command) == [str(SCRIPT), '{session}']
    assert os.access(SCRIPT, os.X_OK)


def test_with_no_settings_a_finished_session_runs_the_handoff_and_logs_its_transcript_path_in_the_session(lml_root, session):
    size = finish(session)
    result = done(size)
    assert result.returncode == 0, result.stderr
    path = session.resolve() / 'transcript.jsonl'
    assert (session / 'handoff.log').read_text() == f'{path}\n'
    assert not (lml_root / 'handoff.log').exists()
    assert read_json(session / 'done.json')['transcript_bytes'] == size
    assert read_json(session / 'handoff.json')['state'] == 'closed'


def test_a_second_done_signal_runs_nothing(lml_root, session):
    size = finish(session)
    assert done(size).returncode == 0
    assert done(size).returncode == 0
    assert (session / 'handoff.log').read_text().count('transcript.jsonl') == 1


def test_a_crashed_session_is_handed_off_with_its_state(session):
    size = finish(session, 'crashed')
    assert done(size).returncode == 0
    assert read_json(session / 'handoff.json')['state'] == 'crashed'


def test_sams_command_runs_once_with_no_session_argument(tmp_path, session):
    command, recorded = recording_command(tmp_path)
    settings_file(tmp_path, f'done_command = {json.dumps(command + " cron run listener-meeting-processing")}\n')
    size = finish(session)
    assert done(size).returncode == 0
    assert done(size).returncode == 0
    assert recorded() == [['cron', 'run', 'listener-meeting-processing']]
    assert not (session / 'handoff.json').exists()


def test_a_session_word_in_a_setting_becomes_the_session_folder(tmp_path, session):
    command, recorded = recording_command(tmp_path)
    settings_file(tmp_path, f'done_command = {json.dumps(command + " file {session}")}\n')
    assert done(finish(session)).returncode == 0
    assert recorded() == [['file', str(session)]]


def test_a_failing_command_leaves_the_session_unprocessed_and_a_fixed_one_runs(tmp_path, session):
    settings_file(tmp_path, 'done_command = "false"\n')
    size = finish(session)
    result = done(size)
    assert result.returncode == 1
    assert result.stderr.count('\n') == 1 and 'status 1' in result.stderr
    assert not (session / 'done.json').exists()
    command, recorded = recording_command(tmp_path)
    settings_file_path = tmp_path / 'xdg' / 'hereby' / 'recorder.toml'
    settings_file_path.write_text(f'done_command = {json.dumps(command)}\n')
    assert done(size).returncode == 0
    assert recorded() == [[]] and (session / 'done.json').exists()


def test_a_command_that_cannot_start_exits_1_without_a_record(tmp_path, session):
    settings_file(tmp_path, f'done_command = "{tmp_path / "missing"} {{session}}"\n')
    result = done(finish(session))
    assert result.returncode == 1 and result.stderr.count('\n') == 1
    assert not (session / 'done.json').exists()


def test_a_command_still_running_after_the_grace_is_left_detached(tmp_path, session):
    settings_file(tmp_path, 'done_command = "sleep 3"\n')
    assert done(finish(session)).returncode == 0
    assert (session / 'done.json').exists()


def test_the_script_prints_the_transcript_path_once(session):
    finish(session)
    first = handoff(session)
    assert (first.returncode, first.stdout) == (0, f'{session.resolve() / "transcript.jsonl"}\n')
    second = handoff(session)
    assert (second.returncode, second.stdout) == (0, '') and 'already' in second.stderr


def test_the_script_hands_off_again_when_the_transcript_grew(session):
    finish(session)
    assert handoff(session).stdout
    finish(session, transcript=TRANSCRIPT + b'{"seq": 3}\n')
    assert handoff(session).stdout


@pytest.mark.parametrize('state, code', [('active', 3), ('closed', 0)])
def test_the_script_waits_for_an_ended_session_and_skips_an_empty_transcript(session, state, code):
    finish(session, state, transcript=b'')
    result = handoff(session)
    assert (result.returncode, result.stdout) == (code, '')
    assert not (session / 'handoff.json').exists()


def test_the_script_rejects_a_missing_folder(tmp_path):
    assert handoff(tmp_path / 'absent').returncode == 1


def test_forgetting_a_session_removes_what_its_command_printed(lml_root, session, tmp_path, hermes):
    from lml_hermes import forget
    program = tmp_path / 'leak.py'
    program.write_text('print("private meeting content")\n')
    settings_file(tmp_path, f'done_command = {json.dumps(shlex.quote(sys.executable) + " " + shlex.quote(str(program)))}\n')
    assert done(finish(session)).returncode == 0
    assert 'private meeting content' in (session / 'handoff.log').read_text()
    forget(lml_root, SID, runner=hermes)
    assert not session.exists()
    assert not any('private meeting content' in p.read_text(errors='ignore') for p in lml_root.rglob('*') if p.is_file() and p.name != 'forgotten.jsonl')
