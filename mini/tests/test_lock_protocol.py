import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from lml_common import atomic_write, forgotten, read_json, read_jsonl
from lml_hermes import CallFailed, Forgotten, call, forget, meeting_lock

SID = '20261013-100000-abcd'
MINI = Path(__file__).resolve().parents[1]

STUB = '''import json, os, subprocess, sys, time
from pathlib import Path
root = Path(os.environ['LML_ROOT'])
store = root / 'stub_store'
store.mkdir(exist_ok=True)
argv = sys.argv
if 'chat' in argv:
    source = argv[argv.index('--source') + 1]
    (store / 'child-id.json').write_text(json.dumps({'id': 'child-id', 'source': source}))
    (root / 'child.json').write_text(json.dumps({'pid': os.getpid(), 'pgid': os.getpgrp()}))
    if os.environ.get('LML_STUB_GRANDCHILD'):
        subprocess.Popen([sys.executable, '-c', "import os, time; from pathlib import Path; Path(os.environ['LML_ROOT'], 'grandchild.pid').write_text(str(os.getpid())); time.sleep(60)"])
    print('Session: child-id', file=sys.stderr, flush=True)
    while not (root / 'release').exists():
        time.sleep(0.02)
    (root / 'child-exited').touch()
    print(json.dumps({'type': 'result', 'text': 'Budget answer.'}), flush=True)
elif 'list' in argv:
    source = argv[argv.index('--source') + 1]
    values = [json.loads(p.read_text()) for p in store.glob('*.json')]
    print(json.dumps([v for v in values if v['source'] == source]))
elif 'delete' in argv:
    (store / (argv[argv.index('delete') + 1] + '.json')).unlink(missing_ok=True)
else:
    raise SystemExit(1)
'''


