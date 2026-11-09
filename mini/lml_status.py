import json
import os
import re
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.parse import quote
from zoneinfo import ZoneInfo

import lml_settings
from lml_common import dt, load_sessions, read_json, read_jsonl, safe_key
from lml_events import is_meeting
from lml_notes import front_matter, links, section
from lml_records import records

ENDED = {'closed', 'failed', 'crashed'}
FILING_GRACE = timedelta(minutes=75)
LATE_START = timedelta(hours=2)
MEETINGS = '06 - Contacts/Meetings'
TASKS = '02 - Planning/Task Records'
# Live work: the new words plus the old ones still in notes. backlog, triage, parked, done and canceled are not owed.
OWES = {'todo', 'in-progress', 'waiting', 'in-review', 'open', 'blocked'}
OWED = 5
CANCELLED = 'meeting/cancelled'
REVIEW_SENT = ('photon', 'discord-fallback')
RECENT = 5
TODAY = 8
LINE = 140
SNIPPET = 90
SUMMARY = 3
BULLET = re.compile(r'^[ \t]*(?:>[ \t]*)*(?:[-*+]|\d+\.)[ \t]+')
TIMES = re.compile(rb'"ts([01])":\s*"([^"\\]+)"')
DUPLICATE = re.compile(r'^duplicate of \[*([^\]|]+?)(?:\|[^\]]*)?\]*\.?(?: \(filed from [^)]*\))?$', re.I)


def _env(name, default):
    return Path(os.environ.get(name) or default).expanduser()


def _dict(value):
    return value if isinstance(value, dict) else {}


def _strings(value):
    return {item for item in value if isinstance(item, str)} if isinstance(value, (list, dict)) else set()


def _when(value):
    try:
        return dt(value)
    except (TypeError, ValueError):
        return None


def _stamp(moment, tz):
    return moment.astimezone(tz).isoformat(timespec='seconds')


def _read(path):
    try:
        return Path(path).read_text(encoding='utf-8')
    except (OSError, ValueError):
        return ''


def note_url(vault, relative):
    return f"obsidian://open?vault={quote(Path(vault).name, safe='')}&file={quote(relative.removesuffix('.md'), safe='')}"


def note_title(stem):
    return re.sub(r'^\d{4}-\d{2}-\d{2} \d{4} ', '', stem)


def _front(text):
    match = re.match(r'---\n(.*?\n)---[ \t]*(?:\n|$)', text, re.S)
    return match.group(1) if match else ''


def _scalar(front, key):
    match = re.search(rf'^{key}:[ \t]*(.*)$', front, re.M)
    return match.group(1).strip().strip('"\'') if match else ''


def _note_times(front, tz):
    start_s = _scalar(front, 'start')
    try:
        start, end = (datetime.fromisoformat(value) for value in (start_s, _scalar(front, 'end') or start_s))
    except ValueError:
        return None
    return tuple(t if t.tzinfo else t.replace(tzinfo=tz) for t in (start, end))


def calendar_note(started, ended, notes, tz):
    """check_listener.calendar_event: the note overlapping the capture most, or one that started up to 2h before it."""
    best = None
    for path, text in notes:
        front = _front(text)
        times = None if CANCELLED in front else _note_times(front, tz)
        if times is None:
            continue
        start, end = times
        overlap = (min(end, ended) - max(start, started)).total_seconds()
        if overlap <= 0 and not timedelta(0) <= started - start <= LATE_START:
            continue
        rank = (max(overlap, 0), -abs((started - start).total_seconds()))
        if best is None or rank > best[0]:
            best = (rank, path)
    return best[1] if best else None


def _plain(text):
    text = re.sub(r'!\[\[[^\]]*\]\]', ' ', text)
    text = re.sub(r'\[\[([^\]|]*)\|([^\]]*)\]\]', r'\2', text)
    text = re.sub(r'\[\[([^\]]*)\]\]', lambda m: m.group(1).split('#')[0].split('/')[-1], text)
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    text = re.sub(r'(?m)^[ \t]*(?:>[ \t]*)*(?:\[![^\]]*\][+-]?[ \t]*)?(?:#+[ \t]+|[-*+][ \t]+(?:\[.\][ \t]+)?|\d+\.[ \t]+)?', '', text)
    text = re.sub(r'\*\*|__|~~|`|\*', '', text)
    return ' '.join(text.split())


