import json
import os
import shutil
import stat
import subprocess
import sys
import threading
import time
from datetime import timedelta
from pathlib import Path

import pytest

from conftest import make_session
from lml_common import append_jsonl, atomic_write, dt, now_local, read_json
from lml_hermes import forget, meeting_lock

MINI = Path(__file__).resolve().parents[1]
SID = '20261023-163204-440d'
LINE1 = b'{"seq": 1, "text": "hello"}\n'
LINE2 = b'{"seq": 2, "text": "world"}\n'


def run(command, *args, stdin=b'', timeout=20, **kwargs):
    return subprocess.run([str(MINI / command), *map(str, args)], input=stdin, capture_output=True,
                          timeout=timeout, **kwargs)


def receive(name, offset, data):
    return run('live-meeting-receive', SID, name, offset, stdin=data)


def reply(result):
    return result.returncode, json.loads(result.stdout)


@pytest.fixture
def lml_root():
    return Path(os.environ['LML_ROOT'])


@pytest.fixture
def session(lml_root):
    return lml_root / 'sessions' / SID


@pytest.mark.parametrize('name', ['transcript.jsonl', 'marks.jsonl'])
def test_receive_appends_and_reports_size(session, name):
    assert reply(receive(name, 0, LINE1)) == (0, {'size': len(LINE1)})
    assert reply(receive(name, len(LINE1), LINE2)) == (0, {'size': len(LINE1 + LINE2)})
    assert (session / name).read_bytes() == LINE1 + LINE2


def test_resend_from_older_offset_converges(session):
    receive('transcript.jsonl', 0, LINE1)
    receive('transcript.jsonl', len(LINE1), LINE2)
    results = [receive('transcript.jsonl', len(LINE1), LINE2),
               receive('transcript.jsonl', 0, LINE1 + LINE2),
               receive('transcript.jsonl', 0, LINE1 + LINE2)]
    assert [reply(r) for r in results] == [(0, {'size': len(LINE1 + LINE2)})] * 3
    assert (session / 'transcript.jsonl').read_bytes() == LINE1 + LINE2


def test_short_remote_writes_nothing_and_reports_remote_size(session):
    receive('transcript.jsonl', 0, LINE1)
    assert reply(receive('transcript.jsonl', len(LINE1) + 5, LINE2)) == (3, {'size': len(LINE1)})
    assert reply(receive('marks.jsonl', 5, LINE2)) == (3, {'size': 0})
    assert (session / 'transcript.jsonl').read_bytes() == LINE1
    assert not (session / 'marks.jsonl').exists()


@pytest.mark.parametrize('name', ['transcript.jsonl', 'meta.json'])
def test_forgotten_session_receives_nothing(lml_root, session, hermes, name):
    forget(lml_root, SID, runner=hermes)
    result = receive(name, 0, LINE1)
    assert (result.returncode, result.stdout) == (4, b'')
    assert not session.exists()