def wait_for(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= deadline:
            pytest.fail('Timed out waiting for stub process state')
        time.sleep(0.01)


@pytest.fixture
def protocol(root, monkeypatch):
    stub = root / 'stub.py'
    stub.write_text(STUB)
    monkeypatch.setenv('LML_LLM_CMD', sys.executable + ' ' + str(stub))
    processes = []

    def runner(argv, timeout):
        return subprocess.run([sys.executable, str(stub), *argv[1:]], capture_output=True,
                              text=True, timeout=timeout, check=False)

    def spawn(code):
        process = subprocess.Popen([sys.executable, '-c', code], env={**os.environ, 'PYTHONPATH': str(MINI)},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        processes.append(process)
        return process

    prelude = f'''from pathlib import Path
import json, subprocess, sys, time
from lml_hermes import call, forget
root = Path({str(root)!r})
def runner(argv, timeout):
    return subprocess.run([sys.executable, {str(stub)!r}, *argv[1:]], capture_output=True, text=True, timeout=timeout)
'''
    yield SimpleNamespace(root=root, runner=runner, spawn=spawn, prelude=prelude)
    (root / 'release').touch()
    for process in processes:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)
    child = read_json(root / 'child.json', {})
    if child:
        try:
            os.killpg(child['pgid'], signal.SIGKILL)
        except ProcessLookupError:
            pass


def caller(protocol, *, delivery_pause=False, timeout=5):
    delivery = '''def deliver(text):
    (root / 'delivery-entered').touch()
    while not (root / 'deliver-release').exists():
        time.sleep(0.02)
    print(text, flush=True)
''' if delivery_pause else '''def deliver(text):
    print(text, flush=True)
'''
    return protocol.spawn(protocol.prelude + delivery + f'''
try:
    call(root, {SID!r}, 'PRIVATE TRANSCRIPT', timeout={timeout}, hermes_runner=runner, deliver=deliver)
except Exception as exc:
    print(type(exc).__name__, file=sys.stderr)
    raise SystemExit(1)
''')


def forgetter(protocol, *, wait_seconds=5):
    return protocol.spawn(protocol.prelude + f'''
remaining, waiting = forget(root, {SID!r}, runner=runner, wait_seconds={wait_seconds})
(root / 'forget-result.json').write_text(json.dumps([sorted(remaining), waiting]))
raise SystemExit(bool(remaining or waiting))
''')


def test_forget_during_child_waits_then_deletes(protocol):
    process = caller(protocol)
    wait_for(lambda: (protocol.root / 'child.json').exists())
    deleting = forgetter(protocol)
    wait_for(lambda: forgotten(protocol.root, SID))
    assert deleting.poll() is None
    assert (protocol.root / 'stub_store/child-id.json').exists()
    (protocol.root / 'release').touch()
    stdout, stderr = process.communicate(timeout=5)
    assert stdout == '' and stderr.strip() == 'Forgotten'
    assert deleting.communicate(timeout=5) == ('', '')
    assert deleting.returncode == 0
    assert read_json(protocol.root / 'forget-result.json') == [[], False]
    assert not (protocol.root / 'stub_store/child-id.json').exists()
    assert not (protocol.root / 'hermes_map' / (SID + '.jsonl')).exists()


def test_caller_after_tombstone_emits_no_meeting_text_and_makes_no_call(protocol):
    assert forget(protocol.root, SID, runner=protocol.runner) == (set(), False)
    # Recreate a stale mirror as a late sync could do.
    atomic_write(protocol.root / 'sessions' / SID / 'meta.json', {'sid': SID})
    delivered = []
    with pytest.raises(Forgotten):
        call(protocol.root, SID, lambda: pytest.fail('Read forgotten context'),
             hermes_runner=protocol.runner, deliver=delivered.append)
    assert not delivered and not (protocol.root / 'child.json').exists()


def test_mapping_failure_still_deletes_printed_id(protocol, monkeypatch):
    (protocol.root / 'release').touch()
    from lml_common import append_jsonl
    def fail_mapping(path, item):
        if Path(path).parent.name == 'hermes_map':
            raise OSError('PRIVATE TRANSCRIPT')
        append_jsonl(path, item)
    monkeypatch.setattr('lml_hermes.append_jsonl', fail_mapping)
    with pytest.raises(CallFailed, match='Meeting model call failed'):
        call(protocol.root, SID, 'PRIVATE TRANSCRIPT', hermes_runner=protocol.runner)
    assert not (protocol.root / 'stub_store/child-id.json').exists()
    assert not list((protocol.root / 'queries').glob('*'))
    assert forget(protocol.root, SID, runner=protocol.runner) == (set(), False)


def test_mapping_survives_removed_mirror(protocol):
    import shutil
    shutil.rmtree(protocol.root / 'sessions' / SID)
    (protocol.root / 'release').touch()
    assert call(protocol.root, SID, 'PRIVATE TRANSCRIPT', hermes_runner=protocol.runner) == 'Budget answer.'
    assert read_jsonl(protocol.root / 'hermes_map' / (SID + '.jsonl'))[0]['id'] == 'child-id'
    assert not (protocol.root / 'sessions' / SID).exists()


def test_killed_caller_after_child_exit_releases_lock_and_tag_is_deleted(protocol):
    (protocol.root / 'release').touch()
    process = caller(protocol, delivery_pause=True)
    wait_for(lambda: (protocol.root / 'delivery-entered').exists())
    assert (protocol.root / 'child-exited').exists()
    process.kill()
    process.communicate(timeout=5)
    assert process.returncode == -signal.SIGKILL
    assert forget(protocol.root, SID, runner=protocol.runner) == (set(), False)
    assert not (protocol.root / 'stub_store/child-id.json').exists()
    assert not list((protocol.root / 'queries').glob('*'))


def test_sigkill_caller_leaves_child_lock_until_child_exits(protocol):
    process = caller(protocol)
    wait_for(lambda: (protocol.root / 'child.json').exists())
    child = read_json(protocol.root / 'child.json')
    process.kill()
    process.wait(timeout=5)
    assert process.returncode == -signal.SIGKILL
    os.kill(child['pid'], 0)
    assert [e['id'] for e in read_jsonl(protocol.root / 'hermes_map' / (SID + '.jsonl'))] == ['child-id']
    deleting = forgetter(protocol)
    wait_for(lambda: forgotten(protocol.root, SID))
    time.sleep(0.15)
    assert deleting.poll() is None
    assert not (protocol.root / 'forget-result.json').exists()
    assert (protocol.root / 'stub_store/child-id.json').exists()
    (protocol.root / 'release').touch()
    assert deleting.communicate(timeout=5) == ('', '')
    assert deleting.returncode == 0
    assert (protocol.root / 'child-exited').exists()
    assert not (protocol.root / 'stub_store/child-id.json').exists()
    process.communicate(timeout=5)


def test_sigkill_caller_with_hung_child_releases_lock_by_supervisor(protocol, monkeypatch):
    deadline = 3
    monkeypatch.setenv('LML_SUPERVISE_SECONDS', str(deadline))
    monkeypatch.setenv('LML_STUB_GRANDCHILD', '1')
    process = caller(protocol, timeout=45)
    wait_for(lambda: (protocol.root / 'child.json').exists())
    wait_for(lambda: (protocol.root / 'grandchild.pid').exists())
    child = read_json(protocol.root / 'child.json')
    try:
        time.sleep(0.1)
        started = time.monotonic()
        process.kill()
        process.wait(timeout=5)
        assert process.returncode == -signal.SIGKILL
        os.kill(child['pid'], 0)
        deleting = forgetter(protocol, wait_seconds=deadline + 5)
        wait_for(lambda: forgotten(protocol.root, SID))
        assert deleting.poll() is None
        assert deleting.communicate(timeout=deadline + 5) == ('', '')
        assert deleting.returncode == 0
        assert time.monotonic() - started < deadline + 5
        assert read_json(protocol.root / 'forget-result.json') == [[], False]
        assert not (protocol.root / 'release').exists()
        assert not (protocol.root / 'child-exited').exists()
        assert not (protocol.root / 'stub_store/child-id.json').exists()
        grandchild = int((protocol.root / 'grandchild.pid').read_text())
        for pid in [child['pid'], grandchild]:
            with pytest.raises(ProcessLookupError):
                os.kill(pid, 0)
        with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=0):
            pass
    finally:
        try:
            os.killpg(child['pgid'], signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)


