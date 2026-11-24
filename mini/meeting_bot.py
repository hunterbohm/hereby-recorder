"""The meeting bot: sends Hermes's notetaker into Google Meet and Zoom calls the user picks, then files what it heard.

The bot itself is a service (bot/ in this repo): every bot is a Chrome in its own container, signed in as the notetaker
account. This module is the mini's side. State lives in $MEETING_BOT_ROOT (default ~/.local/state/meeting-bot, mode
0700):

  optins.json    the calendar calls the user picked, by event key (the key lml_status puts in status.json)
  bots/<id>.json one record per bot started
  chat-logs/     the meeting chat each bot saw, one JSON line per message
  audio/<id>/    the call audio while it waits to be transcribed (removed once filed)
  boards/<id>/   each whiteboard of the call as board-<n>.png and board-<n>.excalidraw, kept up to date during the call,
                 and final.json, the room's boards as the call left them
  logs/<id>-brain.log, logs/<id>-filing.log  what the call's whiteboard process and filer printed
  board-model.json  how the whiteboard reaches its model directly (board_brain.py); without it, through Hermes's chat
  voice-usage.jsonl  the minutes of call audio each call streamed to Deepgram for spoken commands, one line per call
  tick.json      what the last full check learned (calendar check time, last problem)
  outbox.jsonl   what the follower has for the owner until the next tick hands it on
  follow.log     what the last follower printed, which is only ever a failure

Every file about one call carries its bot id, and forget_call removes them all. A finished call goes after the
recorder's retention_days (recorder.toml, 14 by default), and at once when its notes are forgotten
(live-meeting-forget): the tick reads the recorder's forgotten sessions and forgets the call filed into each.

Hermes runs `meeting-bot tick` once a minute; it returns at once, handing on the outbox and starting the follower,
`meeting-bot follow`, which does the checking and keeps watching while a call is joining, under way or about to start.

During a call the whiteboard is driven by a process of its own, `meeting-bot brain <bot id>` (board_brain.py), which
the follower starts once the bot is in the call; it takes board commands from the call's board room the moment they are
heard or typed.

The notes are not written here. A call is transcribed with Hereby's importer (`lml-import file`) and handed to the
recorder's own filing path with live-meeting-receive and live-meeting-done, carrying the calendar event key.
"""
import argparse
import base64
import fcntl
import http.client
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

import board_brain
import meeting_board
from lml_common import (atomic_write, dt, forgotten, locked, now_local, private_dir, read_json, read_jsonl, root_path,
                        safe_key)

HERE = Path(__file__).resolve().parent
MEET = re.compile(r'^https://meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})(?:[/?#]\S*)?$')
# A Zoom link on zoom.us or a company subdomain of it, with the meeting number after /j/ (or /w/ for webinars).
ZOOM = re.compile(r'^https://(?:[a-z0-9-]+\.)*zoom\.us/[jw]/(\d{9,12})(?:[/?#]\S*)?$', re.I)
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
    'bot_lost': 'the bot stopped unexpectedly, so the last few seconds may be missing',
    'service_restart': 'the bot service restarted',
    'browser_stuck': 'its browser stopped responding',
    'bot_blocked': 'Zoom turned it away as a bot',
    'bad_link': 'Zoom did not accept the meeting link or passcode',
    'lost_call': 'it lost the call',
    'notice_failed': 'it could not post its recording notice in the meeting chat',
}
OFF = {'state': 'off', 'chat': False, 'error': None}
# A calendar call's bot is sent this long before the start: it takes about 40 seconds to reach the waiting room (a
# rehearsal call, 2026-11-21), so it is waiting there when the call starts.
LEAD = timedelta(minutes=2)
CALENDAR_WINDOW_MIN = 7 * 24 * 60
CALENDAR_RECHECK = timedelta(minutes=3)
RECHECK_REACH = timedelta(hours=24)
START_FAILURES_TOLD = 3
# A finished call whose audio is smaller than this heard nothing (an Ogg header alone is a few hundred bytes).
MIN_AUDIO_BYTES = 4000
FILING_ATTEMPTS = 3
FILING_RETRY = timedelta(minutes=2)
FILING_RESPAWNS = 6
OPTIN_KEEP = timedelta(hours=36)
ADDRESSED = re.compile(r'\b(hermes|notetaker)\b', re.I)
MENTION = re.compile(r"(?i)@?\b(?:hermes|(?:\w+'s )?(?:ai )?notetaker)\b[,:]?")
MAX_REPLIES = 20
REPLIES_PER_TICK = 2
REPLY_CHARS = 1500
# What Hermes posts in the meeting chat when it texts the owner an answer.
SENT_NOTE = 'I texted you the answer.'
QUESTION_CHARS = 500
# The whiteboard's own process for a call is started again at most this often if it stops.
BRAIN_RESTART = timedelta(seconds=30)
# The follower (`meeting-bot follow`, started by the tick) looks at a bot joining or waiting to be let in this often, so
# its whiteboard starts within seconds of it being let in; at a call under way (its chat, its audio, a removal from the
# panel) this often; and does the full check this often.
LOOK_JOINING_S = 2
LOOK_S = 5
CHECK_EVERY_S = 60
# The follower keeps running from this long before a calendar call's bot is due, so the bot is sent on the second even
# if Hermes's minute job runs only every 2 minutes.
WAKE_AHEAD = timedelta(seconds=150)
# Spoken commands: the bot streams the call to Deepgram and reports each phrase that starts with "Hermes". Nobody's name
# comes with it, so it goes wherever anyone's chat message could, and to the owner's question path only when asked
# straight to Hermes ("Hermes, what did we…?") with chat replies on.
SPOKEN = '(spoken)'


class Usage(Exception):
    """The request is wrong; exit 1."""


class Failure(Exception):
    """The service or the data is wrong; exit 2."""


class ServiceError(Failure):
    def __init__(self, status, detail):
        super().__init__(f'The bot service answered {status}: {detail}' if status else f'The bot service is unreachable: {detail}')
        self.status = status