def test_receive_waits_for_a_forget_in_progress(lml_root, session):
    with meeting_lock(lml_root, SID, exclusive=True):
        process = subprocess.Popen([str(MINI / 'live-meeting-receive'), SID, 'transcript.jsonl', '0'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        process.stdin.write(LINE1)
        process.stdin.close()
        time.sleep(0.5)
        assert process.poll() is None and not session.exists()
        append_jsonl(lml_root / 'forgotten.jsonl', {'sid': SID, 'at': now_local().isoformat()})
    assert process.wait(timeout=10) == 4
    assert not session.exists()


@pytest.mark.parametrize('args', [
    ('../x', 'transcript.jsonl', '0'), (SID, 'audio.wav', '0'), (SID, '../meta.json', '0'),
    (SID, 'transcript.jsonl', '-1'), (SID, 'transcript.jsonl', '1.5'), (SID, 'meta.json', '1'),
])
def test_bad_arguments_exit_2_and_touch_nothing(lml_root, args):
    assert run('live-meeting-receive', *args, stdin=LINE1).returncode == 2
    assert not lml_root.exists()


@pytest.mark.parametrize('name', ['meta.json', 'live.json', 'speakers.json'])
def test_replace_swaps_the_whole_file(session, name):
    longer, shorter = b'{"state": "active", "pad": "xxxxxxxxxxxx"}', b'{"state": "closed"}'
    assert reply(receive(name, 0, longer)) == (0, {'size': len(longer)})
    assert reply(receive(name, 0, shorter)) == (0, {'size': len(shorter)})
    assert (session / name).read_bytes() == shorter
    assert [p.name for p in session.iterdir()] == [name]


def test_replace_never_shows_a_partial_file(session):
    old, new = b'a' * 2_000_000, b'b' * 2_000_000
    receive('live.json', 0, old)
    seen, stop = set(), threading.Event()

    def read():
        while not stop.is_set():
            seen.add((session / 'live.json').read_bytes())

    reader = threading.Thread(target=read)
    reader.start()
    try:
        for data in (new, old, new, old, new):
            assert receive('live.json', 0, data).returncode == 0
    finally:
        stop.set()
        reader.join()
    assert seen <= {old, new}


def test_receive_creates_private_directories(lml_root, session):
    receive('transcript.jsonl', 0, LINE1)
    receive('meta.json', 0, b'{}')
    modes = {path: stat.S_IMODE(path.stat().st_mode) for path in (lml_root, lml_root / 'sessions', session)}
    assert set(modes.values()) == {0o700}
    assert {stat.S_IMODE(p.stat().st_mode) for p in session.iterdir()} == {0o600}


@pytest.fixture
def processing(tmp_path, monkeypatch):
    bin_dir, calls, release = tmp_path / 'bin', tmp_path / 'calls.jsonl', tmp_path / 'release'
    bin_dir.mkdir()
    stub = bin_dir / 'hermes'
    stub.write_text(f'''#!{sys.executable}
import json, sys, time
from pathlib import Path
with open({str(calls)!r}, 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
deadline = time.monotonic() + 30
while not Path({str(release)!r}).exists() and time.monotonic() < deadline:
    time.sleep(0.02)
''')
    stub.chmod(0o755)
    monkeypatch.setenv('PATH', f'{bin_dir}{os.pathsep}{os.environ["PATH"]}')
    monkeypatch.delenv('LML_DONE_CMD', raising=False)
    settings = Path(os.environ['XDG_CONFIG_HOME']) / 'hereby' / 'recorder.toml'
    settings.parent.mkdir(parents=True)
    settings.write_text('done_command = "hermes cron run listener-meeting-processing"\n')

    def recorded():
        return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    def started(at_least=0):
        deadline = time.monotonic() + 10
        while len(recorded()) < at_least and time.monotonic() < deadline:
            time.sleep(0.02)
        time.sleep(0.5)
        return recorded()

    yield started
    release.touch()


def end_session(state='closed'):
    receive('meta.json', 0, json.dumps({'sid': SID, 'state': state}).encode())
    receive('transcript.jsonl', 0, LINE1 + LINE2)
    return len(LINE1 + LINE2)


def done(transcript_bytes):
    return run('live-meeting-done', SID, transcript_bytes, timeout=10)


def test_done_starts_processing_once_without_holding_the_caller(lml_root, session, processing):
    size = end_session()
    assert done(size).returncode == 0
    assert processing(1) == [['cron', 'run', 'listener-meeting-processing']]
    with meeting_lock(lml_root, SID, exclusive=True, wait_seconds=2):
        pass
    record = read_json(session / 'done.json')
    assert record['transcript_bytes'] == size and dt(record['at'])
    assert done(size).returncode == 0
    assert processing(1) == [['cron', 'run', 'listener-meeting-processing']]


@pytest.mark.parametrize('state', ['active', None])
def test_done_refuses_a_session_that_has_not_ended(session, processing, state):
    size = end_session(state) if state else 0
    assert done(size).returncode == 3
    assert processing() == [] and not (session / 'done.json').exists()


def test_done_refuses_a_transcript_size_mismatch(session, processing):
    size = end_session()
    assert done(size - 1).returncode == 3
    assert processing() == [] and not (session / 'done.json').exists()


def test_done_for_a_forgotten_session_exits_4(lml_root, processing, hermes):
    size = end_session()
    forget(lml_root, SID, runner=hermes)
    assert done(size).returncode == 4
    assert processing() == []


def test_done_spawn_failure_exits_1_without_a_record(session, processing, monkeypatch, tmp_path):
    size = end_session()
    monkeypatch.setenv('LML_DONE_CMD', f'{tmp_path / "no-such-command"} cron run x')
    result = done(size)
    assert result.returncode == 1 and result.stderr
    assert processing() == [] and not (session / 'done.json').exists()


def test_late_import_is_accepted_and_waits_until_its_done_signal(lml_root, session, processing, tmp_path):
    from lml_status import status
    end = now_local() - timedelta(hours=6)
    meta = {'sid': SID, 'state': 'closed', 'source': 'phone', 'title': 'Call with Omar', 'heartbeat_at': end.isoformat(),
            'started_at': (end - timedelta(minutes=20)).isoformat(), 'ended_at': end.isoformat()}
    assert receive('meta.json', 0, json.dumps(meta).encode()).returncode == 0
    assert receive('transcript.jsonl', 0, LINE1 + LINE2).returncode == 0

    def recent():
        [entry] = status(lml_root, now_local(), processing=tmp_path / 'none.json', calendar=tmp_path / 'none.json',
                         vault=tmp_path / 'vault')['recent']
        return entry['title'], entry['state']
    assert recent() == ('Call with Omar', 'waiting')
    assert done(len(LINE1 + LINE2)).returncode == 0
    assert processing(1) == [['cron', 'run', 'listener-meeting-processing']]
    assert recent() == ('Call with Omar', 'filing')


def test_ask_answers_the_question_on_stdin(lml_root, tmp_path):
    make_session(lml_root, now_local(), sid=SID, test=True)
    stub = tmp_path / 'llm.py'
    stub.write_text('''import json, sys
from pathlib import Path
query = Path(sys.argv[sys.argv.index('--query-file') + 1]).read_text()
print('Session: ask-id', file=sys.stderr)
print(json.dumps({'type': 'result', 'text': 'The budget is $90,000.' if 'Question: What was the budget?' in query else 'question missing'}))
''')
    result = run('live-meeting-ask', stdin='  What was the budget?\n'.encode(),
                 env={**os.environ, 'LML_LLM_CMD': f'{sys.executable} {stub}'})
    assert (result.returncode, result.stdout) == (0, b'The budget is $90,000.\n')


def test_a_failed_live_answer_exits_1_with_the_message_on_stderr(lml_root, tmp_path):
    make_session(lml_root, now_local(), sid=SID, test=True)
    stub = tmp_path / 'llm.py'
    stub.write_text('raise SystemExit(1)\n')
    result = run('live-meeting-ask', stdin=b'What was the budget?', env={**os.environ, 'LML_LLM_CMD': f'{sys.executable} {stub}'})
    assert (result.returncode, result.stdout, result.stderr) == (1, b'', b'The meeting answer is unavailable right now.\n')


@pytest.mark.parametrize('stdin', [b'', b' \n\t'])
def test_ask_without_a_question_exits_2(stdin):
    result = run('live-meeting-ask', stdin=stdin)
    assert (result.returncode, result.stdout) == (2, b'')


def snapshot(path):
    return {str(p.relative_to(path)): (p.stat().st_size, p.stat().st_mtime_ns) for p in sorted(path.rglob('*'))}


def test_every_remote_command_reads_and_writes_only_under_lml_root(tmp_path):
    home, root, calls, ran = tmp_path / 'home', tmp_path / 'lml-elsewhere-test', tmp_path / 'hermes.jsonl', tmp_path / 'done-ran'
    decoy, now = home / '.local/state/live-meeting', now_local()
    make_session(decoy, now, sid='20261024-080000-decoy')
    append_jsonl(decoy / 'forgotten.jsonl', {'sid': SID, 'at': now.isoformat()})
    atomic_write(decoy / 'schedule.json', {'events': [{'key': 'decoy', 'title': 'DECOY', 'attendee_count': 2,
                                                       'start': (now + timedelta(minutes=5)).isoformat(),
                                                       'end': (now + timedelta(minutes=35)).isoformat()}]})
    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    (bin_dir / 'hermes').write_text(f'''#!{sys.executable}
import json, sys
with open({str(calls)!r}, 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
print('No sessions found.' if sys.argv[1:3] == ['sessions', 'list'] else '')
''')
    (bin_dir / 'hermes').chmod(0o755)
    (tmp_path / 'done.py').write_text(f'open({str(ran)!r}, "w").write("ran")')
    env = {**{k: v for k, v in os.environ.items() if k != 'PYTHONPATH'}, 'HOME': str(home), 'LML_ROOT': str(root),
           'PATH': f'{bin_dir}{os.pathsep}{os.environ["PATH"]}', 'LML_DONE_CMD': f'{sys.executable} {tmp_path / "done.py"}'}
    before = snapshot(home)

    asked = run('live-meeting-ask', stdin=b'What did they say?', env=env)
    assert (asked.returncode, asked.stdout) == (0, b'No meeting is being transcribed right now.\n')
    meta = {'sid': SID, 'state': 'closed', 'started_at': now.isoformat(), 'ended_at': now.isoformat(), 'heartbeat_at': now.isoformat()}
    for name, data in (('meta.json', json.dumps(meta).encode()), ('transcript.jsonl', LINE1 + LINE2)):
        assert run('live-meeting-receive', SID, name, 0, stdin=data, env=env).returncode == 0
    beat = {'at': now.isoformat(), 'app_version': '2.0.0', 'state': 'idle', 'sid': None, 'mic_ok': True, 'audio_ok': True}
    synced = run('live-meeting-sync-status', stdin=json.dumps(beat).encode(), env=env)
    assert synced.returncode == 0, synced.stderr
    feed = json.loads(synced.stdout)
    assert feed['schedule'] == {} and feed['status']['next'] is None and [r['sid'] for r in feed['status']['recent']] == [SID]
    assert run('live-meeting-done', SID, len(LINE1 + LINE2), env=env).returncode == 0
    deadline = time.monotonic() + 10
    while not ran.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert ran.exists() and read_json(root / 'sessions' / SID / 'done.json')['transcript_bytes'] == len(LINE1 + LINE2)
    assert sorted(p.name for p in (root / 'sessions' / SID).iterdir()) == ['done.json', 'handoff.log', 'meta.json', 'transcript.jsonl']
    forgot = run('live-meeting-forget', SID, env=env)
    assert forgot.returncode == 0, forgot.stderr

    assert not (root / 'sessions' / SID).exists() and read_json(root / 'heartbeat.json')['state'] == 'idle'
    assert [line['sid'] for line in map(json.loads, (root / 'forgotten.jsonl').read_text().splitlines())] == [SID]
    assert [json.loads(line) for line in calls.read_text().splitlines()] == [['sessions', 'list', '--source', 'lm-' + SID]] * 2
    assert snapshot(home) == before


COMMANDS = ['live-meeting-forget', 'live-meeting-receive', 'live-meeting-done', 'live-meeting-ask', 'live-meeting-quick']


@pytest.mark.parametrize('command', COMMANDS)
def test_command_runs_through_a_symlink_in_another_directory(tmp_path, command):
    links, copies = tmp_path / 'links', tmp_path / 'copies'
    links.mkdir()
    copies.mkdir()
    (links / command).symlink_to(MINI / command)
    shutil.copy2(MINI / command, copies / command)
    env = {key: value for key, value in os.environ.items() if key != 'PYTHONPATH'}

    def start(directory):
        return subprocess.run([str(directory / command), '--help'], input=b'', capture_output=True,
                              cwd=tmp_path, env=env, timeout=20)

    linked, copied = start(links), start(copies)
    assert linked.returncode == {'live-meeting-ask': 2, 'live-meeting-quick': 1}.get(command, 0), linked.stderr
    assert copied.returncode == 1 and b'ModuleNotFoundError' in copied.stderr


FAKE_HERMES = {
    'cron/__init__.py': '',
    'tools/__init__.py': '',
    'cron/jobs.py': '''import json, os
from pathlib import Path

def path():
    return Path(os.environ['HERMES_HOME']) / 'cron' / 'jobs.json'

def load():
    return json.loads(path().read_text()) if path().exists() else []

def save(jobs):
    path().parent.mkdir(parents=True, exist_ok=True)
    path().write_text(json.dumps(jobs))

def resolve_job_ref(ref):
    return next((job for job in load() if job['name'] == ref), None)
''',
    'tools/cronjob_tools.py': '''import json
from cron.jobs import load, save

def cronjob(action, job_id, **fields):
    jobs = load()
    for job in jobs:
        if job['name'] == job_id and action == 'update':
            job.update(fields)
    save(jobs)
    return json.dumps({'success': any(job['name'] == job_id for job in jobs)})
''',
    'cli.py': '''import argparse
from cron.jobs import load, save

parser = argparse.ArgumentParser(prog='hermes')
cron = parser.add_subparsers(dest='group', required=True).add_parser('cron')
actions = cron.add_subparsers(dest='action', required=True)
create, edit = actions.add_parser('create'), actions.add_parser('edit')
create.add_argument('--name')
edit.add_argument('job_id')
edit.add_argument('--schedule')
edit.add_argument('--prompt')
edit.add_argument('--agent', action='store_true')
for command in (create, edit):
    command.add_argument('--no-agent', action='store_true')
    command.add_argument('--failure-deliver')
    command.add_argument('--deliver')
    command.add_argument('--skill', action='append')
    command.add_argument('--script')
create.add_argument('schedule')
create.add_argument('prompt', nargs='?')
args = parser.parse_args()
fields = {'schedule': args.schedule, 'prompt': args.prompt, 'deliver': args.deliver, 'skills': args.skill,
          'script': args.script, 'failure_deliver': args.failure_deliver}
jobs = load()
if args.action == 'create':
    jobs.append({'name': args.name, 'no_agent': args.no_agent, **{k: v for k, v in fields.items() if v is not None}})
else:
    job = next(job for job in jobs if job['name'] == args.job_id)
    job.update({key: value for key, value in fields.items() if value is not None})
    if args.agent:
        job['no_agent'] = False
    if args.no_agent:
        job['no_agent'] = True
save(jobs)
''',
}


@pytest.fixture
def fake_home(tmp_path):
    home, package = tmp_path / 'home', tmp_path / 'fake-hermes'
    for relative, text in FAKE_HERMES.items():
        (package / relative).parent.mkdir(parents=True, exist_ok=True)
        (package / relative).write_text(text)
    executables = {
        tmp_path / 'venv/bin/python': f'#!/bin/sh\nexec "{sys.executable}" "$@"\n',
        tmp_path / 'bin/hermes': f'''#!/bin/sh
export HERMES_HOME="{home}/.hermes"
export VIRTUAL_ENV="{tmp_path}/venv"
export PYTHONPATH="{package}"
exec "$VIRTUAL_ENV/bin/python" "{package}/cli.py" "$@"
''',
        home / 'command-center/skills/custom-skills/meeting-processing/scripts/listener-watch.sh':
            '#!/bin/sh\necho wake-gate-output\n',
    }
    for path, text in executables.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)
    return home, {**os.environ, 'HOME': str(home), 'PATH': f'{tmp_path / "bin"}{os.pathsep}{os.environ["PATH"]}'}


def test_install_links_commands_and_converges_the_hermes_job(fake_home):
    home, env = fake_home
    canonical = home / 'command-center/skills/custom-skills/meeting-processing/scripts/listener-watch.sh'
    watch = home / '.hermes/scripts/listener-watch.sh'
    watch.parent.mkdir(parents=True)
    watch.symlink_to(canonical)

    def install(*args):
        result = subprocess.run(['sh', str(MINI / 'install.sh'), *args], env=env, capture_output=True, text=True,
                                timeout=60)
        assert result.returncode == 0, result.stderr
        return result.stdout

    def installed():
        links = {path.name: os.readlink(path) for path in (home / '.local/bin').iterdir()}
        return links, watch.is_symlink(), watch.read_bytes(), json.loads((home / '.hermes/cron/jobs.json').read_text())

    assert "'create'" in install('--dry-run')
    assert not (home / '.local').exists() and watch.is_symlink() and not (home / '.hermes/cron').exists()
    install()
    first = installed()
    links, watch_is_link, _, jobs = first
    assert links == {command: str(MINI / command) for command in COMMANDS + ['live-meeting-sync-status', 'meeting-bot']}
    assert not watch_is_link and canonical.read_text() == '#!/bin/sh\necho wake-gate-output\n'
    assert subprocess.run(['bash', str(watch)], env=env, capture_output=True, text=True).stdout == 'wake-gate-output\n'
    by_name = {item['name']: item for item in jobs}
    job = dict(by_name['listener-meeting-processing'])
    assert len(jobs) == 2 and 'meeting-processing' in job.pop('prompt')
    assert job == {'name': 'listener-meeting-processing', 'schedule': 'every 60m', 'deliver': 'local',
                   'skills': ['meeting-processing'], 'script': 'listener-watch.sh', 'no_agent': False,
                   'enabled_toolsets': ['terminal', 'file', 'skills']}
    tick = dict(by_name['meeting-bot-tick'])
    assert tick == {'name': 'meeting-bot-tick', 'schedule': 'every 1m', 'deliver': 'photon', 'failure_deliver': 'local',
                    'script': 'meeting-bot-tick.sh', 'no_agent': True}
    assert (home / '.hermes/scripts/meeting-bot-tick.sh').read_bytes() == (MINI / 'hermes-meeting-bot-tick.sh').read_bytes()
    assert "'edit'" in install('--dry-run')
    install()
    assert installed() == first
