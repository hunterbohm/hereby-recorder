"""The meeting bot: sends Hermes's notetaker into Google Meet calls the user picks, then files what it heard.

The bot itself is a service (bot/ in this repo): every bot is a Chrome in its own container, signed in as the notetaker
account. This module is the mini's side. State lives in $MEETING_BOT_ROOT (default ~/.local/state/meeting-bot, mode
0700):

  optins.json    the calendar calls the user picked, by event key (the key lml_status puts in status.json)
  bots/<id>.json one record per bot started
  chat-logs/     the meeting chat each bot saw, one JSON line per message
  audio/<id>/    the call audio while it waits to be transcribed (removed once filed)
  tick.json      what the last tick learned (calendar check time, last problem)

The notes are not written here. A call is transcribed with Hereby's importer (`lml-import file`) and handed to the
recorder's own filing path with live-meeting-receive and live-meeting-done, carrying the calendar event key.
"""
import argparse
import fcntl
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import timedelta, timezone
from pathlib import Path

from lml_common import atomic_write, dt, forgotten, locked, now_local, private_dir, read_json, root_path, safe_key

HERE = Path(__file__).resolve().parent
MEET = re.compile(r'^https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:[/?#]\S*)?$')
TERMINAL = ('filed', 'failed', 'cancelled')
ACTIVE = ('joining', 'waiting_room', 'in_call')
PHASE_OF_STATE = {'signing_in': 'joining', 'joining': 'joining', 'waiting_room': 'waiting_room', 'in_call': 'in_call',
                  'ended': 'ended', 'failed': 'failed'}
# The panel's words for a bot's phase.
STATE_OF_PHASE = {'joining': 'joining', 'waiting_room': 'waiting_room', 'in_call': 'in_call', 'ended': 'done',
                  'filed': 'done', 'failed': 'failed'}
REASONS = {
    'denied': 'it was not let in, or it was removed from the call',
    'waiting_room_timeout': 'nobody let it in within 10 minutes',
    'bot_not_found': 'the bot service lost it',
    'bot_restarted': 'the bot service restarted and lost the recording',
    'service_restart': 'the bot service restarted',
    'browser_stuck': 'its browser stopped responding',
}
OFF = {'state': 'off', 'chat': False, 'error': None}
LEAD = timedelta(minutes=1)
CALENDAR_WINDOW_MIN = 7 * 24 * 60
CALENDAR_RECHECK = timedelta(minutes=3)
RECHECK_REACH = timedelta(hours=24)
START_FAILURES_TOLD = 3
# A finished call whose audio is smaller than this heard nothing (an Ogg header alone is a few hundred bytes).
MIN_AUDIO_BYTES = 4000
FILING_ATTEMPTS = 3
FILING_RETRY = timedelta(minutes=2)
FILING_RESPAWNS = 6
KEEP = timedelta(days=14)
OPTIN_KEEP = timedelta(hours=36)
ADDRESSED = re.compile(r'\b(hermes|notetaker)\b', re.I)
MENTION = re.compile(r"(?i)@?\b(?:hermes|(?:\w+'s )?(?:ai )?notetaker)\b[,:]?")
MAX_REPLIES = 20
REPLIES_PER_TICK = 2
REPLY_CHARS = 1500
# What Hermes posts in the meeting chat when it texts the owner an answer.
SENT_NOTE = 'I texted you the answer.'
QUESTION_CHARS = 500


class Usage(Exception):
    """The request is wrong; exit 1."""


class Failure(Exception):
    """The service or the data is wrong; exit 2."""


class ServiceError(Failure):
    def __init__(self, status, detail):
        super().__init__(f'The bot service answered {status}: {detail}' if status else f'The bot service is unreachable: {detail}')
        self.status = status