class WholeAudioOnly(ServiceError):
    """A bot from before the copies during the call: it sends its whole recording or nothing."""


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

    def room(self, token):
        """The board room of the call with this board token (board_brain.Room), with the same key."""
        return board_brain.Room(self.base, token, self._key)

    def call(self, method, path, body=None):
        with self._open(self._request(method, path, body), 30) as response:
            raw = response.read()
        try:
            return json.loads(raw) if raw.strip() else None
        except ValueError:
            raise ServiceError(0, 'the answer was not JSON') from None

    def append(self, path, destination, offset, timeout=300):
        """Add to `destination` (`offset` bytes long) what the service has after them: the answer must say it starts
        there (`x-audio-from`), or, from a bot that cannot send part of its audio, be the whole file. A body cut short
        leaves what was written, which is still the start of what follows."""
        try:
            with self._open(self._request('GET', path), timeout) as response:
                start = response.headers.get('x-audio-from')
                if start is None and offset:
                    raise WholeAudioOnly(200, 'the bot cannot send part of its audio')
                if start is not None and start != str(offset):
                    raise ServiceError(200, f'the bot sent its audio from byte {start}, not {offset}')
                with open(destination, 'ab' if offset else 'wb') as stream:
                    shutil.copyfileobj(response, stream)
        except (OSError, http.client.HTTPException) as exc:
            raise ServiceError(0, str(exc) or type(exc).__name__) from None

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
        except (OSError, http.client.HTTPException) as exc:
            # A body cut short raises IncompleteRead, which is not an OSError.
            partial.unlink(missing_ok=True)
            raise ServiceError(0, str(exc) or type(exc).__name__) from None


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


def board_model(root):
    """The whiteboard's model: straight to the gateway named in board-model.json, else through Hermes's chat (whose
    session is deleted once read)."""
    def ask(text):
        from lml_hermes import ask_once
        return ask_once(root_path(), text, timeout=60)
    return board_brain.load_model(root, ask)


def call_log(app, bot_id, kind):
    """One call's log, so forgetting the call removes it too."""
    return private_dir(app.store.root / 'logs') / f'{safe_key(bot_id)}-{kind}.log'