@pytest.mark.parametrize('stage', ['before_supervisor', 'before_child'])
def test_sigkill_caller_before_spawn_releases_lock_by_deadline(protocol, monkeypatch, stage):
    deadline = 2
    marker = protocol.root / 'spawn-ready'
    monkeypatch.setenv('LML_SUPERVISE_SECONDS', str(deadline))
    if stage == 'before_supervisor':
        code = protocol.prelude + f"""
import lml_hermes
def paused_spawn(*args, **kwargs):
    Path({str(marker)!r}).touch()
    time.sleep(60)
lml_hermes.subprocess.Popen = paused_spawn
call(root, {SID!r}, 'PRIVATE TRANSCRIPT', hermes_runner=runner)
"""
        process = protocol.spawn(code)
    else:
        monkeypatch.setenv('LML_SUPERVISE_PAUSE_SECONDS', '5')
        monkeypatch.setenv('LML_SUPERVISE_READY_FILE', str(marker))
        process = caller(protocol, timeout=45)
    wait_for(marker.exists)
    assert not (protocol.root / 'child.json').exists()
    with pytest.raises(TimeoutError):
        with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=0):
            pass
    started = time.monotonic()
    process.kill()
    process.wait(timeout=5)
    with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=deadline + 5):
        pass
    assert time.monotonic() - started < deadline + 5
    assert not (protocol.root / 'child.json').exists()
    assert not (protocol.root / 'stub_store/child-id.json').exists()
    process.communicate(timeout=5)
    if stage == 'before_child':
        supervisor_pid = int(marker.read_text())
        wait_for(lambda: process_gone(supervisor_pid))


def process_gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


@pytest.mark.parametrize('code', [0, 7])
def test_supervisor_cli_passes_stdout_and_exit_code(protocol, code):
    from lml_hermes import run_chat
    with meeting_lock(protocol.root, SID) as fd:
        result = run_chat([sys.executable, '-c', f"print('stub output'); raise SystemExit({code})"], 5, fd)
    assert result.returncode == code
    assert result.stdout == 'stub output\n' and result.stderr == ''
    with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=0):
        pass


def test_chat_child_does_not_inherit_the_cron_lazy_install_block(protocol, monkeypatch):
    from lml_hermes import run_chat
    monkeypatch.setenv('HERMES_DISABLE_LAZY_INSTALLS', '1')
    monkeypatch.setenv('LML_KEPT', 'kept')
    probe = "import os; print(os.environ.get('HERMES_DISABLE_LAZY_INSTALLS'), os.environ.get('LML_KEPT'))"
    with meeting_lock(protocol.root, SID) as fd:
        result = run_chat([sys.executable, '-c', probe], 5, fd)
    assert (result.returncode, result.stdout) == (0, 'None kept\n')


def test_supervisor_spawn_failure_releases_lock_without_starting_child(protocol, monkeypatch):
    def spawn(*args, **kwargs):
        raise OSError('Supervisor unavailable')
    monkeypatch.setattr('lml_hermes.subprocess.Popen', spawn)
    with pytest.raises(CallFailed):
        call(protocol.root, SID, 'PRIVATE TRANSCRIPT', hermes_runner=protocol.runner)
    assert not (protocol.root / 'child.json').exists()
    with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=0):
        pass


def test_supervisor_deadline_exits_124_and_reaps_child(protocol, monkeypatch):
    from lml_hermes import run_chat
    monkeypatch.setenv('LML_SUPERVISE_SECONDS', '0.4')
    with meeting_lock(protocol.root, SID) as fd:
        result = run_chat([sys.executable, str(protocol.root / 'stub.py'), 'chat', '--source', 'lm-' + SID], 5, fd)
    child = read_json(protocol.root / 'child.json')
    assert result.returncode == 124
    assert result.stdout == ''
    assert result.stderr == 'Session: child-id\n'
    assert process_gone(child['pid'])
    with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=0):
        pass