def api_key():
    if os.environ.get('MEETING_BOT_API_KEY'):
        return os.environ['MEETING_BOT_API_KEY']
    try:
        result = subprocess.run(['security', 'find-generic-password', '-a', 'hermes', '-s', 'meeting-bot-api-token', '-w'],
                                capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        result = None
    if result is None or result.returncode or not result.stdout.strip():
        raise Failure('The bot service key is not in the login Keychain (account hermes, service meeting-bot-api-token).')
    return result.stdout.strip()


class Service:
    """The bot service's HTTP API. The key is read when first needed and goes only in the Authorization header."""

    def __init__(self, base, key=api_key):
        self.base, self._key, self._token = base.rstrip('/'), key, None

    def _request(self, method, path, body=None):
        self._token = self._token or self._key()
        headers = {'Authorization': 'Bearer ' + self._token, 'Accept': 'application/json', 'User-Agent': 'hermes-meeting-bot'}
        data = None
        if body is not None:
            data, headers['Content-Type'] = json.dumps(body).encode(), 'application/json'
        return urllib.request.Request(self.base + path, data=data, method=method, headers=headers)

    def _open(self, request, timeout):
        try:
            return urllib.request.urlopen(request, timeout=timeout)
        except urllib.error.HTTPError as exc:
            detail = exc.read(300).decode('utf-8', 'replace')
            try:
                detail = json.loads(detail).get('error') or detail
            except (ValueError, AttributeError):
                pass
            raise ServiceError(exc.code, str(detail).replace(self._token or '\0', '***')) from None
        except (urllib.error.URLError, OSError) as exc:
            raise ServiceError(0, str(getattr(exc, 'reason', exc))) from None

    def call(self, method, path, body=None):
        with self._open(self._request(method, path, body), 30) as response:
            raw = response.read()
        try:
            return json.loads(raw) if raw.strip() else None
        except ValueError:
            raise ServiceError(0, 'the answer was not JSON') from None

    def download(self, path, destination):
        """Stream a file to `destination`, which only exists afterwards if the whole body arrived."""
        destination = Path(destination)
        partial = destination.with_name(destination.name + '.part')
        try:
            with self._open(self._request('GET', path), 300) as response, open(partial, 'wb') as stream:
                shutil.copyfileobj(response, stream)
            os.replace(partial, destination)
        except ServiceError:
            partial.unlink(missing_ok=True)
            raise
        except OSError as exc:
            partial.unlink(missing_ok=True)
            raise ServiceError(0, str(exc)) from None


def default_root():
    return Path(os.environ.get('MEETING_BOT_ROOT') or '~/.local/state/meeting-bot').expanduser()


class Store:
    def __init__(self, root):
        self.root = Path(root).expanduser()

    def lock(self):
        return locked(self.root / 'lock')

    def bot(self, bot_id):
        return read_json(self.root / 'bots' / (safe_key(bot_id) + '.json'))

    def put(self, record):
        atomic_write(self.root / 'bots' / (safe_key(record['bot_id']) + '.json'), record)

    def bots(self):
        records = [read_json(path) for path in (self.root / 'bots').glob('*.json')]
        return sorted((r for r in records if isinstance(r, dict)), key=lambda r: (r['created_at'], r['bot_id']))

    def _dict(self, name):
        value = read_json(self.root / name, {})
        return value if isinstance(value, dict) else {}

    def optins(self):
        return self._dict('optins.json')

    def put_optins(self, value):
        atomic_write(self.root / 'optins.json', value)

    def tick_state(self):
        return self._dict('tick.json')

    def put_tick_state(self, value):
        atomic_write(self.root / 'tick.json', value)

    def audio_dir(self, bot_id):
        return private_dir(self.root / 'audio' / safe_key(bot_id))


@contextmanager
def try_lock(path):
    """Yields whether the lock was taken, without waiting for it."""
    path = Path(path)
    private_dir(path.parent)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            got = True
        except BlockingIOError:
            got = False
        yield got
    finally:
        os.close(fd)


# What the production app uses for each outside step. Tests replace them on the App.

def calendar_events(minutes):
    import lml_settings
    from live_meeting_brief import Sources, normalize_events
    sources = Sources.production(lml_settings.load())
    raw, health = sources.events(minutes)
    # A read that missed a calendar would show moves that did not happen; refuse it and let the tick try again.
    if not health.get('ok') or health.get('status') != 'ok':
        raise Failure(f"The calendar could not be read ({health.get('status') or 'unknown'}).")
    return normalize_events(raw, sources)


def schedule_events():
    """The events the panel was shown: schedule.json, written by the brief tick."""
    schedule = read_json(root_path() / 'schedule.json', {})
    schedule = schedule if isinstance(schedule, dict) else {}
    found = [e for e in schedule.get('events') or [] if isinstance(e, dict)]
    if isinstance(schedule.get('next'), dict):
        found.append(schedule['next'])
    return found


def answer_any(question):
    import any_answer
    return any_answer.answer(question)


def find_tool(name, env):
    if os.environ.get(env):
        return os.environ[env]
    for folder in (*os.environ.get('PATH', '').split(os.pathsep), '/opt/homebrew/bin', '/usr/local/bin'):
        if folder and os.access(Path(folder) / name, os.X_OK):
            return str(Path(folder) / name)
    return None


def convert_audio(source, destination):
    """The bot's Ogg Opus as a 16 kHz mono WAV, which AVFoundation (so lml-import) can open."""
    ffmpeg = find_tool('ffmpeg', 'MEETING_BOT_FFMPEG')
    if not ffmpeg:
        raise Failure('ffmpeg is not installed on the mini, so the call audio cannot be converted.')
    result = subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source),
                             '-ac', '1', '-ar', '16000', str(destination)], capture_output=True, text=True, timeout=1800)
    if result.returncode or not Path(destination).exists():
        raise Failure('ffmpeg could not convert the call audio: ' + (result.stderr.strip().splitlines() or ['no reason'])[-1][:200])


def lml_import_binary():
    default = Path.home() / 'Library/Application Support/LiveMeetingListener/bin/lml-import'
    for candidate in (os.environ.get('LML_IMPORT_BIN'), default, shutil.which('lml-import')):
        if candidate and os.access(candidate, os.X_OK):
            return str(candidate)
    raise Failure('lml-import is not installed on the mini (build it with import/scripts/install.sh).')