def spawn_brain(app, bot_id):
    log = os.open(call_log(app, bot_id, 'brain'), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        subprocess.Popen([sys.executable, str(HERE / 'meeting-bot'), 'brain', bot_id], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    finally:
        os.close(log)


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


def spawn_follower(app):
    # Emptied each start, like tick.err: it holds what the last follower printed, which is only ever a failure.
    log = os.open(app.store.root / 'follow.log', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        subprocess.Popen([sys.executable, str(HERE / 'meeting-bot'), 'follow'], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    finally:
        os.close(log)


def spawn_filer(app, bot_id):
    log = os.open(call_log(app, bot_id, 'filing'), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
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
    model: object = board_model
    convert: object = convert_audio
    transcribe: object = transcribe
    spawn: object = None
    spawn_brain: object = None
    spawn_follower: object = None
    receive: tuple = (str(HERE / 'live-meeting-receive'),)
    done: tuple = (str(HERE / 'live-meeting-done'),)
    now: object = now_local
    # The owner's display name in the meeting chat; None reads it from recorder.toml (user_name).
    owner: object = None
    sleep: object = time.sleep
    clock: object = time.monotonic

    def __post_init__(self):
        self.spawn = self.spawn or (lambda bot_id: spawn_filer(self, bot_id))
        self.spawn_brain = self.spawn_brain or (lambda bot_id: spawn_brain(self, bot_id))
        self.spawn_follower = self.spawn_follower or (lambda: spawn_follower(self))


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

def can_join(url):
    """Google Meet and Zoom calls; Teams and the rest are not supported yet."""
    return bool(MEET.match(str(url or '')) or ZOOM.match(str(url or '')))


def meeting_code(url):
    """What identifies a call across its links: Meet's code, or Zoom's meeting number on any subdomain."""
    found = MEET.match(str(url or '')) or ZOOM.match(str(url or ''))
    return found.group(1) if found else str(url)


def same_meeting(a, b):
    return meeting_code(a) == meeting_code(b)


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
            'replies': 0, 'pending': [], 'filing': None, 'sid': None, 'outcome': None,
            'boards': [], 'board': None, 'board_commands': 0, 'presenting': False,
            'seen_heard': [], 'near_misses': [], 'voice': None, 'board_token': None, 'board_url': None, 'room_seq': 0}


def notice_text():
    """What the notetaker posts in the call's chat as it gets in (recorder.toml's notetaker_notice), or None for the bot
    service's own neutral notice."""
    import lml_settings
    return lml_settings.load().notetaker_notice


def start_bot(app, *, url, chat, trigger, event):
    # The bot always reads the meeting chat (silently); whether Hermes may post is decided here, so the chat switch
    # works in the middle of a call.
    # It also always listens for spoken commands; the service streams the call to speech-to-text only while in it.
    # Whatever the chat switch, it first posts its notice in the chat, and records, listens and reads the chat only once
    # the chat shows it.
    body = {'meeting_url': url, 'chat': True, 'voice': True}
    if notice := notice_text():
        body['notice'] = notice
    created = app.service.call('POST', '/bots', body)
    if not isinstance(created, dict) or not created.get('id'):
        raise ServiceError(0, 'the answer had no bot id')
    record = new_record(app, url=url, chat=chat, trigger=trigger, event=event, bot_id=created['id'])
    # The call's board room: the token is also what its live link is made of.
    if re.fullmatch(r'[0-9a-f]{32}', str(created.get('board_token') or '')):
        record.update(board_token=created['board_token'], board_url=created.get('board_url'))
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
    """Record the choice and return. The follower starts the bot (LEAD before, or at once if the call has begun)."""
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
        if not can_join(event.get('meeting_url')):
            raise Failure(f"{event.get('title') or 'That call'} has no Google Meet or Zoom link.")
        key = event['key']
        optins[key] = optin_entry(event, False, app.now().isoformat())
        app.store.put_optins(optins)
        return view(app, key)


def cmd_optout(app, args):
    """Drop the choice. A bot already in the call is marked to leave; the follower makes it leave within seconds."""
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
    if not can_join(url):
        raise Usage('Only Google Meet and Zoom links can be joined for now.')
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


def chat_lock(app, bot_id):
    """One chat line at a time per call: two sent at once can mix in the meeting's chat box."""
    return locked(app.store.root / 'locks' / f'chat-{safe_key(bot_id)}.lock')


def post_chat(app, record, text):
    with chat_lock(app, record['bot_id']):
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
                                   'outcome', 'sid', 'presenting', 'board_url')} | {'chat_messages': len(r.get('chat_log') or []),
                                                                       'boards': [b['title'] for b in r.get('boards') or []],
                                                                       'voice_minutes': voice_minutes(r)}
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


def new_heard(record, heard):
    """The spoken commands not seen before, as messages from SPOKEN."""
    seen = set(record.setdefault('seen_heard', []))
    fresh = []
    for item in heard:
        if not isinstance(item, dict) or not item.get('id') or item['id'] in seen or not str(item.get('text') or '').strip():
            continue
        seen.add(item['id'])
        record['seen_heard'].append(item['id'])
        text = meeting_board.spoken(item['text'])
        fresh.append({'id': item['id'], 'sender': SPOKEN, 'text': text[:QUESTION_CHARS + 20],
                      'at': item.get('at'), 'spoken': True, 'direct': bool(item.get('direct'))})
    return fresh


# Near misses kept with one call's record, and the longest kept of one.
NEAR_KEPT = 100
NEAR_CHARS = 200


def keep_near_misses(record, near):
    """What the bot heard that sounded like a board command with no name it knew, and the unnamed requests to start a
    board it took (`started`), kept in the call's record so the name rules can be tuned from real calls. The record is
    the only copy: it goes when the call is forgotten, after the recorder's retention_days or with its notes."""
    kept = record.setdefault('near_misses', [])
    seen = {item.get('id') for item in kept}
    for item in near:
        if not isinstance(item, dict) or not item.get('id') or item['id'] in seen or not str(item.get('text') or '').strip():
            continue
        seen.add(item['id'])
        kept.append({'id': str(item['id'])[:40], 'text': str(item['text'])[:NEAR_CHARS], 'at': item.get('at'),
                     **({'started': True} if item.get('started') else {})})
    del kept[:-NEAR_KEPT]


def spoken_question(message):
    """A question spoken straight to Hermes. Anyone may have said it, and the answer goes only to the owner by text.
    Only something said as a question counts, so a misheard command or a remark never makes the owner get a text, nor
    does frustration said like one ("what the f---?")."""
    question = ' '.join(MENTION.sub(' ', str(message.get('text') or '')).split())[:QUESTION_CHARS]
    asked = question.endswith('?') or meeting_board.QUESTION.match(meeting_board.POLITE.sub('', question))
    return question if message.get('direct') and asked and not meeting_board.frustrated(question) else None


def voice_minutes(record):
    return round(int((record.get('voice') or {}).get('streamed_seconds') or 0) / 60, 1)


def log_voice(app, record):
    """One line per call in voice-usage.jsonl with the minutes streamed to Deepgram, which is what it bills."""
    if record.get('voice_logged') or (record.get('voice') or {}).get('state', 'off') == 'off':
        return
    record['voice_logged'] = True
    # The bot id says which call; the title would be one more copy of the meeting's name to forget.
    line = {'bot_id': record['bot_id'], 'created_at': record['created_at'], 'ended_at': app.now().isoformat(),
            'minutes': voice_minutes(record), 'state': record['voice'].get('state')}
    path = private_dir(app.store.root) / 'voice-usage.jsonl'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps(line, ensure_ascii=False) + '\n').encode())
    finally:
        os.close(fd)


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
        lost(app, record, 'bot_not_found')
        return
    if (status or {}).get('state') == 'idle':
        # A started bot is never idle again unless its container restarted, and the recording went with it.
        lost(app, record, 'bot_restarted')
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
    if isinstance(status.get('voice'), dict):
        record['voice'] = status['voice']
        # Given up after drops, or at the per-call limit: either way spoken commands are over for this call.
        stopped = {'failed': 'stopped working', 'capped': 'stopped'}.get(status['voice'].get('state'))
        if stopped:
            tell(record, 'voice_failed', f"Spoken commands {stopped} in {label(record)} "
                                         f"({status['voice'].get('error') or 'no reason given'}). Typed ones in the "
                                         'meeting chat still work.', messages)
    if status.get('recording') == 'stopped':
        at = status.get('recording_stopped_at')
        when = f" at {dt(at).astimezone(app.now().tzinfo).strftime('%-I:%M %p')}" if at else ''
        tell(record, 'recording_stopped', f"The notetaker stopped recording {label(record)}{when} "
                                          f"({status.get('recording_error') or 'no reason given'}). It is still in the "
                                          'call, and what it recorded until then will be filed.', messages)
    if isinstance(status.get('notice'), dict):
        notice = record['notice'] = {k: status['notice'].get(k) for k in ('state', 'tries', 'error', 'at')}
        if notice['state'] == 'failed':
            tell(record, 'notice_failed', f'The notetaker is in {label(record)} but could not post its recording notice in '
                                          'the meeting chat, so it is not recording. It tries again every minute.', messages)
        elif notice['state'] == 'posted' and 'notice_failed' in record['told']:
            tell(record, 'notice_posted', f'The notetaker posted its recording notice in {label(record)} after all and is '
                                          'recording now.', messages)
    fresh = new_chat(record, status.get('chat') or [])
    spoken = new_heard(record, status.get('heard') or [])
    keep_near_misses(record, status.get('near_misses') or [])
    record['phase'] = state
    if state == 'waiting_room':
        tell(record, 'waiting_room', f'The notetaker is waiting to be admitted to {label(record)}.', messages)
    # Board commands are the whiteboard process's (board_brain.py), which has them from the board room already; here they
    # are only kept from being taken as questions.
    asked = board_messages(record, fresh + spoken)
    fresh = [m for m in fresh if m not in asked]
    spoken = [m for m in spoken if m not in asked]
    if state == 'in_call' and not record.get('cancel'):
        drive_brain(app, record)
    if record.get('board_failed'):
        tell(record, 'board_failed', f"The notetaker could not change the whiteboard in {label(record)}: "
                                     f"{record['board_failed']}", messages)
    if record.get('board_error') and record.get('boards'):
        tell(record, 'board_share', share_failed(record), messages)
    # Questions wait in `pending` so a burst is answered a couple per tick. Turning chat off drops what was waiting.
    if state == 'in_call' and chat_enabled(app, record) and not record.get('cancel'):
        pending = record.get('pending', []) + [q for m in fresh if (q := addressed(app, m, record))] + [
            q for m in spoken if (q := spoken_question(m))]
        take = pending[:min(REPLIES_PER_TICK, max(0, MAX_REPLIES - record['replies']))]
        record['pending'] = pending[len(take):] if record['replies'] + len(take) < MAX_REPLIES else []
        record['replies'] += len(take)
        chats.extend((record['bot_id'], question) for question in take)
    else:
        record['pending'] = []
    if state in ('ended', 'failed'):
        conclude(app, record, state)


