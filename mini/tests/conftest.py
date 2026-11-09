import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lml_common import atomic_write, dt
from lml_records import Record


@pytest.fixture(autouse=True)
def isolated_environment(monkeypatch, tmp_path):
    monkeypatch.setenv('LML_ROOT', str(tmp_path / 'live-meeting-test'))
    monkeypatch.setenv('XDG_CONFIG_HOME', str(tmp_path / 'xdg'))
    monkeypatch.delenv('LML_LLM_CMD', raising=False)
    # The meeting bot never reaches the real service, the real key, or the real state from a test.
    monkeypatch.setenv('MEETING_BOT_ROOT', str(tmp_path / 'meeting-bot-state'))
    monkeypatch.setenv('MEETING_BOT_URL', 'http://127.0.0.1:9')
    monkeypatch.setenv('MEETING_BOT_API_KEY', 'test-key-not-real')
    for name in ('LML_SUPERVISE_SECONDS', 'LML_SUPERVISE_PAUSE_SECONDS', 'LML_SUPERVISE_READY_FILE', 'LML_LOCK_FD'):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture(autouse=True)
def no_screen_network(monkeypatch):
    import lml_screen
    def refused(prompt, **kwargs):
        raise lml_screen.ScreenFailed('offline')
    monkeypatch.setattr(lml_screen, 'ask', refused)


@pytest.fixture
def now():
    return dt('2026-10-13T10:15:00-05:00')


def event(key='event', start='2026-10-13T10:00:00-05:00', end='2026-10-13T11:00:00-05:00', **kwargs):
    return dict(key=key, start=start, end=end, has_conference=False, attendee_count=2, **kwargs)


def part(text='The budget is $70,000.', start='2026-10-13T10:14:00-05:00', end='2026-10-13T10:14:05-05:00', xo=0, words='aligned'):
    if words == 'aligned':
        count = len(text.split())
        duration = (dt(end) - dt(start)).total_seconds()
        words = [[duration * i / count, duration * (i + 1) / count] for i in range(count)]
    return dict(t0=start, t1=end, text=text, xo=xo, words=words)


def row(text='The budget is $70,000.', seq=1, ch='me', parts=None, **kwargs):
    parts = parts or [part(text)]
    return dict(seq=seq, ch=ch, ts0=parts[0]['t0'], ts1=parts[-1]['t1'],
                text=' '.join(p['text'] for p in parts), parts=parts, xo=0, **kwargs)


def make_session(root, now, *, sid='20261013-100000-abcd', rows=None, partials=None, speech=None, **meta):
    path = root / 'sessions' / sid
    values = dict(sid=sid, state='active', started_at='2026-10-13T10:00:00-05:00', ended_at=None,
                  heartbeat_at=now.isoformat())
    values.update(meta)
    atomic_write(path / 'meta.json', values)
    finals = rows if rows is not None else [row()]
    atomic_write(path / 'live.json', dict(finals=[], seq_hi=max([r.get('seq', 0) for r in finals], default=0),
                                        partials=partials or {}, speech=speech or {}))
    atomic_write(path / 'transcript.jsonl', ''.join(json.dumps(r) + '\n' for r in finals))
    return path


@pytest.fixture
def root(tmp_path, now):
    root = tmp_path / 'live-meeting-test'
    make_session(root, now)
    atomic_write(root / 'schedule.json', {'events': [event()]})
    atomic_write(root / 'briefs/event.md', '# Budget meeting\n\n' + Record('last.md', '2026-09-30', 'The budget is $90,000.').render())
    return root


def result_line(text):
    """The final event of `hermes chat --format stream-json`."""
    return json.dumps({'type': 'result', 'text': text}) + '\n'


class HermesStub:
    def __init__(self, reply='Budget answer.'):
        self.reply = reply
        self.ids = set()
        self.calls = []
        self.prompts = []
        self.count = 0

    def __call__(self, argv, timeout):
        self.calls.append((argv, timeout))
        if 'chat' in argv:
            self.count += 1
            identifier = f'session-{self.count}'
            self.ids.add(identifier)
            path = Path(argv[argv.index('--query-file') + 1])
            self.prompts.append(path.read_text())
            return SimpleNamespace(returncode=0, stdout=result_line(self.reply), stderr=f'Session: {identifier}\n')
        if 'list' in argv:
            output = json.dumps([{'id': i} for i in sorted(self.ids)])
            return SimpleNamespace(returncode=0, stdout=output, stderr='')
        if 'delete' in argv:
            self.ids.discard(argv[3])
            return SimpleNamespace(returncode=0, stdout='', stderr='')
        raise AssertionError('Unexpected command')


@pytest.fixture
def hermes():
    return HermesStub()