def _clip(text, limit=LINE):
    if len(text) <= limit:
        return text
    cut = text[:limit - 1]
    return (cut.rsplit(' ', 1)[0] if ' ' in cut[limit // 2:] else cut).rstrip(' ,;:.') + '…'


def _day(value):
    try:
        day = date.fromisoformat(value)
    except (TypeError, ValueError):
        return str(value)
    return f'{day:%b} {day.day}'


def brief_lines(text):
    items = sorted(records(text), key=lambda r: r.date, reverse=True)
    summaries = ((r.date, _plain(r.text.partition('\n')[2])) for r in items if r.kind == 'prior_meeting')
    actions = (_plain(line) for r in items if r.kind in {'action_item', 'commitment'} for line in r.text.splitlines())
    subjects = ((r.date, _plain(r.text.partition('\n')[0])) for r in items if r.kind == 'email')
    summary = next(((day, line) for day, line in summaries if line), None)
    action = next((line for line in actions if line), None)
    subject = next(((day, line) for day, line in subjects if line), None)
    lines = [summary and f'Last met {_day(summary[0])}: {summary[1]}', action and f'Open: {action}',
             subject and f'Email {_day(subject[0])}: {subject[1]}']
    return [_clip(line) for line in lines if line]


def owed(vault, note_text):
    """Titles of the user's open TaskNotes that link a person the meeting note lists, soonest first."""
    people = links(front_matter(note_text)[0].get('people'))
    if not people:
        return []
    tasks = []
    for path in (vault / TASKS).glob('*.md'):
        meta = front_matter(_read(path))[0]
        status, title = meta.get('status'), meta.get('title')
        if isinstance(status, str) and status in OWES and links(meta.get('people')) & people:
            when = str(meta.get('due') or meta.get('scheduled') or '')[:10] or '9999'
            tasks.append((when, title.strip() if isinstance(title, str) and title.strip() else path.stem))
    return [title for _, title in sorted(tasks)[:OWED]]


OFF = {'state': 'off', 'chat': False, 'error': None}


def hermes_states():
    """Event key -> the `hermes` field, from the meeting-bot state. Empty when Hermes is on for nothing or the state is unreadable."""
    try:
        import meeting_bot
        return meeting_bot.hermes_states()
    except Exception:
        return {}


def next_meeting(root, events, now, calendar, vault, hermes=None):
    upcoming = []
    for event in events if isinstance(events, list) else []:
        try:
            start, end = dt(event['start']), dt(event['end'])
            if end > now and is_meeting(event):
                upcoming.append((start, str(event['key']), event))
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
    if not upcoming:
        return None
    _, key, event = min(upcoming, key=lambda item: item[:2])
    relative = _dict(_dict(calendar.get('events')).get(event.get('event_id') or '')).get('path')
    if not isinstance(relative, str) or not (vault / relative).is_file():
        relative = None
    stem = Path(relative).stem if relative else None
    try:
        brief = _read(root / 'briefs' / (safe_key(key) + '.md'))
    except ValueError:
        brief = ''
    others = [name for name in event.get('people') or [] if isinstance(name, str) and name.strip()]
    return {'title': event.get('title') or (note_title(stem) if stem else 'Untitled meeting'),
            'start': event['start'], 'end': event['end'], 'meeting_url': event.get('meeting_url'),
            'note': stem, 'note_url': note_url(vault, relative) if relative else None,
            'brief': brief_lines(brief) if brief else [], 'owed': owed(vault, _read(vault / relative)) if relative else [],
            'with': others[0].split()[0] if len(others) == 1 else None,
            'key': key, 'hermes': dict((hermes or {}).get(key, OFF))}


def today(events, now, tz, hermes=None):
    """The rest of today's calendar from every account, in order: events not over yet that start before midnight."""
    midnight = datetime.combine(now.astimezone(tz).date() + timedelta(days=1), datetime.min.time(), tz)
    rows, seen = [], set()
    for event in events if isinstance(events, list) else []:
        try:
            start, end, key = dt(event['start']), dt(event['end']), str(event['key'])
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
        if end <= now or start >= midnight or key in seen:
            continue
        seen.add(key)
        title = event.get('title')
        url = event.get('meeting_url')
        rows.append((start, key, {'title': title if isinstance(title, str) and title.strip() else 'Untitled event',
                                  'start': event['start'], 'end': event['end'],
                                  'meeting_url': url if isinstance(url, str) and url else None,
                                  'meeting': is_meeting(event),
                                  'key': key, 'hermes': dict((hermes or {}).get(key, OFF))}))
    return [row for _, _, row in sorted(rows, key=lambda item: item[:2])][:TODAY]


class Ledger:
    """What meeting processing recorded about listener captures, keyed by note id lm-<sid>."""

    def __init__(self, state):
        listener = _dict(state.get('listener'))
        self.processed = _strings(listener.get('processed'))
        self.skipped = {key: reason for key, reason in _dict(listener.get('skipped')).items() if isinstance(key, str)}
        self.filed = {record.get('note_id'): name for name, record in _dict(state.get('filed')).items()
                      if isinstance(record, dict)}
        self.reviews = {}
        reviews = _dict(_dict(state.get('granola')).get('reviews')).values()
        for review in sorted((r for r in reviews if isinstance(r, dict)), key=lambda r: str(r.get('created_at') or '')):
            self.reviews[review.get('note_id')] = review

    def state(self, note_id, done_at, arrived, now):
        if note_id in self.processed:
            return 'filed'
        if note_id in self.skipped:
            return 'skipped'
        if done_at and now - done_at < FILING_GRACE:
            return 'filing'
        return 'waiting' if now - arrived < FILING_GRACE else 'failed'


def _items(text):
    """A section's bullets, one item each; a plain paragraph gives one item per sentence. Lead-ins ending in ':' are dropped."""
    chunks = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            chunks.append(None)
        elif BULLET.match(line) or not chunks or chunks[-1] is None:
            chunks.append([bool(BULLET.match(line)), line])
        else:
            chunks[-1].append(line)
    items = []
    for bullet, *lines in filter(None, chunks):
        plain = _plain('\n'.join(lines))
        items.extend([plain] if bullet else re.split(r'(?<=[.!?])\s+(?=[A-Z0-9"“])', plain))
    return [item for item in items if item and not item.endswith(':')]


def digest(text):
    """A filed note's one-line snippet and up to three bullets from its Summary, then its Decisions."""
    body = front_matter(text)[1]
    items = list(dict.fromkeys(item for name in ('Summary', 'Decisions') for item in _items(section(body, [name]))))
    return (_clip(items[0], SNIPPET) if items else None), [_clip(item) for item in items[:SUMMARY]]


def _spans(path):
    """(ts0, ts1, raw row) for each complete transcript row.

    Decoding every row as JSON costs about 10 ms per long session on each 60 s status call,
    so only the two times are read here and only the chosen row is decoded.
    """
    try:
        data = path.read_bytes()
    except OSError:
        return []
    spans = []
    for raw in data.split(b'\n')[:-1]:
        times = dict(TIMES.findall(raw))
        start, end = (_when(times.get(key, b'').decode('utf-8', 'replace')) for key in (b'0', b'1'))
        if start and end:
            spans.append((start, end, raw))
    return spans


def _text(raw):
    try:
        row = json.loads(raw)
    except ValueError:
        return ''
    text = row.get('text') if isinstance(row, dict) else None
    return ' '.join(text.split()) if isinstance(text, str) else ''


def spoken_at(spans, at):
    """The transcript line under way at `at` (the latest to start), else the last one that ended before it."""
    pools = (([span for span in spans if span[0] <= at <= span[1]], lambda span: span[0]),
             ([span for span in spans if span[1] < at], lambda span: span[1]))
    for pool, key in pools:
        while pool:
            span = max(pool, key=key)
            if text := _text(span[2]):
                return text
            pool.remove(span)
    return ''


def marked_moments(session, tz):
    marks = [at for at in (_when(item.get('at')) for item in read_jsonl(session.path / 'marks.jsonl')) if at]
    spans = _spans(session.path / 'transcript.jsonl') if marks else []
    return [{'at': _stamp(at, tz), 'text': _clip(spoken_at(spans, at))} for at in marks]


def _duplicated_note(reason, meetings):
    match = DUPLICATE.match(reason) if isinstance(reason, str) else None
    if not match:
        return None
    name = Path(match.group(1).strip()).name
    path = meetings / (name if name.endswith('.md') else name + '.md')
    return path if path.is_file() else None


def _review(review):
    if not review:
        return None
    tasks = review.get('tasks')
    return {'sent': review.get('delivery') in REVIEW_SENT, 'tasks': len(tasks) if isinstance(tasks, (dict, list)) else 0,
            'answered': bool(review.get('applied_at'))}


def recent_entry(session, now, ledger, vault, tz):
    sid, note_id = session.sid, 'lm-' + session.sid
    ended = session.ended_at()
    known_start = _when(session.meta.get('started_at'))
    started = known_start or ended
    meetings = vault / MEETINGS
    days = sorted({m.astimezone(tz).strftime('%Y-%m-%d') for m in (started - LATE_START, started, ended)})
    notes = [(path, _read(path)) for day in days for path in sorted(meetings.glob(f'{day} *.md'))]
    review = ledger.reviews.get(note_id) or {}
    recorded = [meetings / Path(name).name for name in (ledger.filed.get(note_id), review.get('meeting'))
                if isinstance(name, str)]
    filed = (next((path for path in recorded if path.is_file()), None)
             or next((path for path, text in notes if f'(session {sid})' in text), None))
    matched = calendar_note(started, ended, notes, tz)
    named = session.meta.get('title')
    title = (review.get('title') or (filed and note_title(filed.stem)) or (matched and note_title(matched.stem))
             or (isinstance(named, str) and named.strip()) or f'Call {started.astimezone(tz):%Y-%m-%d %H%M}')
    # An import lands closed, hours after the call, so the filing clock starts at its last arrival here.
    try:
        arrived = max(ended, datetime.fromtimestamp((session.path / 'meta.json').stat().st_mtime, tz))
    except OSError:
        arrived = ended
    state = ledger.state(note_id, _when(_dict(read_json(session.path / 'done.json')).get('at')), arrived, now)
    note = ((filed or matched) if state == 'filed'
            else _duplicated_note(ledger.skipped.get(note_id), meetings) if state == 'skipped' else None)
    snippet, summary = digest(_read(note)) if note else (None, [])
    return {'sid': sid, 'title': title, 'ended_at': _stamp(ended, tz),
            'duration_s': max(0, int((ended - known_start).total_seconds())) if known_start else None,
            'marks': len(read_jsonl(session.path / 'marks.jsonl')), 'state': state,
            'note': note.stem if note else None,
            'note_url': note_url(vault, f'{MEETINGS}/{note.name}') if note else None,
            'review': _review(review), 'snippet': snippet, 'summary': summary,
            'marked_moments': marked_moments(session, tz)}


def live_session(root, sessions, now, tz):
    """The session recording now and the warnings texted during it (or printed, in dry-run mode)."""
    current = [s for s in sessions if s.is_live(now)]
    if not current:
        return None
    session = max(current, key=lambda s: (_when(s.meta.get('started_at')) or s.ended_at(), s.sid))
    sent = [entry for entry in read_jsonl(root / 'nudges' / (session.sid + '.jsonl')) if entry.get('gate') == 'sent']
    warnings = [{'at': _stamp(at, tz), 'text': entry['text'], 'n': n}
                for n, entry in enumerate(sent, 1)
                if (at := _when(entry.get('at'))) and isinstance(entry.get('text'), str) and entry['text'].strip()]
    return {'sid': session.sid, 'warnings': warnings}


def status(root, now, *, processing=None, calendar=None, vault=None, tz=None):
    """C4 status.json for the panel. Reads only; a missing or malformed source gives nulls or []."""
    root = Path(root)
    processing = _dict(read_json(processing or _env('MEETING_PROCESSING_STATE', '~/.hermes/data/meeting-processing.json'), {}))
    calendar = _dict(read_json(calendar or _env('CALENDAR_SYNC_STATE', '~/.hermes/data/calendar-sync.json'), {}))
    vault = Path(vault or os.environ.get('MEETING_VAULT') or lml_settings.load().vault).expanduser()
    try:
        tz = tz or ZoneInfo(os.environ.get('CALENDAR_SYNC_TZ') or 'America/Chicago')
    except (KeyError, ValueError, OSError):
        tz = now.tzinfo
    schedule = _dict(read_json(root / 'schedule.json', {}))
    events = schedule.get('events')
    if isinstance(events, list) and isinstance(schedule.get('next'), dict):
        events = [*events, schedule['next']]
    sessions = load_sessions(root, now)
    ended = sorted((s for s in sessions if s.meta.get('state') in ENDED),
                   key=lambda s: (s.ended_at(), s.sid), reverse=True)[:RECENT]
    ledger = Ledger(processing)
    hermes = hermes_states()
    return {'v': 1, 'at': _stamp(now, tz), 'next': next_meeting(root, events, now, calendar, vault, hermes),
            'today': today(events, now, tz, hermes),
            'recent': [recent_entry(s, now, ledger, vault, tz) for s in ended],
            'live': live_session(root, sessions, now, tz)}