def board_messages(record, fresh):
    """The new chat messages and spoken commands that ask Hermes for something on the whiteboard. Anyone in the call
    may: the board shows only what people say or type in the call, never the owner's notes."""
    said = {m['text'] for m in record['said']}
    found = []
    for message in fresh:
        text = str(message.get('text') or '')
        has_board = bool(record.get('boards') or found)
        if text not in said and ADDRESSED.search(text) and meeting_board.intent(text, has_board):
            found.append(message)
    return found


def drive_brain(app, record):
    """Start the call's whiteboard process if it is not running (it stops by itself when the call ends)."""
    if not record.get('board_token') or brain_running(app, record['bot_id']):
        return
    last = record.get('brain_started_at')
    if last and app.now() - dt(last) < BRAIN_RESTART:
        return
    record['brain_started_at'] = app.now().isoformat()
    app.spawn_brain(record['bot_id'])


def brain_running(app, bot_id):
    with try_lock(app.store.root / 'locks' / f'brain-{safe_key(bot_id)}.lock') as got:
        return not got


def lost(app, record, error):
    """The bot is gone in the middle of the call. The audio copied here as the call went is filed like a call that
    stopped early; with too little of it, the call failed."""
    have = audio_here(app, record['bot_id'])
    admitted = any(c.get('state') == 'in_call' for c in record['changes'])
    if admitted and have >= MIN_AUDIO_BYTES:
        record.update(audio_bytes=have, error='bot_lost')
        conclude(app, record, 'failed')
    else:
        record.update(phase='failed', error=error)
        shutil.rmtree(app.store.root / 'audio' / safe_key(record['bot_id']), ignore_errors=True)
        log_voice(app, record)


def audio_here(app, bot_id):
    ogg = app.store.root / 'audio' / safe_key(bot_id) / 'call.ogg'
    return ogg.stat().st_size if ogg.exists() else 0


def pull_audio(app, bot_id, running=False):
    """Copy the call's audio recorded since the last copy from the bot to here: on each pass while the call runs, so a
    bot lost in the middle loses at most its last few seconds, and the rest once it is over. `running`: only while the
    call is still under way, so a copy taken after filing cannot leave the audio behind."""
    with locked(app.store.root / 'locks' / f'audio-{safe_key(bot_id)}.lock'):
        if running and (app.store.bot(bot_id) or {}).get('phase') != 'in_call':
            return
        have = audio_here(app, bot_id)
        # A short wait while the call runs, so a slow answer does not hold up the chat passes; the next pass tries again.
        app.service.append(f'/bots/{bot_id}/audio?from={have}', app.store.audio_dir(bot_id) / 'call.ogg', have,
                           30 if running else 300)


def pull_running_audio(app, bot_ids):
    """This pass's copy for each call under way. One that fails waits for the next pass; filing fetches the rest."""
    for bot_id in bot_ids:
        try:
            pull_audio(app, bot_id, running=True)
        except ServiceError:
            pass


# A room nobody closed empties itself this long after the call's bot started (the Worker's links expire then too).
ROOM_LIFETIME = timedelta(hours=12)


def close_room(app, record):
    """The call is over: the room's final boards are kept here (final_boards), then its board link stops working and the
    room forgets them. A room that cannot be read stays open, and each tick tries again until it has emptied itself."""
    if not record.get('board_token') or record.get('room_closed'):
        return
    room = app.service.room(record['board_token'])
    try:
        keep_final_boards(app, record['bot_id'], room.state())
        room.close()
        record['room_closed'] = True
    except board_brain.RoomError:
        if app.now() >= dt(record['created_at']) + ROOM_LIFETIME:
            record['room_closed'] = 'emptied'


def final_path(app, bot_id):
    return app.store.root / 'boards' / safe_key(bot_id) / 'final.json'


def keep_final_boards(app, bot_id, state):
    """The room's boards as the call left them, with the room's change count (`seq`) as their revision: what filing
    checks the kept pictures against. A room with no boards, or one already emptied, leaves what is kept here as it is."""
    boards = state.get('boards') if isinstance(state, dict) else None
    if not isinstance(boards, list) or not boards:
        return
    path = final_path(app, bot_id)
    private_dir(path.parent)
    atomic_write(path, {'seq': state.get('seq'), 'current': state.get('current'), 'boards': boards,
                        'kept_at': app.now().isoformat()})


def final_boards(app, record):
    """The call's final boards: those kept as its room closed, else read from the room now (a room the tick could not
    read yet). None when neither works."""
    kept = read_json(final_path(app, record['bot_id']), None)
    if isinstance(kept, dict) and isinstance(kept.get('boards'), list):
        return kept
    if record.get('board_token') and not record.get('room_closed'):
        try:
            keep_final_boards(app, record['bot_id'], app.service.room(record['board_token']).state())
        except board_brain.RoomError:
            return None
        kept = read_json(final_path(app, record['bot_id']), None)
        return kept if isinstance(kept, dict) and isinstance(kept.get('boards'), list) else None
    return None


def check_boards(app, bot_id):
    """Each board kept here against its final version, before filing. A board whose last picture shows an older version
    keeps that picture but goes to the notes with its final text (`final`); one with no picture is not in the notes, and
    its final version stays in final.json. Either is told once, as is a call whose final boards could not be read. A
    retried filing checks again, since the bot's last pictures may have replaced the entries."""
    with app.store.lock():
        record = app.store.bot(bot_id)
        if not record.get('board_token'):
            return record
    final = final_boards(app, record)
    with app.store.lock():
        record = app.store.bot(bot_id)
        if final is None:
            # Told only for a call that had a board: one kept here, a board command, a board change the owner texted,
            # or a board whose picture could not be kept. (Questions move `room_seq` too, so it is no sign of a board.)
            record['boards_unchecked'] = bool(record.get('boards') or record.get('board_commands')
                                              or int(record.get('room_written') or 0) or record.get('board_failed'))
        else:
            entries = {b['n']: b for b in record.get('boards') or []}
            older, missing = [], []
            for n, board in enumerate(final['boards'], 1):
                entry = entries.get(n)
                picture, source = board_files(app, bot_id, n)
                title = str((board or {}).get('title') or 'Whiteboard') if isinstance(board, dict) else 'Whiteboard'
                if not entry or not picture.exists() or not source.exists():
                    missing.append(title)
                elif entry.get('board') != board:
                    entry['final'] = board
                    older.append(entry.get('title') or title)
            record.update(boards_older=older, boards_missing=missing, boards_seq=final.get('seq'), boards_unchecked=False,
                          boards_final=str(final_path(app, bot_id)))
        app.store.put(record)
        return record