def utc(moment):
    return moment.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def transcribe(audio, started, workdir):
    """Turn an audio file into a recorder session with `lml-import file`: (sid, session folder), or None when nobody spoke.

    lml-import writes sessions/<sid>/{transcript.jsonl,meta.json} under --root, keeps a ledger there so a rerun on the
    same audio finds the same session, and prints one JSON line per file. Without --push it sends nothing anywhere.
    """
    root = private_dir(Path(workdir) / 'import')
    result = subprocess.run([lml_import_binary(), 'file', str(audio), '--root', str(root), '--started', utc(started)],
                            capture_output=True, text=True, timeout=4 * 3600)
    outcomes = []
    for line in result.stdout.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict):
            outcomes.append(item)
    failed = next((o for o in outcomes if o.get('outcome') == 'failed'), None)
    if failed or result.returncode and not outcomes:
        raise Failure('lml-import failed: ' + str((failed or {}).get('reason') or result.stderr.strip()[-200:] or result.returncode))
    outcome = outcomes[-1] if outcomes else {}
    if outcome.get('outcome') == 'skipped' and outcome.get('reason') == 'no speech':
        return None
    sid = outcome.get('sid')
    if outcome.get('outcome') not in ('imported', 'skipped') or not sid:
        raise Failure('lml-import did not produce a session (' + str(outcome.get('outcome') or 'no output') + ').')
    return sid, root / 'sessions' / sid


def run_step(argv, data=b''):
    result = subprocess.run(argv, input=data, capture_output=True, timeout=300)
    if result.returncode:
        raise Failure(f'{Path(argv[0]).name} exited {result.returncode}: {result.stderr.decode("utf-8", "replace").strip()[:200]}')


