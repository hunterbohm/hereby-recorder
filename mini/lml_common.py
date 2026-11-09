from __future__ import annotations

import fcntl
import json
import os
import re
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

import lml_settings

CONFIG_PATH = Path.home() / '.config/live-meeting/config.json'
LIVE_S = 90
RECORDING = ('recording', 'paused')
RECENT_ROWS = timedelta(minutes=15)
SOURCES = ('listener', 'phone', 'file', 'bot')


def now_local():
    return datetime.now().astimezone()


def dt(value):
    parsed = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('Timestamp needs a time zone')
    return parsed


def production_root():
    return lml_settings.load().storage_root


def root_path():
    return Path(os.environ['LML_ROOT'] if 'LML_ROOT' in os.environ else production_root()).expanduser()


def test_root(root):
    root = Path(root).resolve()
    return root != production_root().resolve() and ('test' in root.name.lower())


def safe_key(value):
    value = str(value)
    if not value or value in {'.', '..'} or '/' in value or '\\' in value or any(c in value for c in '*?[]\x00\n\r'):
        raise ValueError('Invalid storage key')
    return value


def nonnegative_int(text):
    if not (text.isascii() and text.isdigit()):
        raise ValueError('Expected a non-negative integer')
    return int(text)


def file_size(path):
    try:
        return Path(path).stat().st_size
    except FileNotFoundError:
        return 0


def private_dir(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def atomic_write(path, value):
    path = Path(path)
    private_dir(path.parent)
    if not isinstance(value, (str, bytes)):
        value = json.dumps(value, ensure_ascii=False)
    data = value.encode('utf-8') if isinstance(value, str) else value
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name + '.')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(name).unlink(missing_ok=True)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return default


def read_jsonl(path):
    try:
        data = Path(path).read_bytes()
    except OSError:
        return []
    result = []
    # The last piece is empty or a line still being written.
    for line in data.split(b'\n')[:-1]:
        try:
            item = json.loads(line)
            if isinstance(item, dict):
                result.append(item)
        except ValueError:
            continue
    return result


def append_jsonl(path, item):
    path = Path(path)
    private_dir(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, 'a', encoding='utf-8') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(item, ensure_ascii=False) + '\n')
        stream.flush()
        os.fsync(stream.fileno())


@contextmanager
def locked(path):
    path = Path(path)
    private_dir(path.parent)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(fd, 'r+') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def config(path=None):
    value = read_json(path or CONFIG_PATH, {})
    return value if isinstance(value, dict) else {}


def forgotten(root, sid):
    return any(item.get('sid') == sid for item in read_jsonl(Path(root) / 'forgotten.jsonl'))


@dataclass
class Session:
    path: Path
    meta: dict
    live: dict

    @property
    def sid(self):
        return self.path.name

    @property
    def source(self):
        return self.meta.get('source') if self.meta.get('source') in SOURCES else 'listener'

    def is_live(self, now):
        """Active, and its last meta push or a Mac heartbeat naming it arrived under 90 s ago."""
        pushed = (now - dt(self.meta['heartbeat_at'])).total_seconds()
        if self.meta.get('state') != 'active':
            return False
        if 0 <= pushed < LIVE_S:
            return True
        beat = read_json(self.path.parent.parent / 'heartbeat.json')
        try:
            received = (now - dt(beat['received_at'])).total_seconds()
        except (KeyError, TypeError, ValueError):
            return False
        return beat.get('sid') == self.sid and beat.get('state') in RECORDING and 0 <= received < LIVE_S

    def ended_at(self):
        return dt(self.meta.get('ended_at') or self.meta['heartbeat_at'])

    def rows(self, now):
        """Transcript finals that ended in the 15 minutes before now (or the session end), then live partials."""
        since = (now if self.is_live(now) else self.ended_at()) - RECENT_ROWS
        finals = []
        for row in self.transcript():
            try:
                if dt(row['ts1']) >= since:
                    finals.append(dict(row, partial=False))
            except (KeyError, TypeError, ValueError):
                continue
        partials = [dict(row, ch=ch, partial=True) for ch, row in self.live.get('partials', {}).items() if row]
        return finals + partials

    def transcript(self):
        return read_jsonl(self.path / 'transcript.jsonl')


def load_sessions(root, now, *, allow_test=False):
    result = []
    for path in (Path(root) / 'sessions').glob('*'):
        if not path.is_dir() or forgotten(root, path.name):
            continue
        meta = read_json(path / 'meta.json', {})
        live = read_json(path / 'live.json', {})
        if not isinstance(meta, dict):
            continue
        if not isinstance(live, dict):
            live = {}
        if meta.get('test') and not (allow_test and test_root(root)):
            continue
        try:
            session = Session(path, meta, live)
            session.is_live(now)
            session.ended_at()
        except (ValueError, KeyError, TypeError):
            continue
        result.append(session)
    return result


def select_session(root, now, *, recent=False, allow_test=False):
    sessions = load_sessions(root, now, allow_test=allow_test)
    live = [s for s in sessions if s.is_live(now)]
    if live:
        return max(live, key=lambda s: dt(s.meta['started_at']))
    ended = [s for s in sessions if 0 <= (now - s.ended_at()).total_seconds() < 1800]
    return max(ended, key=lambda s: s.ended_at()) if recent and ended else None


def normalize(text):
    return ' '.join(re.findall(r'\w+', str(text).casefold().replace('’', "'")))