def conclude(app, record, state):
    """The call is over: file what the bot heard, or give up when it heard nothing."""
    admitted = any(c.get('state') == 'in_call' for c in record['changes'])
    log_voice(app, record)
    record['ended_at'] = app.now().isoformat()
    record['presenting'] = False
    close_room(app, record)
    if record.get('boards'):
        record['boards_dir'] = str(app.store.root / 'boards' / record['bot_id'])
    if not admitted or record['audio_bytes'] < MIN_AUDIO_BYTES:
        record['phase'] = 'failed'
        # Too little audio to file; what was copied here during the call goes too.
        shutil.rmtree(app.store.root / 'audio' / safe_key(record['bot_id']), ignore_errors=True)
        # A bot that never got its notice into the chat never recorded.
        untold = (record.get('notice') or {}).get('state') not in (None, 'posted')
        record['error'] = record['error'] if state == 'failed' and record['error'] else (
            'it never got into the call' if not admitted else 'notice_failed' if untold else 'it recorded no audio')
        try:
            delete_bot(app, record)
        except ServiceError:
            pass
        return
    record['phase'] = 'ended'
    record['call_error'] = record['error'] if state == 'failed' else None


# The bot's share error when the host lets only the host share (bot/container/zoom-ui.mjs HOST_ONLY).
SHARE_HOST_ONLY = 'the host lets only the host share'


def share_failed(record):
    """What the owner is told, once, when the bot drew a board but could not show it. A host who lets only the host
    share is told apart, with what the host changes (Zoom's app and its browser version put it in different places;
    the browser's was checked in a test call on 2026-11-22), since nobody in the call can tell why the board is missing."""
    if record['board_error'] == SHARE_HOST_ONLY:
        return (f"The notetaker drew a whiteboard in {label(record)} but could not show it: the host lets only the host "
                "share. The host clicks the arrow next to Share, then in the Zoom app Advanced sharing options and "
                "Who can share? All participants, or in a browser Host tools for share and turn on Share screen. The "
                "notetaker tries again by itself every 30 seconds for 10 minutes.")
    return f"The notetaker drew a whiteboard in {label(record)} but could not show it: {record['board_error']}."


def its_boards(record):
    """'its whiteboard is' or 'its 2 whiteboards are', for the call's boards."""
    count = len(record.get('boards') or [])
    return 'its whiteboard is' if count == 1 else f'its {count} whiteboards are'


def announce(record, messages):
    if record['phase'] == 'failed':
        boards = (f" {its_boards(record).capitalize()} kept in {record['boards_dir']}."
                  if record.get('boards') and record.get('boards_dir') else '')
        tell(record, 'failed', f"The notetaker could not record {label(record)}: {reason(record['error'])}.{boards}", messages)
    elif record['phase'] == 'ended' and record.get('call_error'):
        tell(record, 'stopped', f"The notetaker stopped early in {label(record)}: {reason(record['call_error'])}. "
                                'Filing what it heard.', messages)
    elif record['phase'] == 'filed':
        name, count = label(record), len(record.get('boards') or [])
        boards = its_boards(record).rsplit(' ', 1)[0]
        text = {'filed': f'Notes for {name} are being filed' + (f', with {boards}.' if count else '.'),
                'mac': f'Hereby already recorded {name}, so Hermes made no second note. It kept the meeting chat'
                       + (f' and added {boards} to that recording.' if count else '.'),
                'silent': f'Nobody spoke in {name}, so there are no notes to file.'
                          + (f" {its_boards(record).capitalize()} kept in {record.get('boards_dir')}." if count else '')
                }.get(record.get('outcome'))
        if text:
            tell(record, 'filed', text, messages)
        if record.get('outcome') in ('filed', 'mac'):
            tell_board_check(record, messages)


def quoted(titles):
    names = [f'"{t}"' for t in titles]
    return names[0] if len(names) == 1 else ', '.join(names[:-1]) + ' and ' + names[-1]


def tell_board_check(record, messages):
    """What filing found when it checked the kept whiteboards against the room's final boards (check_boards)."""
    name, older, missing = label(record), record.get('boards_older') or [], record.get('boards_missing') or []
    if older:
        one = len(older) == 1
        tell(record, 'boards_older', f"The picture{'' if one else 's'} of whiteboard{'' if one else 's'} {quoted(older)} in "
                                     f"{name} show{'s it' if one else ' them'} before {'its' if one else 'their'} last "
                                     f"change. The notes have {'its' if one else 'their'} final text.", messages)
    if missing:
        one = len(missing) == 1
        tell(record, 'boards_missing', f"Whiteboard{'' if one else 's'} {quoted(missing)} in {name} "
                                       f"{'has' if one else 'have'} no picture, so {'it is' if one else 'they are'} not in "
                                       f"the notes. The final version is kept in {record.get('boards_final')}.", messages)
    if record.get('boards_unchecked'):
        tell(record, 'boards_unchecked', f'Hermes could not read the final whiteboards of {name}, so a change made in the '
                                         "call's last seconds may be missing from the notes.", messages)


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
        elif not can_join(event.get('meeting_url')):
            del optins[key]
            messages.append(f'{title} no longer has a Google Meet or Zoom link, so the notetaker will not join.')
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


def retention(app):
    """How long a finished call is kept: the recorder's retention_days, the same as its notes' session files. A settings
    file that cannot be read keeps the default rather than stopping the tick."""
    import lml_settings
    try:
        days = lml_settings.load().retention_days
    except lml_settings.SettingsError:
        days = lml_settings.Settings().retention_days
    return timedelta(days=days)