def spawn_filer(app, bot_id):
    log = os.open(private_dir(app.store.root) / 'filing.log', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        subprocess.Popen([sys.executable, str(HERE / 'meeting-bot'), 'file', bot_id], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    finally:
        os.close(log)


@dataclass
class App:
    store: Store
    service: object
    events: object = calendar_events
    schedule: object = schedule_events
    answer: object = answer_any
    convert: object = convert_audio
    transcribe: object = transcribe
    spawn: object = None
    receive: tuple = (str(HERE / 'live-meeting-receive'),)
    done: tuple = (str(HERE / 'live-meeting-done'),)
    now: object = now_local
    # The owner's display name in the meeting chat; None reads it from recorder.toml (user_name).
    owner: object = None

    def __post_init__(self):
        self.spawn = self.spawn or (lambda bot_id: spawn_filer(self, bot_id))


def service_url(root):
    """The bot service's address: $MEETING_BOT_URL, else the first line of <state root>/service-url."""
    if os.environ.get('MEETING_BOT_URL'):
        return os.environ['MEETING_BOT_URL']
    try:
        url = (Path(root) / 'service-url').read_text(encoding='utf-8').strip().splitlines()[0]
    except (OSError, IndexError):
        url = ''
    if not url.startswith(('https://', 'http://127.0.0.1')):
        raise Failure(f'The bot service address is not set: put its https URL in {Path(root) / "service-url"} (or set MEETING_BOT_URL).')
    return url


def production_app():
    root = private_dir(default_root())
    return App(Store(root), Service(service_url(root)))


# Calls and opt-ins.

def is_meet(url):
    return bool(MEET.match(str(url or '')))


def meet_code(url):
    found = re.search(r'meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})', str(url))
    return found.group(1) if found else str(url)


def same_meeting(a, b):
    return meet_code(a) == meet_code(b)


def z(moment):
    return moment.astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def clock(app, iso):
    moment, now = dt(iso).astimezone(), app.now().astimezone()
    return moment.strftime('%-I:%M %p' if moment.date() == now.date() else '%a %-I:%M %p')


def describe(exc):
    return str(exc) if isinstance(exc, Failure) else f'{type(exc).__name__}: {exc}'


def reason(error):
    return REASONS.get(error) or (str(error) if error else 'no reason was given')


def label(record):
    return record.get('title') or 'the call'


def hermes_field(entry, record):
    """The panel's `hermes` object for an opt-in and its bot record, if any."""
    chat = bool(entry.get('chat'))
    if not record:
        failed = entry.get('failures', 0) >= START_FAILURES_TOLD
        return {'state': 'failed' if failed else 'scheduled', 'chat': chat, 'error': entry.get('error') if failed else None}
    state = STATE_OF_PHASE.get(record['phase'], 'off')
    return {'state': state, 'chat': chat, 'error': reason(record.get('error')) if state == 'failed' else None}


def hermes_states(root=None):
    """Event key -> hermes field for every opt-in. Read-only, and an empty or broken state gives {}."""
    store = Store(root or default_root())
    states = {}
    for key, entry in store.optins().items():
        if not isinstance(entry, dict):
            continue
        record = store.bot(entry['bot_id']) if entry.get('bot_id') else None
        states[key] = hermes_field(entry, record if isinstance(record, dict) else None)
    return states


def find_entry(optins, ident):
    if ident in optins:
        return ident
    return next((key for key, entry in optins.items() if entry.get('event_id') and entry['event_id'] == ident), None)


def find_event(app, ident):
    """The upcoming event the panel was shown, from schedule.json. The panel commands stay off the network."""
    now = app.now()
    for event in app.schedule():
        try:
            if ident in (event.get('key'), event.get('event_id')) and dt(event['end']) > now:
                return event
        except (KeyError, TypeError, ValueError):
            continue
    raise Failure(f'No upcoming calendar event {ident}.')


def new_record(app, *, url, chat, trigger, event, bot_id):
    return {'bot_id': bot_id, 'meeting_url': url, 'chat': chat, 'trigger': trigger,
            'event_key': event['key'] if event else None, 'title': event.get('title') if event else None,
            'start': event.get('start') if event else None, 'created_at': app.now().isoformat(), 'phase': 'joining',
            'error': None, 'told': [], 'changes': [], 'audio_bytes': 0, 'chat_log': [], 'seen_chat': [], 'said': [],
            'replies': 0, 'pending': [], 'filing': None, 'sid': None, 'outcome': None}


def start_bot(app, *, url, chat, trigger, event):
    # The bot always reads the meeting chat (silently); whether Hermes may post is decided here, so the chat switch
    # works in the middle of a call.
    created = app.service.call('POST', '/bots', {'meeting_url': url, 'chat': True})
    if not isinstance(created, dict) or not created.get('id'):
        raise ServiceError(0, 'the answer had no bot id')
    record = new_record(app, url=url, chat=chat, trigger=trigger, event=event, bot_id=created['id'])
    app.store.put(record)
    return record


def delete_bot(app, record):
    """Shut a bot's container down for good. A bot the service no longer knows counts as gone."""
    try:
        app.service.call('DELETE', f"/bots/{record['bot_id']}")
    except ServiceError as exc:
        if exc.status != 404:
            raise


def cancel_bot(app, record):
    """Take a bot out of its call, then shut its container down."""
    if record['phase'] in ACTIVE:
        try:
            app.service.call('POST', f"/bots/{record['bot_id']}/leave")
        except ServiceError:
            pass
    delete_bot(app, record)


def optin_entry(event, chat, opted_at):
    """An opt-in keeps its own copy of the event, so its bot can be started without the calendar."""
    return {'chat': chat, 'event_id': event.get('event_id'), 'title': event.get('title'), 'start': event['start'],
            'end': event['end'], 'meeting_url': event['meeting_url'], 'bot_id': None, 'opted_at': opted_at,
            'failures': 0, 'error': None}


def ensure_bot(app, optins, key):
    """Start the bot for an opt-in that has none yet, once it is due. A failed start is kept on the opt-in for the tick."""
    entry, now = optins[key], app.now()
    if entry.get('bot_id') or now < dt(entry['start']) - LEAD or dt(entry['end']) <= now:
        return
    try:
        record = start_bot(app, url=entry['meeting_url'], chat=entry['chat'], trigger='calendar',
                           event={**entry, 'key': key})
    except Exception as exc:
        entry['failures'] = entry.get('failures', 0) + 1
        entry['error'] = describe(exc)
    else:
        entry.update(bot_id=record['bot_id'], failures=0, error=None)
    app.store.put_optins(optins)


def view(app, key):
    optins = app.store.optins()
    entry = optins.get(key)
    if not entry:
        return {'key': key, 'hermes': dict(OFF)}
    record = app.store.bot(entry['bot_id']) if entry.get('bot_id') else None
    return {'key': key, 'hermes': hermes_field(entry, record)}


def cmd_optin(app, args):
    """Record the choice and return. The tick starts the bot (a minute before, or at once if the call has begun)."""
    with app.store.lock():
        optins = app.store.optins()
        key = find_entry(optins, args.key)
        if key:
            entry = optins[key]
            record = app.store.bot(entry['bot_id']) if entry.get('bot_id') else None
            if not (record and record['phase'] == 'failed' and dt(entry['end']) > app.now()):
                return view(app, key)
            del optins[key]
        event = find_event(app, args.key)
        if not is_meet(event.get('meeting_url')):
            raise Failure(f"{event.get('title') or 'That call'} has no Google Meet link.")
        key = event['key']
        optins[key] = optin_entry(event, False, app.now().isoformat())
        app.store.put_optins(optins)
        return view(app, key)


def cmd_optout(app, args):
    """Drop the choice. A bot already in the call is marked to leave; the tick makes it leave."""
    with app.store.lock():
        optins = app.store.optins()
        key = find_entry(optins, args.key)
        if key:
            entry = optins.pop(key)
            record = app.store.bot(entry['bot_id']) if entry.get('bot_id') else None
            if record and record['phase'] in ACTIVE:
                record['cancel'] = True
                app.store.put(record)
            app.store.put_optins(optins)
    return {'key': key or args.key, 'hermes': dict(OFF)}


def cmd_chat(app, args):
    with app.store.lock():
        optins = app.store.optins()
        key = find_entry(optins, args.key)
        if not key:
            raise Failure('Hermes is not on for that call.')
        chat = args.state == 'on'
        optins[key]['chat'] = chat
        app.store.put_optins(optins)
        record = app.store.bot(optins[key]['bot_id']) if optins[key].get('bot_id') else None
        if record:
            record['chat'] = chat
            app.store.put(record)
        return view(app, key)


def chat_enabled(app, record):
    entry = app.store.optins().get(record.get('event_key') or '')
    return bool(entry['chat'] if entry else record.get('chat'))


def cmd_join(app, args):
    url = args.url.strip()
    if not is_meet(url):
        raise Usage('Only Google Meet links can be joined for now.')
    with app.store.lock():
        for record in app.store.bots():
            if record['phase'] not in TERMINAL and same_meeting(record['meeting_url'], url):
                raise Usage(f"The notetaker is already on that meeting (bot {record['bot_id']}).")
        record = start_bot(app, url=url, chat=args.chat, trigger='join', event=None)
    return {'bot_id': record['bot_id'], 'hermes': hermes_field({'chat': args.chat}, record)}


def pick_record(app, event_key, phases):
    if event_key:
        optins = app.store.optins()
        key = find_entry(optins, event_key)
        record = app.store.bot(optins[key]['bot_id']) if key and optins[key].get('bot_id') else None
        if not record or record['phase'] not in phases:
            raise Usage('Hermes is not in that call.')
        return record
    found = [r for r in app.store.bots() if r['phase'] in phases]
    if len(found) != 1:
        raise Usage('Hermes is not in a call.' if not found else 'Hermes is in several calls. Pass --event with the one you mean.')
    return found[0]


def post_chat(app, record, text):
    app.service.call('POST', f"/bots/{record['bot_id']}/chat", {'message': text})
    record['said'].append({'at': z(app.now()), 'text': text})
    app.store.put(record)


def cmd_say(app, args):
    text = ' '.join(args.text.split())
    if not text:
        raise Usage('There is nothing to say.')
    with app.store.lock():
        record = pick_record(app, args.event, ('in_call',))
        if not chat_enabled(app, record):
            raise Usage('Chat replies are off for this call.')
        post_chat(app, record, text)
    return {'bot_id': record['bot_id'], 'sent': text}


def cmd_leave(app, args):
    with app.store.lock():
        record = pick_record(app, args.event, ACTIVE)
        app.service.call('POST', f"/bots/{record['bot_id']}/leave")
    return {'bot_id': record['bot_id'], 'left': True}


def cmd_status(app, args):
    optins = app.store.optins()
    bots = [{k: r.get(k) for k in ('bot_id', 'event_key', 'title', 'phase', 'error', 'chat', 'meeting_url', 'created_at',
                                   'outcome', 'sid')} | {'chat_messages': len(r.get('chat_log') or [])}
            for r in app.store.bots()]
    return {'optins': {key: {**entry, 'hermes': hermes_field(entry, app.store.bot(entry['bot_id']) if entry.get('bot_id') else None)}
                       for key, entry in optins.items()}, 'bots': bots}


# The tick.

def tell(record, tag, text, messages):
    if tag not in record['told']:
        record['told'].append(tag)
        messages.append(text)


def new_chat(record, messages_seen):
    seen = set(record['seen_chat'])
    fresh = [m for m in messages_seen if isinstance(m, dict) and m.get('id') and m['id'] not in seen]
    for message in fresh:
        record['seen_chat'].append(message['id'])
        record['chat_log'].append({k: message.get(k) for k in ('id', 'sender', 'text', 'at')})
    return fresh


def owner_name(app):
    """The owner's name as the recorder knows it, or '' when recorder.toml does not set one."""
    if app.owner is not None:
        return str(app.owner).strip()
    import lml_settings
    name = lml_settings.load().user_name.strip()
    return '' if name == lml_settings.Settings().user_name else name


def is_owner(app, sender):
    """Only the owner's own chat messages are answered: the answer draws on private notes and everyone in the call sees it."""
    me, name = owner_name(app).casefold(), str(sender or '').casefold().strip()
    return bool(me) and (name == me or name.startswith(me + ' '))


def addressed(app, message, record):
    text = str(message.get('text') or '')
    sender = str(message.get('sender') or '').casefold()
    if not is_owner(app, message.get('sender')):
        return None
    if 'notetaker' in sender or 'hermes' in sender or text in [m['text'] for m in record['said']]:
        return None
    if not ADDRESSED.search(text):
        return None
    question = ' '.join(MENTION.sub(' ', text).split())[:QUESTION_CHARS]
    return question or None


def poll(app, record, messages, chats):
    """Update a running bot from the service. Queues the chat questions to answer once the state lock is released."""
    try:
        status = app.service.call('GET', f"/bots/{record['bot_id']}/status")
    except ServiceError as exc:
        if exc.status != 404:
            raise
        record.update(phase='failed', error='bot_not_found')
        return
    if (status or {}).get('state') == 'idle':
        # A started bot is never idle again unless its container restarted, and the recording went with it.
        record.update(phase='failed', error='bot_restarted')
        try:
            delete_bot(app, record)
        except ServiceError:
            pass
        return
    state = PHASE_OF_STATE.get((status or {}).get('state'))
    if not state:
        raise ServiceError(0, f"unknown bot state {(status or {}).get('state')!r}")
    record.update(changes=status.get('changes') or [], audio_bytes=int(status.get('audio_bytes') or 0),
                  error=status.get('error'))
    fresh = new_chat(record, status.get('chat') or [])
    record['phase'] = state
    if state == 'waiting_room':
        tell(record, 'waiting_room', f'The notetaker is waiting to be admitted to {label(record)}.', messages)
    # Questions wait in `pending` so a burst is answered a couple per tick. Turning chat off drops what was waiting.
    if state == 'in_call' and chat_enabled(app, record) and not record.get('cancel'):
        pending = record.get('pending', []) + [q for m in fresh if (q := addressed(app, m, record))]
        take = pending[:min(REPLIES_PER_TICK, max(0, MAX_REPLIES - record['replies']))]
        record['pending'] = pending[len(take):] if record['replies'] + len(take) < MAX_REPLIES else []
        record['replies'] += len(take)
        chats.extend((record['bot_id'], question) for question in take)
    else:
        record['pending'] = []
    if state in ('ended', 'failed'):
        conclude(app, record, state)


def conclude(app, record, state):
    """The call is over: file what the bot heard, or give up when it heard nothing."""
    admitted = any(c.get('state') == 'in_call' for c in record['changes'])
    record['ended_at'] = app.now().isoformat()
    if not admitted or record['audio_bytes'] < MIN_AUDIO_BYTES:
        record['phase'] = 'failed'
        record['error'] = record['error'] if state == 'failed' and record['error'] else (
            'it never got into the call' if not admitted else 'it recorded no audio')
        try:
            delete_bot(app, record)
        except ServiceError:
            pass
        return
    record['phase'] = 'ended'
    record['call_error'] = record['error'] if state == 'failed' else None


def announce(record, messages):
    if record['phase'] == 'failed':
        tell(record, 'failed', f"The notetaker could not record {label(record)}: {reason(record['error'])}.", messages)
    elif record['phase'] == 'ended' and record.get('call_error'):
        tell(record, 'stopped', f"The notetaker stopped early in {label(record)}: {reason(record['call_error'])}. "
                                'Filing what it heard.', messages)
    elif record['phase'] == 'filed':
        name = label(record)
        text = {'filed': f'Notes for {name} are being filed.',
                'mac': f'Hereby already recorded {name}, so Hermes made no second note. It kept the meeting chat.',
                'silent': f'Nobody spoke in {name}, so there are no notes to file.'}.get(record.get('outcome'))
        if text:
            tell(record, 'filed', text, messages)


def filer_running(app, bot_id):
    with try_lock(app.store.root / 'locks' / f'filing-{safe_key(bot_id)}.lock') as got:
        return not got


def drive_filing(app, record):
    """Start the detached filer for a finished call, or retry one that failed or died."""
    filing = record['filing'] = {'attempts': 0, 'spawned': 0, 'next_at': None, 'error': None, **(record.get('filing') or {})}
    if filer_running(app, record['bot_id']):
        return
    if filing['next_at'] and app.now() < dt(filing['next_at']):
        return
    if filing['spawned'] >= FILING_RESPAWNS:
        fail_filing(app, record, filing.get('error') or 'the filing process kept stopping')
        return
    filing['spawned'] += 1
    app.store.put(record)
    app.spawn(record['bot_id'])


def fail_filing(app, record, error):
    record.update(phase='failed', error=f'the notes could not be filed ({error})')
    audio = app.store.root / 'audio' / record['bot_id']
    if audio.exists():
        record['error'] += f'. The audio is kept in {audio}; `meeting-bot file {record["bot_id"]}` retries.'
    app.store.put(record)


def advance(app, record, messages, problems, chats):
    try:
        if record['phase'] in ACTIVE:
            # A removed bot is checked first: it may have got into the call since the last tick.
            poll(app, record, messages, chats)
        if record['phase'] == 'in_call' and record.get('cancel'):
            # Removed during the call: it leaves, and what it recorded so far is filed like any finished call.
            app.service.call('POST', f"/bots/{record['bot_id']}/leave")
            record['cancel'] = False
        elif record['phase'] in ACTIVE and record.get('cancel'):
            cancel_bot(app, record)
            record['phase'] = 'cancelled'
        if record['phase'] == 'ended':
            drive_filing(app, record)
        announce(record, messages)
    except Exception as exc:
        problems.append(f'{label(record)}: {describe(exc)}')
    finally:
        app.store.put(record)


def reconcile(app, state, messages, problems):
    """Prune old opt-ins, check the not-yet-joined ones against the calendar, then start any bot that is due."""
    now, optins = app.now(), app.store.optins()
    for key, entry in list(optins.items()):
        record = app.store.bot(entry['bot_id']) if entry.get('bot_id') else None
        over = dt(entry['end']) + OPTIN_KEEP < now
        if over and (not record or record['phase'] in TERMINAL):
            del optins[key]
    app.store.put_optins(optins)
    pending = [key for key, entry in optins.items() if not entry.get('bot_id') and dt(entry['end']) > now]
    checked = state.get('calendar_checked_at')
    if pending and not (checked and now - dt(checked) < CALENDAR_RECHECK):
        recheck(app, state, optins, pending, messages, problems)
    for key in [k for k, e in optins.items() if not e.get('bot_id')]:
        entry = optins[key]
        was = entry.get('failures', 0)
        ensure_bot(app, optins, key)
        if entry.get('failures', 0) == START_FAILURES_TOLD and was < START_FAILURES_TOLD:
            messages.append(f"The notetaker could not start for {entry.get('title') or 'a calendar call'}: {entry['error']}. "
                            'It keeps trying until the call ends.')


def recheck(app, state, optins, pending, messages, problems):
    now = app.now()
    furthest = max(dt(optins[key]['end']) for key in pending)
    try:
        events = app.events(int((furthest + RECHECK_REACH - now).total_seconds() // 60))
    except Exception as exc:
        problems.append(f'calendar: {describe(exc)}')
        return
    by_key = {e['key']: e for e in events}
    by_id = {e['event_id']: e for e in events if e.get('event_id')}
    state['calendar_checked_at'] = now.isoformat()
    for key in pending:
        entry = optins[key]
        title = entry.get('title') or 'a calendar call'
        event = by_id.get(entry.get('event_id')) or by_key.get(key)
        if event is None:
            # The calendar read caps how many events it returns, so one miss is not proof. Two in a row cancels.
            if entry.get('missing'):
                del optins[key]
                messages.append(f'{title} is no longer on the calendar, so the notetaker will not join.')
            else:
                entry['missing'] = True
        elif not is_meet(event.get('meeting_url')):
            del optins[key]
            messages.append(f'{title} no longer has a Google Meet link, so the notetaker will not join.')
        else:
            entry.pop('missing', None)
            if event['start'] != entry['start'] or event['end'] != entry['end'] or event['meeting_url'] != entry['meeting_url']:
                moved = optin_entry(event, entry['chat'], entry['opted_at'])
                del optins[key]
                optins[event['key']] = moved
                if event['start'] != entry['start']:
                    messages.append(f"{event.get('title') or title} moved, so the notetaker will join at "
                                    f"{clock(app, event['start'])} instead.")
    app.store.put_optins(optins)


def prune(app):
    cutoff = app.now() - KEEP
    for record in app.store.bots():
        if record['phase'] in TERMINAL and dt(record['created_at']) < cutoff:
            for path in (app.store.root / 'bots' / (record['bot_id'] + '.json'),
                         app.store.root / 'chat-logs' / (record['bot_id'] + '.jsonl')):
                path.unlink(missing_ok=True)
            shutil.rmtree(app.store.root / 'audio' / record['bot_id'], ignore_errors=True)


def answer_chats(app, chats):
    """Answer the questions the tick queued, after re-checking that Hermes may still speak. Returns the texts for
    the owner.

    The answer draws on the owner's private notes, and Meet shows only a display name, which a guest can copy. So
    the answer goes to the owner by text, never into the meeting chat; the chat only gets a short note that it was
    sent. A guest using the owner's name can at most make the owner get a text."""
    texts = []
    for bot_id, question in chats:
        try:
            reply = ' '.join(str(app.answer(question) or '').split())[:REPLY_CHARS]
        except Exception:
            continue
        if not reply:
            continue
        with app.store.lock():
            record = app.store.bot(bot_id)
            if record and record['phase'] == 'in_call' and chat_enabled(app, record):
                texts.append(f'You asked Hermes in {label(record)}: {question}\n{reply}')
                try:
                    post_chat(app, record, SENT_NOTE)
                except ServiceError:
                    pass
    return texts


def cmd_tick(app, args):
    messages, problems, chats = [], [], []
    with try_lock(app.store.root / 'tick.lock') as got:
        if not got:
            return ''
        with app.store.lock():
            state = app.store.tick_state()
            reconcile(app, state, messages, problems)
            for record in app.store.bots():
                if record['phase'] not in TERMINAL:
                    advance(app, record, messages, problems, chats)
                else:
                    announce_once(app, record, messages)
            prune(app)
            problem = '; '.join(problems) or None
            if problem and problem != state.get('last_error'):
                messages.append(f'The meeting notetaker check hit a problem: {problem}')
            state['last_error'] = problem
            app.store.put_tick_state(state)
        messages.extend(answer_chats(app, chats))
    return '\n'.join(messages)


def announce_once(app, record, messages):
    before = len(record['told'])
    announce(record, messages)
    if len(record['told']) != before:
        app.store.put(record)


# Filing a finished call. Runs detached (`meeting-bot file <bot id>`), so a long transcription never holds the tick.

def mac_recorded(app, key, own_sid):
    """The sid of a session Hereby recorded for this calendar event, if one reached the mini."""
    if not key:
        return None
    root = root_path()
    for path in sorted((root / 'sessions').glob('*')):
        meta = read_json(path / 'meta.json', {})
        if (isinstance(meta, dict) and key in (meta.get('cal_keys') or []) and not meta.get('bot_id') and meta.get('source') != 'bot'
                and not meta.get('test')
                and path.name != own_sid and not forgotten(root, path.name)):
            return path.name
    return None


def save_chat_log(app, record):
    rows = [{**m, 'from_bot': False} for m in record['chat_log']] + [
        {'sender': 'Hermes', 'text': m['text'], 'at': m['at'], 'from_bot': True} for m in record['said']]
    if rows:
        rows.sort(key=lambda m: str(m.get('at') or ''))
        path = private_dir(app.store.root / 'chat-logs') / (record['bot_id'] + '.jsonl')
        atomic_write(path, ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows))


def audio_start(record):
    """When the audio file begins: the bot starts recording the moment it is in the call."""
    for change in record['changes']:
        if change.get('state') == 'in_call' and change.get('at'):
            return dt(change['at'])
    return dt(record.get('start') or record['created_at'])


def file_call(app, record):
    """Do every step for one finished call. Returns ('filed' | 'mac' | 'silent', sid). Each step can be rerun."""
    bot_id = record['bot_id']
    save_chat_log(app, record)
    mac = mac_recorded(app, record.get('event_key'), record.get('sid'))
    if mac:
        delete_bot(app, record)
        return 'mac', None
    work = app.store.audio_dir(bot_id)
    ogg, wav = work / 'call.ogg', work / 'call.wav'
    if not wav.exists():
        if not ogg.exists():
            app.service.download(f'/bots/{bot_id}/audio', ogg)
        # The audio is safe here, so the container can go.
        try:
            delete_bot(app, record)
        except ServiceError:
            pass
        app.convert(ogg, wav)
    produced = app.transcribe(wav, audio_start(record), work)
    if produced is None:
        shutil.rmtree(work, ignore_errors=True)
        return 'silent', None
    sid, folder = produced
    transcript = (folder / 'transcript.jsonl').read_bytes()
    meta = json.loads((folder / 'meta.json').read_text(encoding='utf-8'))
    # source "bot" is what meeting processing reads as Hermes's own notetaker (check_listener.SOURCES).
    meta.update(source='bot', cal_keys=[record['event_key']] if record.get('event_key') else [], apps=['google_meet'],
                bot_id=bot_id, meeting_url=record['meeting_url'])
    if record.get('title'):
        meta['title'] = record['title']
    run_step([*app.receive, sid, 'transcript.jsonl', '0'], transcript)
    run_step([*app.receive, sid, 'meta.json', '0'], json.dumps(meta, ensure_ascii=False).encode())
    run_step([*app.done, sid, str(len(transcript))])
    shutil.rmtree(work, ignore_errors=True)
    return 'filed', sid


def cmd_file(app, args):
    bot_id = safe_key(args.bot_id)
    with try_lock(app.store.root / 'locks' / f'filing-{bot_id}.lock') as got:
        if not got:
            return {'bot_id': bot_id, 'filing': 'already running'}
        with app.store.lock():
            record = app.store.bot(bot_id)
            if not record:
                raise Usage(f'Unknown bot {bot_id}.')
            if record['phase'] == 'failed' and (app.store.root / 'audio' / bot_id).exists():
                # A manual retry of a call whose audio was kept.
                record.update(phase='ended', error=None, filing=None)
                app.store.put(record)
            if record['phase'] != 'ended':
                return {'bot_id': bot_id, 'filing': record['phase']}
        try:
            (outcome, sid), error = file_call(app, record), None
        except Exception as exc:
            outcome, sid, error = None, None, describe(exc)
        with app.store.lock():
            record = app.store.bot(bot_id)
            if outcome:
                record.update(phase='filed', outcome=outcome, sid=sid)
            else:
                filing = record['filing'] or {}
                filing['attempts'] = filing.get('attempts', 0) + 1
                filing['error'] = error
                filing['next_at'] = (app.now() + FILING_RETRY).isoformat()
                record['filing'] = filing
                if filing['attempts'] >= FILING_ATTEMPTS:
                    fail_filing(app, record, error)
            app.store.put(record)
        if error:
            raise Failure(error)
    return {'bot_id': bot_id, 'filing': outcome}


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def parser():
    top = Parser(prog='meeting-bot', description="Send Hermes's notetaker into Google Meet calls.")
    commands = top.add_subparsers(dest='command', required=True, parser_class=Parser)
    for name in ('optin', 'optout'):
        commands.add_parser(name).add_argument('key')
    chat = commands.add_parser('chat')
    chat.add_argument('key')
    chat.add_argument('state', choices=('on', 'off'))
    join = commands.add_parser('join')
    join.add_argument('url')
    join.add_argument('--chat', action='store_true')
    say = commands.add_parser('say')
    say.add_argument('text')
    say.add_argument('--event')
    leave = commands.add_parser('leave')
    leave.add_argument('--event')
    commands.add_parser('status')
    commands.add_parser('tick')
    commands.add_parser('file').add_argument('bot_id')
    return top


HANDLERS = {'optin': cmd_optin, 'optout': cmd_optout, 'chat': cmd_chat, 'join': cmd_join, 'say': cmd_say,
            'leave': cmd_leave, 'status': cmd_status, 'tick': cmd_tick, 'file': cmd_file}


def main(argv=None, app=None, out=None, err=None):
    out, err = out or sys.stdout, err or sys.stderr
    try:
        args = parser().parse_args(argv)
        result = HANDLERS[args.command](app or production_app(), args)
        code = 0
    except Usage as exc:
        result, code, message = None, 1, str(exc)
    except Exception as exc:
        result, code, message = None, 2, describe(exc)
    if code:
        err.write(' '.join(message.split()) + '\n')
    elif isinstance(result, str):
        if result:
            out.write(result + '\n')
    else:
        out.write(json.dumps(result, ensure_ascii=False) + '\n')
    return code