def test_caller_timeout_before_child_spawn_stops_supervisor(protocol, monkeypatch):
    marker = protocol.root / 'spawn-ready'
    monkeypatch.setenv('LML_SUPERVISE_PAUSE_SECONDS', '5')
    monkeypatch.setenv('LML_SUPERVISE_READY_FILE', str(marker))
    process = caller(protocol, timeout=0.8)
    wait_for(marker.exists)
    stdout, stderr = process.communicate(timeout=2)
    assert stdout == '' and stderr.strip() == 'CallFailed'
    assert not (protocol.root / 'child.json').exists()
    assert process_gone(int(marker.read_text()))
    with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=0):
        pass


def test_timeout_kills_child_group_before_lock_release(protocol, monkeypatch):
    monkeypatch.setenv('LML_STUB_GRANDCHILD', '1')
    process = caller(protocol, timeout=0.8)
    wait_for(lambda: (protocol.root / 'grandchild.pid').exists())
    child = read_json(protocol.root / 'child.json')
    grandchild = int((protocol.root / 'grandchild.pid').read_text())
    assert os.getpgid(grandchild) == child['pgid']
    stdout, stderr = process.communicate(timeout=5)
    assert stdout == '' and stderr.strip() == 'CallFailed'
    assert process.returncode == 1
    # A group with no members cannot keep any inherited lock descriptor open.
    with pytest.raises(ProcessLookupError):
        os.killpg(child['pgid'], 0)
    with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=0):
        pass
    assert not (protocol.root / 'stub_store/child-id.json').exists()
    assert not list((protocol.root / 'queries').glob('*'))


def test_forget_timeout_is_bounded_and_can_be_retried(protocol):
    process = caller(protocol)
    wait_for(lambda: (protocol.root / 'child.json').exists())
    deleting = forgetter(protocol, wait_seconds=0.1)
    assert deleting.communicate(timeout=5) == ('', '')
    assert deleting.returncode == 1
    assert read_json(protocol.root / 'forget-result.json') == [[], True]
    assert process.poll() is None
    assert (protocol.root / 'stub_store/child-id.json').exists()
    assert (protocol.root / 'deletions' / (SID + '.json')).exists()
    (protocol.root / 'release').touch()
    assert process.communicate(timeout=5)[0] == ''
    assert forget(protocol.root, SID, runner=protocol.runner) == (set(), False)


@pytest.mark.parametrize('consumer', ['answer', 'nudge'])
def test_delivery_callback_is_inside_shared_lock(root, now, hermes, consumer):
    from live_answer import answer
    from live_meeting_nudge import tick
    from test_nudge import candidate
    if consumer == 'nudge':
        hermes.reply = json.dumps(candidate())
    delivered = []
    def delivery(text):
        fd = os.open(root / 'locks' / (SID + '.lock'), os.O_RDWR)
        try:
            with pytest.raises(BlockingIOError):
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(fd)
        delivered.append(text)
    if consumer == 'answer':
        assert answer('Budget?', root=root, now=now, runner=hermes, hermes_runner=hermes,
                      deliver=delivery) == 'Budget answer.'
    else:
        assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, deliver=delivery)
    assert len(delivered) == 1


def test_delivery_failure_deletes_printed_id(protocol):
    (protocol.root / 'release').touch()
    def failed_delivery(text):
        raise OSError('PRIVATE TRANSCRIPT')
    with pytest.raises(CallFailed):
        call(protocol.root, SID, 'PRIVATE TRANSCRIPT', hermes_runner=protocol.runner, deliver=failed_delivery)
    assert not (protocol.root / 'stub_store/child-id.json').exists()
    with meeting_lock(protocol.root, SID, exclusive=True, wait_seconds=0):
        pass


@pytest.mark.parametrize('consumer', ['answer', 'nudge'])
def test_entry_point_after_tombstone_makes_no_llm_call(root, now, hermes, consumer):
    from live_answer import NO_MEETING, answer
    from live_meeting_nudge import tick
    atomic_write(root / 'forgotten.jsonl', json.dumps({'sid': SID, 'at': now.isoformat()}) + '\n')
    if consumer == 'answer':
        assert answer('Budget?', root=root, now=now, runner=hermes) == NO_MEETING
    else:
        delivered = []
        assert tick(root=root, now=now, runner=hermes, deliver=delivered.append) == ''
        assert not delivered
    assert not hermes.calls