def forget_call(app, record):
    """Removes every copy of one finished call: its board room is emptied and its container stopped, then its record,
    chat log, audio (with the copies made during the call), whiteboards and final boards, logs, voice-usage line and
    calendar opt-in go.
    Returns False, keeping the record so the next tick tries again, when the service cannot be reached."""
    bot_id = record['bot_id']
    if record.get('board_token') and not record.get('room_closed'):
        try:
            app.service.room(record['board_token']).close()
        except board_brain.RoomError:
            # A room past its lifetime has emptied itself (its own alarm).
            if app.now() < dt(record['created_at']) + ROOM_LIFETIME:
                return False
    try:
        delete_bot(app, record)
    except ServiceError:
        return False
    root, key = app.store.root, safe_key(bot_id)
    for path in (root / 'chat-logs' / f'{key}.jsonl', call_log(app, bot_id, 'brain'), call_log(app, bot_id, 'filing'),
                 *(root / 'locks' / f'{kind}-{key}.lock' for kind in ('chat', 'brain', 'audio', 'filing', 'board'))):
        path.unlink(missing_ok=True)
    for folder in ('audio', 'boards'):
        shutil.rmtree(root / folder / key, ignore_errors=True)
    keep_voice_usage(app, lambda line: line.get('bot_id') != bot_id)
    # A calendar call's opt-in keeps the event (title, link) with the bot it started; with the bot forgotten, it goes too,
    # and no bot is started for it again.
    optins = app.store.optins()
    kept = {key: entry for key, entry in optins.items() if entry.get('bot_id') != bot_id}
    if len(kept) < len(optins):
        app.store.put_optins(kept)
    (root / 'bots' / f'{key}.json').unlink(missing_ok=True)
    return True


def keep_voice_usage(app, keep):
    path = app.store.root / 'voice-usage.jsonl'
    lines = read_jsonl(path)
    kept = [line for line in lines if keep(line)]
    if len(kept) < len(lines):
        atomic_write(path, ''.join(json.dumps(line, ensure_ascii=False) + '\n' for line in kept))


def forget_forgotten(app):
    """Calls whose notes were forgotten (live-meeting-forget, or the recorder's own retention) are forgotten here too.
    The recorder keeps each forgotten session's id for its retention_days, so a call still filing then goes once filed.
    A call that Hereby's own recording covered is named by that recording's session."""
    gone = {item['sid'] for item in read_jsonl(root_path() / 'forgotten.jsonl') if item.get('sid')}
    for record in app.store.bots():
        if record['phase'] in TERMINAL and record.get('sid') in gone and not forget_call(app, record):
            return


def prune(app):
    """Finished calls older than the retention, with every copy of them; voice-usage lines and the logs from before
    each call had its own, by the same age. Stops at the first call the service cannot be reached for."""
    cutoff = app.now() - retention(app)
    for record in app.store.bots():
        if record['phase'] in TERMINAL and dt(record['created_at']) < cutoff and not forget_call(app, record):
            break
    keep_voice_usage(app, lambda line: not line.get('ended_at') or dt(line['ended_at']) >= cutoff)
    for name in ('brain.log', 'filing.log'):
        path = app.store.root / name
        if path.exists() and path.stat().st_mtime < cutoff.timestamp():
            path.unlink(missing_ok=True)


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
    """Hermes's once-a-minute job: hands on what the follower left for the owner, and starts the follower unless it is
    still running. It returns at once, whatever the calls are doing. Hermes counts an 'every 1m' job's next run from when
    its last run finished and looks for due jobs once a minute, and a cron-expression job is due at the next minute after
    the last run finished: either way a run that takes more than a few seconds misses the next look, and a tick that
    watched the calls for 45 seconds ran only every 2 minutes (a rehearsal on 2026-11-21: the board 72 seconds after the
    bot was let in). The follower does the slow work."""
    text = take_outbox(app)
    if not follower_running(app):
        app.spawn_follower()
    return text


def cmd_follow(app, args):
    """The follower (started by the tick): a full check, then, while a call needs watching, a look every few seconds and
    a full check every minute, until nothing is joining, in a call, or about to start. What the owner should be told
    goes in the outbox, which the next tick hands on (the tick's output is what Hermes texts the owner)."""
    with try_lock(follow_lock(app)) as got:
        if not got:
            return ''
        checked = None
        while True:
            if checked is None or app.clock() - checked >= CHECK_EVERY_S:
                checked = app.clock()
                post(app, check(app))
            else:
                post(app, look(app))
            wait = watching(app)
            if wait is None:
                return ''
            app.sleep(wait)


def follow_lock(app):
    return app.store.root / 'tick.lock'


def follower_running(app):
    with try_lock(follow_lock(app)) as got:
        return not got


def check(app):
    """One full pass over the opt-ins and calls. Returns what the owner should be told, as one text ('' for nothing)."""
    messages, problems, chats = [], [], []
    with app.store.lock():
        state = app.store.tick_state()
        reconcile(app, state, messages, problems)
        for record in app.store.bots():
            if record['phase'] not in TERMINAL:
                advance(app, record, messages, problems, chats)
            else:
                announce_once(app, record, messages)
            if record['phase'] not in ACTIVE and record.get('board_token') and not record.get('room_closed'):
                # A room that could not be read when its call ended: its final boards are kept, then it is closed.
                close_room(app, record)
                app.store.put(record)
        forget_forgotten(app)
        prune(app)
        problem = '; '.join(problems) or None
        if problem and problem != state.get('last_error'):
            messages.append(f'The meeting notetaker check hit a problem: {problem}')
        state['last_error'] = problem
        app.store.put_tick_state(state)
        recording = [r['bot_id'] for r in app.store.bots() if r['phase'] == 'in_call']
    pull_running_audio(app, recording)
    messages.extend(answer_chats(app, chats))
    return '\n'.join(messages)


def look(app):
    """A quick look between full checks: a calendar call's bot that is due now, a bot let in or gone, a call taken off
    the panel, the chat questions. Problems wait for the next full check, which reports them once."""
    messages, chats = [], []
    with app.store.lock():
        start_due(app)
        for record in app.store.bots():
            if record['phase'] in ACTIVE:
                advance(app, record, messages, [], chats)
        recording = [r['bot_id'] for r in app.store.bots() if r['phase'] == 'in_call']
    pull_running_audio(app, recording)
    return '\n'.join(messages + answer_chats(app, chats))


def start_due(app):
    """Start the bot of each calendar call that is due and has not been tried yet, on the second. One that failed is
    tried again by the full check each minute, which also tells the owner."""
    optins = app.store.optins()
    for key, entry in list(optins.items()):
        if not entry.get('bot_id') and not entry.get('failures'):
            ensure_bot(app, optins, key)


def watching(app):
    """Seconds until the follower looks again, or None when nothing needs it: a bot joining or waiting to be let in is
    looked at every LOOK_JOINING_S, so its whiteboard starts within seconds of it being let in; a call under way every
    LOOK_S, for its chat, its audio and a removal from the panel; a calendar call whose bot is due within WAKE_AHEAD,
    so the bot is sent on time rather than at the next minute's tick."""
    phases = {r['phase'] for r in app.store.bots()}
    now = app.now()
    soon = any(not entry.get('bot_id') and dt(entry['end']) > now and dt(entry['start']) - LEAD - now <= WAKE_AHEAD
               for entry in app.store.optins().values() if isinstance(entry, dict))
    if soon or phases & {'joining', 'waiting_room'}:
        return LOOK_JOINING_S
    return LOOK_S if 'in_call' in phases else None


def outbox_path(app):
    return app.store.root / 'outbox.jsonl'


def post(app, text):
    """Keep `text` for the owner until the next tick hands it on."""
    if not text:
        return
    with locked(app.store.root / 'locks' / 'outbox.lock'):
        fd = os.open(outbox_path(app), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps({'at': app.now().isoformat(), 'text': text}, ensure_ascii=False) + '\n').encode())
        finally:
            os.close(fd)


def take_outbox(app):
    """What the follower kept for the owner since the last tick, oldest first, as one text; the outbox is emptied."""
    with locked(app.store.root / 'locks' / 'outbox.lock'):
        lines = read_jsonl(outbox_path(app))
        outbox_path(app).unlink(missing_ok=True)
    return '\n'.join(str(line['text']) for line in lines if isinstance(line, dict) and line.get('text'))


# The whiteboard. The call's board room on the bot service holds its boards; the whiteboard process (board_brain.py) and
# the owner's texts change them there, and each finished change's picture and Excalidraw file come back here at once, so
# a bot that dies mid-call still leaves every board for the notes.

def board_files(app, bot_id, n):
    folder = app.store.root / 'boards' / safe_key(bot_id)
    return folder / f'board-{n}.png', folder / f'board-{n}.excalidraw'


def keep_board(app, bot_id, n):
    """Ask the bot for board n's picture and Excalidraw file, and keep them; the record's list of boards follows."""
    return keep_drawn(app, bot_id, n, app.service.call('GET', f'/bots/{bot_id}/board/export?n={int(n)}'))


def keep_last_boards(app, bot_id):
    """The boards the bot drew once more as it left the call: those changed since it last drew them, such as a change
    made from the board link in the call's last seconds. A bot already gone has none left to give; one that does not
    answer is asked twice more before filing goes on without them (the container is deleted after this)."""
    for attempt in range(3):
        try:
            shown = app.service.call('GET', f'/bots/{bot_id}/board/final')
            break
        except ServiceError as exc:
            if exc.status == 404 or attempt == 2:
                return 0
            app.sleep(2)
    kept = 0
    for one in (shown.get('boards') if isinstance(shown, dict) else None) or []:
        try:
            keep_drawn(app, bot_id, int(one['n']), one)
            kept += 1
        except (ServiceError, KeyError, TypeError, ValueError):
            pass
    return kept


def keep_drawn(app, bot_id, n, shown):
    if not isinstance(shown, dict) or not shown.get('png') or not shown.get('scene') or not isinstance(shown.get('board'), dict):
        raise ServiceError(0, 'the bot drew no board')
    picture, source = board_files(app, bot_id, n)
    private_dir(picture.parent)
    try:
        atomic_write(picture, base64.b64decode(shown['png'], validate=True))
    except ValueError:
        raise ServiceError(0, 'the board picture was not readable') from None
    atomic_write(source, shown['scene'] if isinstance(shown['scene'], str) else json.dumps(shown['scene']))
    title = str(shown['board'].get('title') or 'Whiteboard')
    with app.store.lock():
        record = app.store.bot(bot_id)
        entry = {'n': n, 'title': title, 'board': shown['board'], 'updated_at': app.now().isoformat()}
        record['boards'] = sorted([b for b in record.get('boards') or [] if b.get('n') != n] + [entry], key=lambda b: b['n'])
        record['board'] = n
        app.store.put(record)
    return {'picture': str(picture), 'title': title}


def say_in_call(app, bot_id, text):
    """A line in the meeting chat from the whiteboard, only while chat replies are on (everyone in the call sees it).
    True when it was said."""
    # The line goes in `said` first, so the bot never takes its own line for a command, and is sent after the store is
    # free again: the board's next step waits on the store, and must not wait on the meeting chat too.
    with app.store.lock():
        record = app.store.bot(bot_id)
        if not (record and record['phase'] == 'in_call' and chat_enabled(app, record)):
            return False
        record['said'].append({'at': z(app.now()), 'text': text})
        app.store.put(record)
    with chat_lock(app, bot_id):
        app.service.call('POST', f'/bots/{bot_id}/chat', {'message': text})
    return True


def board_lock(app, bot_id):
    return locked(app.store.root / 'locks' / f'board-{safe_key(bot_id)}.lock')


def make_brain(app, bot_id):
    with app.store.lock():
        record = app.store.bot(bot_id)
    if not record or not record.get('board_token'):
        raise Usage('That call has no whiteboard.')
    return board_brain.Brain(
        app.store, bot_id, app.service.room(record['board_token']), app.model(app.store.root),
        keep=lambda n: keep_board(app, bot_id, n), say=lambda text: say_in_call(app, bot_id, text),
        lock=lambda: board_lock(app, bot_id), describe=describe, now=app.now, sleep=app.sleep)


def cmd_brain(app, args):
    """The whiteboard process for one call (started by the tick). Runs until the call is over."""
    with try_lock(app.store.root / 'locks' / f'brain-{safe_key(args.bot_id)}.lock') as got:
        if not got:
            return ''
        return make_brain(app, args.bot_id).run()


def cmd_board(app, args):
    """A whiteboard request texted by the owner: carried out at once, the same way as one said in the call."""
    text = ' '.join(args.text.split())
    if not text:
        raise Usage('Say what to put on the whiteboard.')
    with app.store.lock():
        record = pick_record(app, args.event, ('in_call',))
    if not record.get('board_token'):
        raise Usage('This call has no whiteboard. It started before whiteboards were live; the next call will have one.')
    room = app.service.room(record['board_token'])
    try:
        with board_lock(app, record['bot_id']):
            state = room.state()
            try:
                # Each text is its own command, and so its own undo step.
                result = board_brain.run_command(room, app.model(app.store.root), state, text,
                                                 cmd=f'text-{secrets.token_hex(4)}', any_text=True)
            finally:
                # The call's whiteboard process reads this to know its next command's boards are out of date.
                with app.store.lock():
                    current = app.store.bot(record['bot_id'])
                    current['room_written'] = max(int(current.get('room_written') or 0), room.seq)
                    app.store.put(current)
    except ValueError as exc:
        raise Usage(str(exc)) from None
    except board_brain.RoomError as exc:
        raise Failure(str(exc)) from None
    except Exception as exc:
        raise Failure(f'Hermes could not work out that change to the whiteboard ({describe(exc)}).') from None
    out = {'bot_id': record['bot_id'], 'board': result.get('board'), 'board_url': record.get('board_url')}
    if result['kind'] == 'undo':
        if result['refused']:
            raise Usage(result['refused'][0])
        brain = make_brain(app, record['bot_id'])
        brain.later = lambda work, *args: work(*args)
        brain.after_undo(result['changed'], result['count'])
        return {**out, 'undone': True, 'boards': result['count']}
    if result['kind'] == 'stop':
        with app.store.lock():
            record = app.store.bot(record['bot_id'])
            record['presenting'] = False
            app.store.put(record)
        return {**out, 'presenting': False}
    make_brain(app, record['bot_id']).post_link()
    kept = keep_board(app, record['bot_id'], result['board'])
    after = room.state()
    return {**out, 'title': kept['title'], 'presenting': bool(after.get('presenting')),
            'share_error': after.get('present_error'), 'picture': kept['picture']}


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
    """When the audio file begins: the bot starts recording the moment its notice shows in the call's chat, or, for a bot
    from before the notice, the moment it is in the call."""
    notice = record.get('notice') or {}
    if notice.get('state') == 'posted' and notice.get('at'):
        return dt(notice['at'])
    for change in record['changes']:
        if change.get('state') == 'in_call' and change.get('at'):
            return dt(change['at'])
    return dt(record.get('start') or record['created_at'])


def kept_boards(app, record):
    """The call's whiteboards whose picture and file are both here, in board order."""
    found = []
    for entry in record.get('boards') or []:
        picture, source = board_files(app, record['bot_id'], entry['n'])
        if picture.exists() and source.exists():
            found.append((entry, picture, source))
    return found


def send_boards(app, record, sid):
    """Hand the whiteboards to a recorder session: board-<n>.png and .excalidraw, and boards.json naming them with each
    board's text, action items and decisions (meeting_board.board_text), which meeting processing files into the
    meeting's notes."""
    listed = []
    for entry, picture, source in kept_boards(app, record):
        run_step([*app.receive, sid, picture.name, '0'], picture.read_bytes())
        run_step([*app.receive, sid, source.name, '0'], source.read_bytes())
        listed.append({'n': entry['n'], 'title': entry['title'], 'picture': picture.name, 'source': source.name,
                       **meeting_board.board_text(entry.get('final') or entry.get('board'))})
    if listed:
        run_step([*app.receive, sid, 'boards.json', '0'], json.dumps({'boards': listed}, ensure_ascii=False).encode())
    return len(listed)


def file_call(app, record):
    """Do every step for one finished call. Returns ('filed' | 'mac' | 'silent', sid). Each step can be rerun."""
    bot_id = record['bot_id']
    keep_last_boards(app, bot_id)
    record = check_boards(app, bot_id) or record
    save_chat_log(app, record)
    mac = mac_recorded(app, record.get('event_key'), record.get('sid'))
    if mac:
        # Hereby's own recording becomes the notes, so the whiteboards go with it. A recording forgotten meanwhile
        # refuses them, and they stay here.
        try:
            send_boards(app, record, mac)
        except Failure:
            pass
        delete_bot(app, record)
        # The audio copied here during the call is not needed.
        shutil.rmtree(app.store.root / 'audio' / safe_key(bot_id), ignore_errors=True)
        # The call's notes are Hereby's recording: forgetting that session forgets what was kept here.
        return 'mac', mac
    work = app.store.audio_dir(bot_id)
    ogg, wav = work / 'call.ogg', work / 'call.wav'
    if not wav.exists():
        try:
            pull_audio(app, bot_id)
        except WholeAudioOnly:
            app.service.download(f'/bots/{bot_id}/audio', ogg)
        except ServiceError as exc:
            # A bot that is gone leaves the audio copied here during the call.
            if not (exc.status == 404 and audio_here(app, bot_id) >= MIN_AUDIO_BYTES):
                raise
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
    # Before meta.json, which ends the session: meeting processing may list it from then on.
    send_boards(app, record, sid)
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


def cmd_board_link(app, args):
    """The call's board link, asked for by the owner: `off` stops it and cuts off everyone on it, `new` does that and
    makes a new one, and `view` makes a watch-only one. A new link is never posted in the meeting chat by this; Hermes
    gives it to the owner. The shared screen keeps showing the board either way."""
    with app.store.lock():
        record = pick_record(app, args.event, ACTIVE)
    if not record.get('board_token'):
        raise Usage('This call has no whiteboard. It started before whiteboards were live; the next call will have one.')
    try:
        answer = app.service.call('POST', f"/rooms/{record['board_token']}/link", {'mode': args.mode})
    except ServiceError as exc:
        if exc.status == 409:
            raise Usage('That call is over, so its board link already stopped working.') from None
        raise
    out = {'bot_id': record['bot_id']}
    if args.mode == 'view':
        return {**out, 'view_url': answer['view_url']}
    with app.store.lock():
        current = app.store.bot(record['bot_id'])
        current['board_url'] = answer.get('board_url')
        # The chat gets a link once, with the first board, and never one the owner turned off or made again: from now
        # on the owner hands the link out.
        current['board_link_posted'] = True
        app.store.put(current)
    return {**out, 'board_url': current['board_url']}


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def parser():
    top = Parser(prog='meeting-bot', description="Send Hermes's notetaker into Google Meet and Zoom calls.")
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
    board = commands.add_parser('board')
    board.add_argument('text')
    board.add_argument('--event')
    board_link = commands.add_parser('board-link')
    board_link.add_argument('mode', choices=('off', 'new', 'view'))
    board_link.add_argument('--event')
    commands.add_parser('brain').add_argument('bot_id')
    leave = commands.add_parser('leave')
    leave.add_argument('--event')
    commands.add_parser('status')
    commands.add_parser('tick')
    commands.add_parser('follow')
    commands.add_parser('file').add_argument('bot_id')
    return top


HANDLERS = {'optin': cmd_optin, 'optout': cmd_optout, 'chat': cmd_chat, 'join': cmd_join, 'say': cmd_say, 'board': cmd_board,
            'board-link': cmd_board_link, 'brain': cmd_brain, 'leave': cmd_leave, 'status': cmd_status, 'tick': cmd_tick, 'follow': cmd_follow,
            'file': cmd_file}


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
