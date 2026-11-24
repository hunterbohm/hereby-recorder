"""The meeting bot against a fake bot service (a loopback HTTP server) and a fake calendar. No real service or calendar."""
import base64
import io
import json
import os
import re
import stat
import sys
import threading
import uuid
from datetime import timedelta
from types import SimpleNamespace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

import meeting_bot
from lml_common import atomic_write, dt, read_json, read_jsonl, root_path
from lml_hermes import forget
from meeting_bot import App, Failure, Service, ServiceError, Store, Usage

MINI = Path(__file__).resolve().parents[1]
KEY = 'test-key-not-real'
MEET = 'https://meet.google.com/abc-defg-hij'
ZOOM = 'https://acme.zoom.us/j/84262542688?pwd=abc.1'
START = dt('2026-10-13T10:00:00-05:00')
END = dt('2026-10-13T11:00:00-05:00')
KEYED = 'cal-event-1'
SID = '20261013-100000-abcd'


class FakeService:
    """The bot service's API over loopback: bots, their state changes, chat, audio and delete."""

    def __init__(self):
        self.bots, self.calls, self.audio_gets = {}, [], 0
        self.fail_create = 0
        # A bot from before the copies during the call: GET /audio ignores `from` and sends the whole file.
        self.whole_audio_only = False
        # GET /audio sends its answer in chunks, as the Worker streams it, but hangs up this many bytes before the end.
        self.cut_audio = 0
        # Called as each chat line is posted, to look around while it is in flight.
        self.on_chat = None
        # The calls' board rooms, by token (FakeRoom in test_meeting_board.py fills them in).
        self.rooms = {}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, value=None, raw=None, headers=(), short=0):
                body = raw if raw is not None else json.dumps(value).encode()
                self.send_response(status)
                for name, header in headers:
                    self.send_header(name, header)
                if short:
                    # One chunk with all but the last `short` bytes, and no end: the connection just closes.
                    self.send_header('Transfer-Encoding', 'chunked')
                    self.end_headers()
                    part = body[:len(body) - short]
                    self.wfile.write(f'{len(part):x}\r\n'.encode() + part + b'\r\n')
                    return
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def handle_any(self):
                raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
                if self.headers.get('Authorization') != 'Bearer ' + KEY:
                    return self.reply(401, {'error': 'unauthorized'})
                body = json.loads(raw) if raw else None
                owner.calls.append((self.command, self.path, body))
                owner.route(self, self.command, self.path, body)

            do_GET = do_POST = do_DELETE = handle_any

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.base = f'http://127.0.0.1:{self.server.server_port}'
        # A short poll so shutdown() at the end of each test returns at once instead of after the default 0.5 s.
        threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True).start()

    def route(self, handler, method, path, body):
        if (method, path) == ('POST', '/bots'):
            if self.fail_create:
                self.fail_create -= 1
                return handler.reply(502, {'error': 'bot did not start: 500'})
            if not re.match(r'^https://(meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}|([a-z0-9-]+\.)*zoom\.us/[jw]/\d{9,12})',
                            body.get('meeting_url') or ''):
                return handler.reply(400, {'error': 'meeting_url must be a Google Meet or Zoom link'})
            bot_id = str(uuid.uuid4())
            token = uuid.uuid4().hex
            self.bots[bot_id] = {'state': 'joining', 'error': None, 'changes': [self.change('joining')], 'audio_bytes': 0,
                                 'chat': [], 'created_with': body, 'audio': b'', 'left': False, 'posted': [],
                                 'heard': [], 'voice': None, 'token': token}
            # `can_present`: whether the bot gets to share the board it is told to (the host may not let it).
            self.rooms[token] = {'boards': [], 'current': None, 'last': None, 'view': {'mode': 'one'}, 'seq': 0, 'presenting': False,
                                 'present_error': None, 'msgs': [], 'history': [], 'closed': False, 'events': [], 'bot_id': bot_id,
                                 'can_present': True}
            return handler.reply(201, {'id': bot_id, 'board_token': token, 'board_url': f'https://bots.test/b/{token}'})
        room = re.fullmatch(r'/rooms/([0-9a-f]{32})/(send|state|close|events|link)(\?.*)?', path)
        if room:
            if room.group(1) not in self.rooms:
                return handler.reply(404, {'error': 'not found'})
            return self.room_route(handler, self.rooms[room.group(1)], room.group(2), body)
        match = re.fullmatch(r'/bots/([0-9a-f-]{36})(/status|/chat|/leave|/audio|/board/export|/board/final)?(?:\?n=(\d+)|\?from=(\d+))?', path)
        bot = self.bots.get(match.group(1)) if match else None
        if bot is None:
            return handler.reply(404, {'error': 'not found'})
        action = match.group(2)
        if method == 'DELETE' and action is None:
            del self.bots[match.group(1)]
            return handler.reply(200, {'ok': True})
        if (method, action) == ('GET', '/status'):
            return handler.reply(200, {'state': bot['state'], 'error': bot['error'], 'changes': bot['changes'],
                                       'audio_bytes': bot['audio_bytes'], 'chat': bot['chat'], 'heard': bot['heard'],
                                       **({'voice': bot['voice']} if bot['voice'] else {}),
                                       **({'near_misses': bot['near_misses']} if bot.get('near_misses') else {}),
                                       **{k: bot[k] for k in ('recording', 'recording_error', 'recording_stopped_at') if k in bot},
                                       **({'notice': bot['notice']} if bot.get('notice') else {})})
        if (method, action) == ('POST', '/chat'):
            if self.on_chat:
                self.on_chat()
            bot['posted'].append(body['message'])
            return handler.reply(200, {'ok': True})
        if (method, action) == ('POST', '/leave'):
            bot['left'] = True
            return handler.reply(200, {'ok': True})
        if (method, action) == ('GET', '/board/export'):
            board = self.rooms[bot['token']]['boards'][int(match.group(3)) - 1]
            return handler.reply(200, {'png': base64.b64encode(b'PNG ' + board['title'].encode()).decode(),
                                       'scene': json.dumps({'type': 'excalidraw', 'title': board['title']}), 'board': board})
        if (method, action) == ('GET', '/board/final'):
            # What the bot drew as it left: the boards changed since it last drew them (set by a test), after
            # `final_fail` failed answers.
            if bot.get('final_fail'):
                bot['final_fail'] -= 1
                return handler.reply(503, {'error': 'the container is starting'})
            return handler.reply(200, {'boards': bot.get('final', [])})
        if (method, action) == ('GET', '/audio'):
            # As the bot: from byte `from` on, saying where the answer starts.
            self.audio_gets += 1
            if self.whole_audio_only:
                return handler.reply(200, raw=bot['audio'])
            start = min(len(bot['audio']), int(match.group(4) or 0))
            return handler.reply(200, raw=bot['audio'][start:], headers=[('x-audio-from', str(start))],
                                 short=self.cut_audio)
        return handler.reply(404, {'error': 'not found'})

    def room_route(self, handler, room, action, body):
        """A call's board room, roughly as the Worker's BoardRoom: it applies edits and keeps what it was sent."""
        if action == 'link':
            # The Worker's board link: off or new moves the room's link version on; links carry the version they are for.
            if room['closed']:
                return handler.reply(409, {'error': 'the call is over'})
            if body['mode'] != 'view':
                room['link'] = room.get('link', 1) + 1
            version = room.get('link', 1)
            return handler.reply(200, {'ok': True, **{'off': {'board_url': None},
                                                      'new': {'board_url': f'https://bots.test/b/#edit-{version}'},
                                                      'view': {'view_url': f'https://bots.test/b/#watch-{version}'}}[body['mode']]})
        if action == 'close':
            room['closed'] = True
            return handler.reply(200, {'ok': True})
        if action == 'state':
            # `state_fail`: how many reads fail before one works (the room is busy or out of reach).
            if room.get('state_fail'):
                room['state_fail'] -= 1
                return handler.reply(503, {'error': 'the room is busy'})
            return handler.reply(200, {k: room[k] for k in ('boards', 'current', 'last', 'seq', 'presenting', 'present_error')})
        if action == 'send':
            results = [self.room_message(room, msg) for msg in body['msgs']]
            return handler.reply(200, {'results': results, 'seq': room['seq'], 'current': room['current']})
        if action == 'events':
            lines = [{'t': 'hello', **{k: room[k] for k in ('boards', 'current', 'last', 'seq', 'presenting')}}] + room['events']
            raw = ''.join(f'data: {json.dumps(e)}\n\n' for e in lines).encode()
            return handler.reply(200, raw=raw)
        return handler.reply(404, {'error': 'not found'})

    def room_message(self, room, msg):
        room['msgs'].append(msg)
        kind = msg.get('t')
        if kind == 'caption':
            # As the Worker's room: a command Hermes finished is marked, for a Hermes that restarts.
            if msg.get('cmd') and msg.get('state') in ('done', 'failed'):
                for event in room['events']:
                    if event.get('id') == msg['cmd']:
                        event['finished'] = True
            return {'ok': True}
        if kind == 'undo':
            if not room['history']:
                return {'ok': False, 'error': 'there is nothing to undo'}
            _, boards, room['current'], room['last'], room['view'] = room['history'].pop()
            changed = [n for n in range(1, len(boards) + 1) if boards[n - 1] != (room['boards'][n - 1:n] or [None])[0]]
            room['boards'] = boards
            room['seq'] += 1
            return {'ok': True, 'what': 'Undone: the last change', 'changed': changed, 'boards': len(boards),
                    'current': room['current']}
        # One undo step per command, as the Worker's room keeps them.
        if not room['history'] or room['history'][-1][0] != msg.get('cmd'):
            room['history'].append((msg.get('cmd'), json.loads(json.dumps(room['boards'])), room['current'], room['last'],
                                    room['view']))
        if kind == 'recap':
            actions = [i for b in room['boards'] for blk in b['blocks'] if blk.get('kind') == 'actions' for i in blk['items']]
            if not actions:
                return {'ok': False, 'error': 'there is nothing to recap yet: no action items, decisions or risks'}
            room['boards'].append({'v': 2, 'title': 'Recap', 'recap': True, 'blocks': [
                {'id': 'actions', 'type': 'list', 'title': 'Action items', 'kind': 'actions', 'items': actions}]})
            room['current'] = room['last'] = len(room['boards'])
            room['view'] = {'mode': 'one'}
            room['seq'] += 1
            return {'ok': True, 'n': room['current'], 'text': 'Recap. Action items: ' + '; '.join(n['text'] for n in actions) + '.'}
        if kind == 'new':
            # A command makes at most one board: asked again, the room gives the one it made.
            made = room.setdefault('made', {})
            if msg.get('cmd') in made:
                return {'ok': True, 'n': made[msg['cmd']]}
            if len(room['boards']) >= 9:
                return {'ok': False, 'error': 'a call holds at most 9 whiteboards'}
            room['boards'].append(msg.get('board') or {'v': 2, 'title': 'Whiteboard', 'blocks': []})
            room['current'] = room['last'] = len(room['boards'])
            room['view'] = {'mode': 'one'}
            if msg.get('cmd'):
                made[msg['cmd']] = room['current']
            room['seq'] += 1
            self.present(room)
            return {'ok': True, 'n': room['current']}
        if kind == 'set':
            # As the Worker's room: a whole board in place of board n (a board by name, put on an empty one).
            if not 1 <= int(msg.get('n') or 0) <= len(room['boards']):
                return {'ok': False, 'error': f"there is no board {msg.get('n')}"}
            room['boards'][msg['n'] - 1] = msg['board']
            room['seq'] += 1
            return {'ok': True, 'n': msg['n']}
        if kind in ('show', 'stop'):
            if kind == 'show' and not 1 <= int(msg.get('n') or 0) <= len(room['boards']):
                return {'ok': False, 'error': f"there is no board {msg.get('n')}"}
            # As the Worker's room: one board, two side by side (`split`, n one of them), or every board (`all`).
            pair = msg.get('split') or []
            if pair and (len(pair) != 2 or pair[0] == pair[1] or msg['n'] not in pair
                         or not all(1 <= n <= len(room['boards']) for n in pair)):
                return {'ok': False, 'error': 'side by side takes two boards the call has'}
            if msg.get('all') and len(room['boards']) < 2:
                return {'ok': False, 'error': 'there is only one board'}
            room['view'] = {'mode': 'split', 'boards': list(pair)} if pair else {'mode': 'all'} if msg.get('all') else {'mode': 'one'}
            room['current'] = msg.get('n') if kind == 'show' else None
            room['last'] = room['current'] or room['last']
            room['seq'] += 1
            self.present(room)
            return {'ok': True, 'n': room['current'], 'view': room['view']}
        if kind == 'op':
            # As the Worker's room (bot/src/ops.js), for the edits these tests make: a title, a block, an item.
            board, op = room['boards'][msg['n'] - 1], msg['op']
            # Of two boards side by side, the one changed last is the one the next change goes to.
            if room['view']['mode'] == 'split' and msg['n'] in room['view']['boards']:
                room['current'] = room['last'] = msg['n']
            blocks = {blk['id']: blk for blk in board['blocks']}
            items = {i['id']: i for blk in board['blocks'] for i in blk['items']}
            if op['op'] == 'title':
                board['title'] = op['text']
            elif op['op'] == 'block':
                if op['id'] in blocks:
                    blocks[op['id']]['title'] = op.get('title') or blocks[op['id']]['title']
                else:
                    kind = op.get('type') or 'list'
                    board['blocks'].append({'id': op['id'], 'type': kind, 'title': op.get('title') or 'Notes',
                                            **({'kind': op.get('kind') or 'notes'} if kind == 'list' else {}), 'items': []})
                    room['seq'] += 1
                    title = board['blocks'][-1]['title']
                    return {'ok': True, 'changed': [op['id']], 'what': f'Added the {kind} “{title}”', 'block': title}
            elif op['op'] == 'item' and op['id'] in items and not op.get('block'):
                was = items[op['id']]['text']
                items[op['id']].update({k: op[k] for k in ('text', 'owner', 'due') if op.get(k)})
                room['seq'] += 1
                return {'ok': True, 'changed': [op['id']], 'what': f'Changed “{was}”'}
            elif op['op'] == 'item':
                if op.get('block') not in blocks:
                    return {'ok': False, 'error': f"there is no block {op.get('block')}"}
                listed = blocks[op['block']]['items']
                if len(listed) >= 12:
                    return {'ok': False, 'error': 'a block holds at most 12 items'}
                listed.append({'id': op['id'], 'text': op['text'], **{k: op[k] for k in ('owner', 'due') if op.get(k)}})
                room['seq'] += 1
                title = blocks[op['block']]['title']
                return {'ok': True, 'changed': [op['id']], 'what': f'Added “{op["text"]}” to {title}', 'added': title}
            else:
                return {'ok': False, 'error': f"unknown edit {op['op']}"}
            room['seq'] += 1
            return {'ok': True, 'changed': [op.get('id', 'title')], 'what': f"{op['op'].capitalize()} {op.get('id', '')}".strip()}
        return {'ok': False, 'error': 'unknown message'}

    @staticmethod
    def present(room):
        """The bot follows the room: it shares the board on screen, or stops sharing."""
        room['presenting'] = bool(room['current']) and room['can_present']
        room['present_error'] = None if room['can_present'] or not room['current'] else 'the host does not let guests present'

    def room_of(self, bot_id):
        return self.rooms[self.bots[bot_id]['token']]

    def hear(self, bot_id, text, source='voice', sender='', at='2026-10-13T15:10:00.000Z', continues=None):
        """A command as the bot sends it to its board room, with the boards as they are (what Hermes's stream gets)."""
        room = self.room_of(bot_id)
        room['seq'] += 1
        event = {'t': 'command', 'seq': room['seq'], 'id': f'v{room["seq"]}', 'text': text, 'source': source,
                 'sender': sender, 'direct': True, 'at': at, 'boards': json.loads(json.dumps(room['boards'])),
                 'current': room['current'], 'last': room['last'], 'view': room['view']}
        if continues:
            event['continues'] = continues
        room['events'].append(event)
        return event

    @staticmethod
    def change(state, error=None, at='2026-10-13T15:00:00.000Z'):
        return {'state': state, 'error': error, 'at': at}

    def move(self, bot_id, state, error=None, at='2026-10-13T15:00:30.000Z'):
        bot = self.bots[bot_id]
        bot.update(state=state, error=error)
        bot['changes'].append(self.change(state, error, at))

    def join_call(self, bot_id, audio=b'o' * 9000):
        self.move(bot_id, 'in_call', at='2026-10-13T15:00:30.000Z')
        self.bots[bot_id].update(audio=audio, audio_bytes=len(audio))

    def say(self, bot_id, sender, text, mid=None):
        chat = self.bots[bot_id]['chat']
        chat.append({'id': mid or f'm{len(chat) + 1}', 'sender': sender, 'text': text, 'at': '2026-10-13T15:10:00.000Z'})

    def speak(self, bot_id, text, direct=True):
        """A spoken command as the bot reports it: the words after the name, with the name in front."""
        heard = self.bots[bot_id]['heard']
        heard.append({'id': f'v{len(heard) + 1}', 'text': text, 'direct': direct, 'at': '2026-10-13T15:10:00.000Z'})

    def only(self):
        assert len(self.bots) == 1, self.bots
        return next(iter(self.bots))


class Clock:
    def __init__(self, moment):
        self.moment = moment

    def __call__(self):
        return self.moment

    def to(self, moment):
        self.moment = moment


def event(key=KEYED, start=START, end=END, url=MEET, title='Budget review', event_id='evt-1'):
    return {'key': key, 'start': start.isoformat(), 'end': end.isoformat(), 'meeting_url': url, 'title': title,
            'event_id': event_id}


class Calendar:
    """The calendar the tick re-reads. Counts reads so the throttle is visible."""

    def __init__(self, *events):
        self.events, self.reads, self.error = list(events), 0, None

    def __call__(self, minutes):
        self.reads += 1
        if self.error:
            raise Failure(self.error)
        return [dict(e) for e in self.events]


@pytest.fixture
def service():
    fake = FakeService()
    yield fake
    fake.server.shutdown()


@pytest.fixture
def clock():
    return Clock(START - timedelta(minutes=30))


@pytest.fixture
def calendar():
    return Calendar(event())


@pytest.fixture
def spawned():
    return []


@pytest.fixture
def brains():
    """The calls whose whiteboard process the tick started."""
    return []


@pytest.fixture
def answers():
    class Answers:
        def __init__(self):
            self.questions, self.reply, self.before = [], 'The budget is $70,000 (Budget review, Oct 6).', None

        def __call__(self, question):
            self.questions.append(question)
            if self.before:
                self.before()
            return self.reply
    return Answers()


@pytest.fixture
def app(tmp_path, service, clock, calendar, spawned, brains, answers):
    def no_model(root):
        raise AssertionError('the whiteboard model was asked for in a test that has none')
    return App(Store(meeting_bot.default_root()), Service(service.base, lambda: KEY), events=calendar,
               schedule=lambda: [e for e in calendar.events], answer=answers, owner='Dana', spawn=spawned.append,
               spawn_brain=brains.append, model=no_model, now=clock,
               receive=(sys.executable, str(MINI / 'live-meeting-receive')),
               done=(sys.executable, str(MINI / 'live-meeting-done')))


def run(app, *argv):
    out, err = io.StringIO(), io.StringIO()
    code = meeting_bot.main(list(argv), app=app, out=out, err=err)
    return code, out.getvalue(), err.getvalue()


def ok(app, *argv):
    code, out, err = run(app, *argv)
    assert (code, err) == (0, ''), (code, err)
    return json.loads(out)


def tick(app):
    """One full check, as the follower makes it each minute: what the owner is told."""
    return meeting_bot.check(app)


def optin(app, key=KEYED):
    return ok(app, 'optin', key)


def start_call(app, service, clock, *, chat=False):
    """Opt in, let the clock reach the start, tick the bot into existence and into the call."""
    optin(app)
    if chat:
        ok(app, 'chat', KEYED, 'on')
    clock.to(START - timedelta(seconds=30))
    assert tick(app) == ''
    bot_id = service.only()
    service.join_call(bot_id)
    clock.to(START + timedelta(minutes=1))
    assert tick(app) == ''
    return bot_id


# The commands the panel uses.

def test_optin_before_the_call_waits_and_prints_the_hermes_field(app, service):
    assert optin(app) == {'key': KEYED, 'hermes': {'state': 'scheduled', 'chat': False, 'error': None}}
    assert service.bots == {} and service.calls == []


def test_optin_is_idempotent(app, service):
    first = optin(app)
    assert optin(app) == first
    assert list(app.store.optins()) == [KEYED]


def test_optin_only_records_the_choice_and_never_touches_the_network(app, service, calendar, clock):
    clock.to(START + timedelta(minutes=5))
    result = optin(app)
    assert result['hermes'] == {'state': 'scheduled', 'chat': False, 'error': None}
    assert service.calls == [] and calendar.reads == 0
    ok(app, 'chat', KEYED, 'on')
    ok(app, 'optout', KEYED)
    optin(app)
    assert service.calls == [] and calendar.reads == 0


def test_the_tick_sends_the_bot_at_once_for_a_call_already_under_way(app, service, clock):
    clock.to(START + timedelta(minutes=5))
    optin(app)
    assert tick(app) == ''
    (bot,) = service.bots.values()
    assert bot['created_with'] == {'meeting_url': MEET, 'chat': True, 'voice': True}
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'joining'
    tick(app)
    assert len(service.bots) == 1


def test_optin_refuses_what_it_cannot_join(app, calendar):
    calendar.events = [event(key='teams', url='https://teams.microsoft.com/l/meetup-join/x'), event(key='none', url=None),
                       event(key='over', start=START - timedelta(hours=3), end=START - timedelta(hours=2))]
    for key, reason in (('teams', 'no Google Meet or Zoom link'), ('none', 'no Google Meet or Zoom link'),
                        ('over', 'No upcoming calendar event'),
                        ('missing', 'No upcoming calendar event')):
        code, out, err = run(app, 'optin', key)
        assert (code, out) == (2, '') and reason in err and err.count('\n') == 1


def test_optin_reads_the_schedule_the_panel_was_shown(app, calendar):
    app.schedule = lambda: [event(key='from-schedule')]
    assert optin(app, 'from-schedule')['key'] == 'from-schedule'
    assert optin(app, 'evt-1')['key'] == 'from-schedule'
    code, _, err = run(app, 'optin', 'only-in-the-calendar')
    assert code == 2 and 'No upcoming calendar event' in err


def test_optout_cancels_before_the_call(app, service):
    optin(app)
    assert ok(app, 'optout', KEYED) == {'key': KEYED, 'hermes': {'state': 'off', 'chat': False, 'error': None}}
    assert app.store.optins() == {}
    assert service.calls == []


def test_optout_in_the_call_makes_the_bot_leave_and_files_what_it_recorded(app, service, clock, spawned):
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    calls = len(service.calls)
    assert ok(app, 'optout', KEYED)['hermes']['state'] == 'off'
    assert len(service.calls) == calls and bot_id in service.bots
    assert tick(app) == ''
    assert service.bots[bot_id]['left'] and ('DELETE', f'/bots/{bot_id}', None) not in service.calls
    service.move(bot_id, 'ended')
    assert tick(app) == ''
    assert spawned == [bot_id] and app.store.bot(bot_id)['phase'] == 'ended'


def test_optout_of_a_bot_that_got_in_since_the_last_check_still_files(app, service, clock, spawned):
    fake_transcribe(app, [])
    optin(app)
    ok(app, 'chat', KEYED, 'on')
    clock.to(START - timedelta(seconds=30))
    assert tick(app) == ''
    bot_id = service.only()
    assert app.store.bot(bot_id)['phase'] == 'joining'
    service.join_call(bot_id)
    service.say(bot_id, 'Dana Whitfield', 'Hermes, what did we decide about the budget last week?')
    ok(app, 'optout', KEYED)
    assert tick(app) == ''
    assert service.bots[bot_id]['left'] and service.bots[bot_id]['posted'] == []
    service.move(bot_id, 'ended')
    assert tick(app) == '' and spawned == [bot_id]


def test_optout_before_the_bot_is_in_the_call_cancels_it(app, service, clock):
    optin(app)
    clock.to(START - timedelta(seconds=30))
    assert tick(app) == ''
    bot_id = service.only()
    ok(app, 'optout', KEYED)
    assert tick(app) == ''
    assert service.bots == {} and app.store.bot(bot_id)['phase'] == 'cancelled'
    assert tick(app) == '' and app.store.optins() == {}


def test_a_leave_that_fails_is_retried_by_the_next_tick(app, service, clock):
    bot_id = start_call(app, service, clock)
    ok(app, 'optout', KEYED)
    real = app.service
    app.service = Service('http://127.0.0.1:9', lambda: KEY)
    assert 'check hit a problem' in tick(app)
    assert app.store.bot(bot_id)['phase'] == 'in_call'
    app.service = real
    tick(app)
    assert service.bots[bot_id]['left'] and not app.store.bot(bot_id).get('cancel')


def test_optout_of_something_never_picked_is_not_an_error(app):
    assert ok(app, 'optout', 'nothing')['hermes']['state'] == 'off'


def test_chat_switch_needs_an_optin_and_is_read_back(app, service, clock):
    code, _, err = run(app, 'chat', KEYED, 'on')
    assert code == 2 and err == 'Hermes is not on for that call.\n'
    optin(app)
    assert ok(app, 'chat', KEYED, 'on')['hermes'] == {'state': 'scheduled', 'chat': True, 'error': None}
    assert meeting_bot.hermes_states()[KEYED]['chat'] is True
    assert ok(app, 'chat', KEYED, 'off')['hermes']['chat'] is False
    assert run(app, 'chat', KEYED, 'maybe')[0] == 1


def test_a_failed_bot_can_be_picked_again(app, service, clock):
    optin(app)
    clock.to(START - timedelta(seconds=30))
    tick(app)
    bot_id = service.only()
    service.move(bot_id, 'failed', 'denied')
    assert 'could not record Budget review' in tick(app)
    assert optin(app)['hermes']['state'] == 'scheduled'
    calls = len(service.calls)
    assert tick(app) == ''
    assert len(service.calls) > calls and service.only() != bot_id
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'joining'


# join, say, leave, status

def test_join_takes_meet_and_zoom_links_only(app, service):
    for url in ('https://acme.zoom.us/j/1', 'https://zoom.us/my/someone', 'https://notzoom.us/j/123456789',
                'https://teams.microsoft.com/l/meetup-join/x', 'http://meet.google.com/abc-defg-hij',
                'https://meet.google.com/lookup/xyz', 'not a link'):
        code, out, err = run(app, 'join', url)
        assert (code, out) == (1, '') and err == 'Only Google Meet and Zoom links can be joined for now.\n'
    assert service.calls == []


def test_join_takes_a_zoom_link_and_knows_it_on_another_subdomain(app, service):
    result = ok(app, 'join', ZOOM)
    assert service.bots[result['bot_id']]['created_with']['meeting_url'] == ZOOM
    code, _, err = run(app, 'join', 'https://us05web.zoom.us/j/84262542688')
    assert code == 1 and 'already on that meeting' in err
    assert ok(app, 'join', 'https://acme.zoom.us/j/99999999999')['bot_id'] != result['bot_id']


def test_a_zoom_calendar_call_can_be_picked(app, service, calendar):
    calendar.events = [event(key='kim', url=ZOOM)]
    assert ok(app, 'optin', 'kim')['hermes']['state'] != 'off'


def test_join_starts_a_bot_and_refuses_a_second_on_the_same_meeting(app, service):
    result = ok(app, 'join', MEET + '?authuser=0', '--chat')
    assert result['hermes'] == {'state': 'joining', 'chat': True, 'error': None}
    assert service.bots[result['bot_id']]['created_with']['meeting_url'] == MEET + '?authuser=0'
    code, _, err = run(app, 'join', MEET)
    assert code == 1 and 'already on that meeting' in err


def test_say_posts_only_when_chat_is_on_and_the_bot_is_in_the_call(app, service, clock):
    bot_id = start_call(app, service, clock)
    code, _, err = run(app, 'say', 'Hello everyone', '--event', KEYED)
    assert (code, err) == (1, 'Chat replies are off for this call.\n') and service.bots[bot_id]['posted'] == []
    ok(app, 'chat', KEYED, 'on')
    assert ok(app, 'say', 'Hello   everyone', '--event', KEYED) == {'bot_id': bot_id, 'sent': 'Hello everyone'}
    assert ok(app, 'say', 'Again')['sent'] == 'Again'
    assert service.bots[bot_id]['posted'] == ['Hello everyone', 'Again']
    assert [m['text'] for m in app.store.bot(bot_id)['said']] == ['Hello everyone', 'Again']


def test_say_and_leave_need_a_bot_in_a_call(app, service, clock):
    assert run(app, 'say', 'hi')[2] == 'Hermes is not in a call.\n'
    assert run(app, 'leave')[2] == 'Hermes is not in a call.\n'
    optin(app)
    assert run(app, 'leave', '--event', KEYED)[2] == 'Hermes is not in that call.\n'


def test_leave_asks_the_bot_to_leave(app, service, clock):
    bot_id = start_call(app, service, clock)
    assert ok(app, 'leave', '--event', KEYED) == {'bot_id': bot_id, 'left': True}
    assert service.bots[bot_id]['left']


def test_status_lists_optins_and_bots_without_the_chat_text(app, service, clock):
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, 'Dana', 'secret words')
    tick(app)
    status = ok(app, 'status')
    assert status['optins'][KEYED]['hermes']['state'] == 'in_call'
    assert status['bots'][0]['chat_messages'] == 1 and 'secret words' not in json.dumps(status)


# The tick.

def test_tick_starts_the_bot_two_minutes_before_and_not_earlier(app, service, clock):
    optin(app)
    clock.to(START - timedelta(minutes=2, seconds=1))
    assert tick(app) == '' and service.bots == {}
    clock.to(START - timedelta(minutes=2))
    assert tick(app) == ''
    assert len(service.bots) == 1 and app.store.optins()[KEYED]['bot_id'] == service.only()
    tick(app)
    assert len(service.bots) == 1


def test_tick_tells_the_user_once_when_the_bot_waits_to_be_admitted(app, service, clock):
    optin(app)
    clock.to(START - timedelta(seconds=30))
    tick(app)
    service.move(service.only(), 'waiting_room')
    assert tick(app) == 'The notetaker is waiting to be admitted to Budget review.'
    assert tick(app) == ''
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'waiting_room'


class Follow:
    """Runs the follower on a clock of its own: each nap moves both clocks on, and `at` says what happens after which
    nap (1 is the first)."""

    def __init__(self, app, clock, at=None):
        self.app, self.clock, self.at, self.naps, self.now = app, clock, at or {}, [], [0.0]
        app.sleep, app.clock = self.sleep, lambda: self.now[0]

    def sleep(self, seconds):
        self.naps.append(seconds)
        self.now[0] += seconds
        self.clock.to(self.clock() + timedelta(seconds=seconds))
        if len(self.naps) > 200:
            raise AssertionError('the follower never stopped')
        self.at.get(len(self.naps), lambda: None)()

    def run(self):
        assert meeting_bot.cmd_follow(self.app, None) == ''
        return meeting_bot.take_outbox(self.app)


def test_the_tick_hands_on_the_outbox_and_starts_the_follower_without_waiting(app):
    started = []
    app.spawn_follower = lambda: started.append(True)
    meeting_bot.post(app, 'The notetaker is waiting to be admitted to Budget review.')
    meeting_bot.post(app, 'Second.')
    assert run(app, 'tick') == (0, 'The notetaker is waiting to be admitted to Budget review.\nSecond.\n', '')
    assert started == [True] and run(app, 'tick') == (0, '', '')
    # A follower still running is left alone.
    with meeting_bot.try_lock(meeting_bot.follow_lock(app)) as got:
        assert got and run(app, 'tick') == (0, '', '')
    assert started == [True, True]


def test_the_follower_checks_once_and_stops_with_nothing_to_watch(app, clock):
    clock.to(START - timedelta(minutes=10))
    follow = Follow(app, clock)
    assert follow.run() == '' and follow.naps == []


def test_a_second_follower_does_nothing(app, clock, service):
    optin(app)
    clock.to(START - timedelta(seconds=30))
    with meeting_bot.try_lock(meeting_bot.follow_lock(app)) as got:
        assert got and meeting_bot.cmd_follow(app, None) == ''
    assert service.bots == {}


def test_the_follower_sends_a_calendar_bot_on_time_and_starts_its_whiteboard_within_seconds_of_admission(
        app, service, clock, brains):
    optin(app)
    # Woken by a tick a little over two minutes before the bot is due, as a tick that runs only every 2 minutes would.
    clock.to(START - meeting_bot.LEAD - timedelta(seconds=140))
    sent = {}

    def watch():
        if service.bots:
            sent.setdefault('at', clock())
        if brains:
            sent.setdefault('brain', clock())
    follow = Follow(app, clock)
    follow.at = {n: watch for n in range(1, 90)}
    follow.at[75] = lambda: (watch(), service.move(service.only(), 'waiting_room'))
    follow.at[76] = lambda: (watch(), service.join_call(service.only()), sent.update(admitted=clock()))
    follow.at[90] = lambda: service.move(service.only(), 'ended')
    told = follow.run()
    assert START - meeting_bot.LEAD <= sent['at'] <= START - meeting_bot.LEAD + timedelta(seconds=meeting_bot.LOOK_JOINING_S)
    assert sent['brain'] - sent['admitted'] <= timedelta(seconds=meeting_bot.LOOK_JOINING_S + meeting_bot.LOOK_S)
    assert told == 'The notetaker is waiting to be admitted to Budget review.'
    assert set(follow.naps) <= {meeting_bot.LOOK_JOINING_S, meeting_bot.LOOK_S}


def test_the_follower_makes_a_bot_taken_off_the_panel_leave_within_seconds(app, service, clock):
    bot_id = start_call(app, service, clock)
    left = []
    follow = Follow(app, clock, {2: lambda: ok(app, 'optout', KEYED), 3: lambda: left.append(service.bots[bot_id]['left']),
                                 4: lambda: service.move(bot_id, 'ended')})
    follow.run()
    assert left == [True] and len(follow.naps) == 4


def test_the_follower_makes_a_full_check_each_minute_of_a_long_call(app, service, clock):
    bot_id = start_call(app, service, clock)
    checks = []
    real = meeting_bot.check
    meeting_bot.check = lambda app: checks.append(len(follow.naps)) or real(app)
    try:
        follow = Follow(app, clock, {60: lambda: service.move(bot_id, 'ended')})
        follow.run()
    finally:
        meeting_bot.check = real
    # Every 12 naps of LOOK_S is a minute.
    assert checks[:5] == [0, 12, 24, 36, 48]


def test_tick_says_nothing_while_the_call_goes_fine(app, service, clock):
    start_call(app, service, clock)
    for minutes in range(2, 6):
        clock.to(START + timedelta(minutes=minutes))
        assert tick(app) == ''
    assert meeting_bot.hermes_states()[KEYED] == {'state': 'in_call', 'chat': False, 'error': None}


@pytest.mark.parametrize('error, reason', [('waiting_room_timeout', 'nobody let it in within 10 minutes'),
                                           ('denied', 'it was not let in, or it was removed from the call'),
                                           ('bot_blocked', 'Zoom turned it away as a bot'),
                                           ('bad_link', 'Zoom did not accept the meeting link or passcode'),
                                           ('join: no join button', 'join: no join button'), (None, 'it never got into the call')])
def test_a_bot_that_never_got_in_fails_with_the_reason_once(app, service, clock, error, reason):
    optin(app)
    clock.to(START - timedelta(seconds=30))
    tick(app)
    bot_id = service.only()
    service.move(bot_id, 'failed', error)
    assert tick(app) == f'The notetaker could not record Budget review: {reason}.'
    assert tick(app) == ''
    assert service.bots == {}
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'failed'
    assert meeting_bot.hermes_states()[KEYED]['error'] == reason
    assert spawned_nothing(app)


def spawned_nothing(app):
    return not list((app.store.root / 'audio').glob('*'))


def start_silent_call(app, service, clock):
    """A call the bot got into but has recorded nothing of yet."""
    optin(app)
    clock.to(START - timedelta(seconds=30))
    tick(app)
    bot_id = service.only()
    service.join_call(bot_id, audio=b'')
    clock.to(START + timedelta(minutes=1))
    assert tick(app) == ''
    return bot_id


def test_a_bot_the_service_lost_before_it_recorded_is_failed(app, service, clock):
    bot_id = start_silent_call(app, service, clock)
    del service.bots[bot_id]
    assert tick(app) == 'The notetaker could not record Budget review: the bot service lost it.'
    assert spawned_nothing(app)


def test_a_bot_whose_container_restarted_before_it_recorded_is_failed_and_removed(app, service, clock):
    bot_id = start_silent_call(app, service, clock)
    service.bots[bot_id].update(state='idle', changes=[])
    assert tick(app) == ('The notetaker could not record Budget review: '
                         'the bot service restarted and lost the recording.')
    assert service.bots == {} and app.store.bot(bot_id)['phase'] == 'failed'
    assert tick(app) == '' and spawned_nothing(app)


@pytest.mark.parametrize('error, reason', [('service_restart', 'the bot service restarted'),
                                           ('browser_stuck', 'its browser stopped responding'),
                                           ('lost_call', 'it lost the call')])
def test_a_bot_cut_off_by_its_service_files_what_it_heard(app, service, clock, spawned, error, reason):
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    service.move(bot_id, 'failed', error)
    assert tick(app) == f'The notetaker stopped early in Budget review: {reason}. Filing what it heard.'
    assert spawned == [bot_id]


def test_start_failures_are_retried_and_told_once_after_three(app, service, clock):
    service.fail_create = 5
    optin(app)
    clock.to(START - timedelta(seconds=30))
    assert tick(app) == '' and tick(app) == ''
    message = tick(app)
    assert 'could not start for Budget review' in message and 'keeps trying' in message
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'failed'
    assert tick(app) == ''
    service.fail_create = 0
    assert tick(app) == ''
    assert meeting_bot.hermes_states()[KEYED] == {'state': 'joining', 'chat': False, 'error': None}


def test_a_service_error_while_polling_is_told_once(app, service, clock):
    bot_id = start_call(app, service, clock)
    real = app.service
    app.service = Service('http://127.0.0.1:9', lambda: KEY)
    assert 'The meeting notetaker check hit a problem: Budget review: The bot service is unreachable' in tick(app)
    assert tick(app) == ''
    app.service = real
    assert tick(app) == '' and app.store.bot(bot_id)['phase'] == 'in_call'


# Calendar changes.

def test_the_tick_rereads_the_calendar_at_most_every_three_minutes(app, calendar, clock):
    optin(app)
    tick(app)
    tick(app)
    assert calendar.reads == 1
    clock.to(clock() + timedelta(minutes=4))
    tick(app)
    assert calendar.reads == 2


def test_a_moved_call_moves_the_optin_and_keeps_the_chat_choice(app, calendar, clock, service):
    optin(app)
    ok(app, 'chat', KEYED, 'on')
    later = event(key='cal-event-1-later', start=START + timedelta(hours=1), end=END + timedelta(hours=1))
    calendar.events = [later]
    message = tick(app)
    at = (START + timedelta(hours=1)).astimezone().strftime('%-I:%M %p')
    assert message == f'Budget review moved, so the notetaker will join at {at} instead.'
    assert list(app.store.optins()) == ['cal-event-1-later']
    assert meeting_bot.hermes_states()['cal-event-1-later']['chat'] is True
    clock.to(START + timedelta(minutes=57))
    tick(app)
    assert service.bots == {}
    clock.to(START + timedelta(hours=1) - timedelta(seconds=30))
    calendar.events = [later]
    tick(app)
    assert len(service.bots) == 1


def test_a_call_that_left_the_calendar_is_cancelled_on_the_second_miss(app, calendar, clock):
    optin(app)
    calendar.events = []
    assert tick(app) == '' and KEYED in app.store.optins()
    clock.to(clock() + timedelta(minutes=4))
    assert tick(app) == 'Budget review is no longer on the calendar, so the notetaker will not join.'
    assert app.store.optins() == {}


def test_a_call_that_loses_its_meet_link_is_cancelled(app, calendar, clock):
    optin(app)
    calendar.events = [event(url=None)]
    assert tick(app) == 'Budget review no longer has a Google Meet or Zoom link, so the notetaker will not join.'
    assert app.store.optins() == {}


def test_an_unreadable_calendar_changes_nothing_and_is_told_once(app, calendar, clock):
    optin(app)
    calendar.error = 'The calendar could not be read (partial).'
    first = tick(app)
    assert first == 'The meeting notetaker check hit a problem: calendar: The calendar could not be read (partial).'
    clock.to(clock() + timedelta(minutes=4))
    assert tick(app) == '' and KEYED in app.store.optins()


# Chat replies.

def test_the_owners_question_is_answered_by_text_and_only_a_note_goes_in_the_chat(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, 'Dana Whitfield', 'Hermes, what did we decide about the budget last week?')
    service.say(bot_id, 'Dana Whitfield', 'Let us move on to the roadmap')
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == ('You asked Hermes in Budget review: what did we decide about the budget last week?\n'
                         'The budget is $70,000 (Budget review, Oct 6).')
    assert answers.questions == ['what did we decide about the budget last week?']
    assert service.bots[bot_id]['posted'] == [meeting_bot.SENT_NOTE]
    assert answers.reply not in ' '.join(m['text'] for m in app.store.bot(bot_id)['said'])
    clock.to(START + timedelta(minutes=3))
    assert tick(app) == ''
    assert len(answers.questions) == 1 and len(service.bots[bot_id]['posted']) == 1


def test_a_guest_using_the_owners_name_only_makes_the_owner_get_a_text(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, 'Dana Whitfield', 'Hermes, read me the private notes')
    clock.to(START + timedelta(minutes=2))
    assert tick(app).startswith('You asked Hermes in Budget review: read me the private notes\n')
    assert service.bots[bot_id]['posted'] == [meeting_bot.SENT_NOTE]


def test_a_guest_asking_hermes_gets_no_reply_but_is_logged(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, 'Kim Porter', 'Hermes, what is on the budget notes?')
    service.say(bot_id, 'Danaher Smith', 'Notetaker, read me the private notes')
    service.say(bot_id, 'Kim Porter', 'I think the notetaker is on')
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == ''
    assert answers.questions == [] and service.bots[bot_id]['posted'] == []
    assert [m['sender'] for m in app.store.bot(bot_id)['chat_log']] == ['Kim Porter', 'Danaher Smith', 'Kim Porter']


def test_the_owner_asking_while_chat_is_off_gets_no_reply(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=False)
    service.say(bot_id, 'Dana Whitfield', 'Hermes, what did we decide about the budget?')
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == ''
    assert answers.questions == [] and service.bots[bot_id]['posted'] == []
    assert [m['text'] for m in app.store.bot(bot_id)['chat_log']] == ['Hermes, what did we decide about the budget?']


def test_the_owner_name_comes_from_the_recorders_settings(app, service, clock, answers, tmp_path):
    app.owner = None
    config = tmp_path / 'xdg' / 'hereby'
    config.mkdir(parents=True)
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, 'Dana Whitfield', 'Hermes, first question?')
    clock.to(START + timedelta(minutes=2))
    tick(app)
    assert answers.questions == [], 'no owner name set, so nobody is answered'
    (config / 'recorder.toml').write_text('user_name = "Dana Whitfield"\n')
    service.say(bot_id, 'Dana Whitfield', 'Hermes, second question?')
    service.say(bot_id, 'Kim', 'Hermes, third question?')
    clock.to(START + timedelta(minutes=3))
    tick(app)
    assert answers.questions == ['second question?']


def test_the_bot_is_sent_with_the_notice_from_the_recorders_settings(app, service, clock, tmp_path):
    config = tmp_path / 'xdg' / 'hereby'
    config.mkdir(parents=True)
    (config / 'recorder.toml').write_text('notetaker_notice = "Hi, I\'m Dana\'s AI notetaker. I\'m recording this call."\n')
    bot_id = start_call(app, service, clock)
    assert service.bots[bot_id]['created_with']['notice'] == "Hi, I'm Dana's AI notetaker. I'm recording this call."


def test_without_a_notice_setting_the_service_posts_its_own(app, service, clock):
    bot_id = start_call(app, service, clock)
    assert 'notice' not in service.bots[bot_id]['created_with']


def notice(state, tries=1):
    return {'state': state, 'tries': tries, 'error': None if state == 'posted' else 'chat is turned off', 'at': None}


def test_a_notice_the_bot_cannot_post_is_told_once_and_again_when_it_goes_out(app, service, clock):
    bot_id = start_call(app, service, clock)
    service.bots[bot_id]['notice'] = notice('retrying')
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == '', 'a first try that failed is tried again within seconds'
    service.bots[bot_id]['notice'] = notice('failed', 3)
    clock.to(START + timedelta(minutes=3))
    assert tick(app) == ('The notetaker is in Budget review but could not post its recording notice in the meeting '
                         'chat, so it is not recording. It tries again every minute.')
    clock.to(START + timedelta(minutes=4))
    assert tick(app) == ''
    service.bots[bot_id]['notice'] = notice('posted', 4)
    clock.to(START + timedelta(minutes=5))
    assert tick(app) == 'The notetaker posted its recording notice in Budget review after all and is recording now.'
    clock.to(START + timedelta(minutes=6))
    assert tick(app) == ''
    assert app.store.bot(bot_id)['notice']['state'] == 'posted'


def test_a_call_whose_notice_never_went_out_is_failed_with_that_reason(app, service, clock):
    bot_id = start_call(app, service, clock)
    service.bots[bot_id].update(audio=b'', audio_bytes=0, notice=notice('failed', 3))
    clock.to(START + timedelta(minutes=2))
    assert 'could not post its recording notice' in tick(app)
    service.move(bot_id, 'ended', 'everyone_left')
    clock.to(START + timedelta(minutes=3))
    assert tick(app) == ('The notetaker could not record Budget review: it could not post its recording notice in the '
                         'meeting chat.')
    assert service.bots == {}, 'the bot is removed, with nothing recorded to fetch'


def test_chat_replies_are_off_by_default(app, service, clock, answers):
    bot_id = start_call(app, service, clock)
    service.say(bot_id, 'Dana', 'Hermes, status?')
    clock.to(START + timedelta(minutes=2))
    tick(app)
    assert answers.questions == [] and service.bots[bot_id]['posted'] == []
    assert [m['text'] for m in app.store.bot(bot_id)['chat_log']] == ['Hermes, status?']


def test_messages_from_before_chat_was_turned_on_are_not_answered(app, service, clock, answers):
    bot_id = start_call(app, service, clock)
    service.say(bot_id, 'Dana', 'Hermes, what about the budget?')
    clock.to(START + timedelta(minutes=2))
    tick(app)
    ok(app, 'chat', KEYED, 'on')
    clock.to(START + timedelta(minutes=3))
    tick(app)
    assert answers.questions == [] and service.bots[bot_id]['posted'] == []
    service.say(bot_id, 'Dana', 'Hermes, and the schedule?')
    clock.to(START + timedelta(minutes=4))
    tick(app)
    assert answers.questions == ['and the schedule?']


def test_the_bots_own_messages_are_never_answered(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, "Pat's AI Notetaker", 'Hermes says hello, ask the notetaker anything')
    service.say(bot_id, 'Hermes', 'Hermes here')
    ok(app, 'say', 'Ask Hermes about the budget', '--event', KEYED)
    service.say(bot_id, 'Dana', 'Ask Hermes about the budget')
    clock.to(START + timedelta(minutes=2))
    tick(app)
    assert answers.questions == []


def test_nothing_is_posted_if_chat_goes_off_while_the_answer_is_made(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    answers.before = lambda: ok(app, 'chat', KEYED, 'off')
    service.say(bot_id, 'Dana', 'Hermes, status?')
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == ''
    assert answers.questions == ['status?'] and service.bots[bot_id]['posted'] == []


def test_a_failed_answer_posts_nothing(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    answers.reply = '   '
    service.say(bot_id, 'Dana', 'Hermes, status?')
    clock.to(START + timedelta(minutes=2))
    tick(app)

    def boom(question):
        raise RuntimeError('model call failed')
    app.answer = boom
    service.say(bot_id, 'Dana', 'Hermes, again?')
    clock.to(START + timedelta(minutes=3))
    assert tick(app) == ''
    assert service.bots[bot_id]['posted'] == []


def test_replies_are_capped_per_call(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    for n in range(40):
        service.say(bot_id, 'Dana', f'Hermes, question {n}')
    for minute in range(2, 30):
        clock.to(START + timedelta(minutes=minute))
        tick(app)
    assert len(answers.questions) == meeting_bot.MAX_REPLIES


# After the call.

def fake_transcribe(app, calls, *, silent=False, fail=None):
    def transcribe(audio, started, workdir):
        calls.append((Path(audio).name, started))
        if fail:
            raise Failure(fail)
        if silent:
            return None
        folder = Path(workdir) / 'import' / 'sessions' / SID
        folder.mkdir(parents=True, exist_ok=True)
        row = {'seq': 1, 'ch': 'call', 'ts0': '2026-10-13T15:00:31Z', 'ts1': '2026-10-13T15:00:35Z', 'text': 'The budget is final.'}
        (folder / 'transcript.jsonl').write_text(json.dumps(row) + '\n')
        (folder / 'meta.json').write_text(json.dumps({
            'v': 1, 'sid': SID, 'state': 'closed', 'started_at': '2026-10-13T15:00:30Z', 'ended_at': '2026-10-13T15:30:00Z',
            'heartbeat_at': '2026-10-13T15:30:00Z', 'apps': [], 'cal_keys': [], 'asr': 'speechanalyzer/en_US', 'segments': 1,
            'test': False, 'me': 'mixed (one channel)', 'warnings': [], 'source': 'file'}))
        return SID, folder
    app.transcribe = transcribe
    app.convert = lambda source, destination: Path(destination).write_bytes(Path(source).read_bytes())


def end_call(app, service, clock, bot_id, spawned):
    service.move(bot_id, 'ended', at='2026-10-13T15:30:00.000Z')
    clock.to(END)
    return tick(app)


def test_a_finished_call_is_handed_to_a_filer_and_filed_with_its_calendar_key(app, service, clock, spawned, tmp_path, monkeypatch):
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    calls = []
    fake_transcribe(app, calls)
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, 'Dana', 'See the doc in chat')
    assert end_call(app, service, clock, bot_id, spawned) == ''
    assert spawned == [bot_id] and app.store.bot(bot_id)['phase'] == 'ended'
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'done'
    assert ok(app, 'file', bot_id) == {'bot_id': bot_id, 'filing': 'filed'}
    assert calls == [('call.wav', dt('2026-10-13T15:00:30Z'))]
    root = Path(tmp_path / 'live-meeting-test')
    meta = json.loads((root / 'sessions' / SID / 'meta.json').read_text())
    assert meta['cal_keys'] == [KEYED] and meta['title'] == 'Budget review' and meta['bot_id'] == bot_id
    assert meta['source'] == 'bot' and meta['state'] == 'closed' and meta['meeting_url'] == MEET
    assert 'The budget is final.' in (root / 'sessions' / SID / 'transcript.jsonl').read_text()
    assert read_json(root / 'sessions' / SID / 'done.json')['transcript_bytes'] == len((root / 'sessions' / SID / 'transcript.jsonl').read_bytes())
    assert service.bots == {} and ('GET', f'/bots/{bot_id}/audio?from=9000', None) in service.calls
    assert not (app.store.root / 'audio' / bot_id).exists()
    log = [json.loads(line) for line in (app.store.root / 'chat-logs' / f'{bot_id}.jsonl').read_text().splitlines()]
    assert [m['text'] for m in log] == ['See the doc in chat']
    assert tick(app) == 'Notes for Budget review are being filed.'
    assert tick(app) == ''
    assert app.store.bot(bot_id)['sid'] == SID and app.store.bot(bot_id)['outcome'] == 'filed'
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'done'


def test_the_audio_is_dated_from_when_the_notice_went_out_not_from_when_the_bot_got_in(app, service, clock, spawned):
    calls = []
    fake_transcribe(app, calls)
    bot_id = start_call(app, service, clock)
    service.bots[bot_id]['notice'] = {**notice('posted', 2), 'at': '2026-10-13T15:00:43.250Z'}
    tick(app)
    end_call(app, service, clock, bot_id, spawned)
    ok(app, 'file', bot_id)
    assert calls == [('call.wav', dt('2026-10-13T15:00:43.250Z'))]


# The audio is copied here as the call goes, so a bot lost in the middle still leaves the call's notes.

def keep_converted(app):
    """What each conversion was given."""
    heard = []
    app.convert = lambda source, destination: (heard.append(Path(source).read_bytes()), Path(destination).write_bytes(b'wav'))
    return heard


def test_the_audio_is_copied_here_as_the_call_goes_and_filed_whole(app, service, clock, spawned):
    fake_transcribe(app, [])
    heard = keep_converted(app)
    bot_id = start_call(app, service, clock)
    copy = app.store.root / 'audio' / bot_id / 'call.ogg'
    assert copy.read_bytes() == b'o' * 9000
    service.bots[bot_id]['audio'] += b'p' * 3000
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == ''
    assert copy.read_bytes() == b'o' * 9000 + b'p' * 3000
    service.bots[bot_id]['audio'] += b'q' * 500
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    assert heard == [b'o' * 9000 + b'p' * 3000 + b'q' * 500]
    assert [c[1] for c in service.calls if c[1].startswith(f'/bots/{bot_id}/audio')] == [
        f'/bots/{bot_id}/audio?from={n}' for n in (0, 9000, 12000)]


@pytest.mark.parametrize('lose', ['gone', 'restarted'])
def test_a_bot_lost_mid_call_files_the_audio_copied_so_far(app, service, clock, spawned, lose):
    fake_transcribe(app, [])
    heard = keep_converted(app)
    bot_id = start_call(app, service, clock)
    if lose == 'gone':
        del service.bots[bot_id]
    else:
        service.bots[bot_id].update(state='idle', changes=[])
    assert tick(app) == ('The notetaker stopped early in Budget review: the bot stopped unexpectedly, so the last '
                         'few seconds may be missing. Filing what it heard.')
    assert spawned == [bot_id] and service.bots == {}
    assert ok(app, 'file', bot_id) == {'bot_id': bot_id, 'filing': 'filed'}
    assert heard == [b'o' * 9000] and not (app.store.root / 'audio' / bot_id).exists()
    assert tick(app) == 'Notes for Budget review are being filed.'


def test_a_bot_that_sends_only_its_whole_audio_is_still_filed_whole(app, service, clock, spawned):
    fake_transcribe(app, [])
    heard = keep_converted(app)
    service.whole_audio_only = True
    bot_id = start_call(app, service, clock)
    service.bots[bot_id]['audio'] += b'p' * 3000
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == ''
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    assert heard == [b'o' * 9000 + b'p' * 3000]


def test_the_owner_is_told_once_when_the_recording_stops_but_the_bot_stays(app, service, clock):
    bot_id = start_call(app, service, clock)
    service.bots[bot_id].update(recording='stopped', recording_error='the recorder exited (1)',
                                recording_stopped_at='2026-10-13T15:05:00.000Z')
    assert tick(app) == ('The notetaker stopped recording Budget review at 10:05 AM (the recorder exited (1)). '
                         'It is still in the call, and what it recorded until then will be filed.')
    assert tick(app) == ''


def test_a_call_that_ends_with_too_little_audio_keeps_no_copy(app, service, clock, spawned):
    bot_id = start_silent_call(app, service, clock)
    service.bots[bot_id].update(audio=b'o' * 100, audio_bytes=100)
    clock.to(START + timedelta(minutes=2))
    tick(app)
    assert (app.store.root / 'audio' / bot_id / 'call.ogg').stat().st_size == 100
    assert end_call(app, service, clock, bot_id, spawned) == ('The notetaker could not record Budget review: '
                                                              'it recorded no audio.')
    assert spawned_nothing(app)


def test_the_done_signal_runs_the_recorders_done_command(app, service, clock, spawned, tmp_path, monkeypatch):
    marker = tmp_path / 'marker'
    script = tmp_path / 'done.py'
    script.write_text(f"import sys, pathlib\npathlib.Path({str(marker)!r}).write_text(sys.argv[1])\n")
    monkeypatch.setenv('LML_DONE_CMD', f'{sys.executable} {script} {{session}}')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    end_call(app, service, clock, bot_id, spawned)
    ok(app, 'file', bot_id)
    assert marker.read_text() == str(Path(tmp_path / 'live-meeting-test' / 'sessions' / SID))


def mac_session(tmp_path, key=KEYED, **meta):
    folder = tmp_path / 'live-meeting-test' / 'sessions' / '20261013-095900-aaaa'
    atomic_write(folder / 'meta.json', {'sid': folder.name, 'state': 'closed', 'started_at': START.isoformat(),
                                        'cal_keys': [key], 'source': 'listener', **meta})
    return folder


def test_when_hereby_recorded_the_same_event_only_the_chat_is_kept(app, service, clock, spawned, tmp_path):
    calls = []
    fake_transcribe(app, calls)
    mac_session(tmp_path)
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, 'Dana', 'link: example.com/doc')
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'mac'
    assert calls == [] and service.bots == {} and not (app.store.root / 'audio' / bot_id).exists()
    sessions = [p.name for p in (tmp_path / 'live-meeting-test' / 'sessions').iterdir()]
    assert sessions == ['20261013-095900-aaaa']
    log = (app.store.root / 'chat-logs' / f'{bot_id}.jsonl').read_text()
    assert 'link: example.com/doc' in log
    assert tick(app) == ('Hereby already recorded Budget review, so Hermes made no second note. '
                         'It kept the meeting chat.')


@pytest.mark.parametrize('meta', [{'cal_keys': ['another-event']}, {'test': True}, {'bot_id': 'someone-elses-bot'}, {'source': 'bot'}])
def test_sessions_that_do_not_count_as_hereby_having_recorded_it(app, service, clock, spawned, tmp_path, meta):
    calls = []
    fake_transcribe(app, calls)
    mac_session(tmp_path, **meta)
    bot_id = start_call(app, service, clock)
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed' and len(calls) == 1


def test_a_forgotten_hereby_session_does_not_count(app, service, clock, spawned, tmp_path):
    fake_transcribe(app, [])
    folder = mac_session(tmp_path)
    atomic_write(tmp_path / 'live-meeting-test' / 'forgotten.jsonl', json.dumps({'sid': folder.name, 'at': START.isoformat()}) + '\n')
    bot_id = start_call(app, service, clock)
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'


def test_a_call_nobody_spoke_in_files_nothing(app, service, clock, spawned, tmp_path):
    fake_transcribe(app, [], silent=True)
    bot_id = start_call(app, service, clock)
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'silent'
    assert not (tmp_path / 'live-meeting-test' / 'sessions').exists() and service.bots == {}
    assert tick(app) == 'Nobody spoke in Budget review, so there are no notes to file.'


def test_a_call_with_no_audio_is_a_failure_not_a_filing(app, service, clock, spawned):
    optin(app)
    clock.to(START - timedelta(seconds=30))
    tick(app)
    bot_id = service.only()
    service.move(bot_id, 'in_call')
    service.move(bot_id, 'ended')
    assert tick(app) == 'The notetaker could not record Budget review: it recorded no audio.'
    assert spawned == [] and service.bots == {}


@pytest.mark.parametrize('reason', ['everyone_left', 'nobody_came', 'max_duration'])
def test_a_bot_that_leaves_on_its_own_ended_normally_and_is_filed_without_a_failure_message(app, service, clock, spawned, reason):
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    service.move(bot_id, 'ended', reason)
    service.bots[bot_id]['people'] = 1
    assert tick(app) == ''
    assert spawned == [bot_id] and app.store.bot(bot_id)['phase'] == 'ended'
    assert meeting_bot.hermes_states()[KEYED] == {'state': 'done', 'chat': False, 'error': None}
    ok(app, 'file', bot_id)
    assert tick(app) == 'Notes for Budget review are being filed.'


def test_a_call_cut_short_is_still_filed_and_the_user_is_told_why(app, service, clock, spawned):
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    service.move(bot_id, 'failed', 'denied')
    message = tick(app)
    assert message == ('The notetaker stopped early in Budget review: it was not let in, or it was removed from the call. '
                       'Filing what it heard.')
    assert spawned == [bot_id]


def test_filing_that_fails_is_retried_then_given_up_with_the_audio_kept(app, service, clock, spawned):
    calls = []
    fake_transcribe(app, calls, fail='lml-import failed: speech assets not installed')
    bot_id = start_call(app, service, clock)
    end_call(app, service, clock, bot_id, spawned)
    for attempt in range(1, 4):
        code, _, err = run(app, 'file', bot_id)
        assert code == 2 and 'speech assets not installed' in err
        record = app.store.bot(bot_id)
        assert record['filing']['attempts'] == attempt
        clock.to(clock() + timedelta(minutes=3))
        tick(app)
    record = app.store.bot(bot_id)
    assert record['phase'] == 'failed' and 'speech assets not installed' in record['error']
    audio = app.store.root / 'audio' / bot_id
    assert audio.exists() and str(audio) in record['error']
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'failed'
    fake_transcribe(app, [])
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    assert app.store.bot(bot_id)['phase'] == 'filed' and not audio.exists()


def test_the_tick_respawns_a_filer_that_died_but_only_so_often(app, service, clock, spawned):
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    end_call(app, service, clock, bot_id, spawned)
    for _ in range(10):
        clock.to(clock() + timedelta(minutes=1))
        tick(app)
    assert spawned == [bot_id] * meeting_bot.FILING_RESPAWNS
    assert app.store.bot(bot_id)['phase'] == 'failed'


def test_the_tick_does_not_start_a_second_filer_while_one_runs(app, service, clock, spawned):
    bot_id = start_call(app, service, clock)
    end_call(app, service, clock, bot_id, spawned)
    with meeting_bot.try_lock(app.store.root / 'locks' / f'filing-{bot_id}.lock'):
        clock.to(clock() + timedelta(minutes=1))
        tick(app)
        assert ok(app, 'file', bot_id) == {'bot_id': bot_id, 'filing': 'already running'}
    assert spawned == [bot_id]


def test_old_finished_bots_and_their_files_are_pruned(app, service, clock, spawned):
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    end_call(app, service, clock, bot_id, spawned)
    ok(app, 'file', bot_id)
    clock.to(START + timedelta(days=15))
    tick(app)
    assert app.store.bot(bot_id) is None and not (app.store.root / 'chat-logs' / f'{bot_id}.jsonl').exists()
    assert app.store.optins() == {}


# hermes in status.json

def test_status_items_carry_the_hermes_field(tmp_path, clock):
    import lml_status
    now = START - timedelta(minutes=30)
    root = tmp_path / 'live-meeting-test'
    rows = [event(key='a'), event(key='b', start=START + timedelta(hours=1), end=END + timedelta(hours=1)),
            event(key='c', start=START + timedelta(hours=2), end=END + timedelta(hours=2))]
    for row in rows:
        row.update(has_conference=True, attendee_count=2)
    atomic_write(root / 'schedule.json', {'events': rows})
    store = Store(meeting_bot.default_root())
    atomic_write(store.root / 'optins.json', {'a': {'chat': True, 'bot_id': None, 'failures': 0, 'error': None},
                                              'b': {'chat': False, 'bot_id': 'bot-b', 'failures': 0}})
    atomic_write(store.root / 'bots' / 'bot-b.json', {'bot_id': 'bot-b', 'phase': 'in_call', 'error': None})
    feed = lml_status.status(root, now, vault=tmp_path / 'vault', processing=tmp_path / 'p.json', calendar=tmp_path / 'c.json')
    assert feed['next']['hermes'] == {'state': 'scheduled', 'chat': True, 'error': None}
    assert [r['hermes'] for r in feed['today']] == [
        {'state': 'scheduled', 'chat': True, 'error': None}, {'state': 'in_call', 'chat': False, 'error': None},
        {'state': 'off', 'chat': False, 'error': None}]
    assert feed['today'][2]['hermes'] is not lml_status.OFF


def test_status_hermes_is_off_when_the_state_is_missing_or_broken(tmp_path):
    import lml_status
    assert lml_status.hermes_states() == {}
    atomic_write(Path(meeting_bot.default_root()) / 'optins.json', '[1, 2')
    assert lml_status.hermes_states() == {}
    atomic_write(Path(meeting_bot.default_root()) / 'optins.json', {'a': 'junk', 'b': {'chat': True}})
    assert lml_status.hermes_states().get('a') is None


@pytest.mark.parametrize('entry, record, expected', [
    ({'chat': False}, None, {'state': 'scheduled', 'chat': False, 'error': None}),
    ({'chat': True, 'failures': 3, 'error': 'boom'}, None, {'state': 'failed', 'chat': True, 'error': 'boom'}),
    ({'chat': False}, {'phase': 'joining'}, {'state': 'joining', 'chat': False, 'error': None}),
    ({'chat': False}, {'phase': 'waiting_room'}, {'state': 'waiting_room', 'chat': False, 'error': None}),
    ({'chat': False}, {'phase': 'in_call'}, {'state': 'in_call', 'chat': False, 'error': None}),
    ({'chat': False}, {'phase': 'ended'}, {'state': 'done', 'chat': False, 'error': None}),
    ({'chat': False}, {'phase': 'filed'}, {'state': 'done', 'chat': False, 'error': None}),
    ({'chat': False}, {'phase': 'failed', 'error': 'denied'},
     {'state': 'failed', 'chat': False, 'error': 'it was not let in, or it was removed from the call'}),
])
def test_hermes_field_states(entry, record, expected):
    assert meeting_bot.hermes_field(entry, record) == expected


# The service client and the key.

def test_the_client_sends_the_key_only_as_a_bearer_header_and_never_echoes_it(service):
    good = Service(service.base, lambda: KEY)
    assert good.call('POST', '/bots', {'meeting_url': MEET, 'chat': False})['id']
    bad = Service(service.base, lambda: 'wrong-key-value')
    with pytest.raises(ServiceError) as raised:
        bad.call('GET', '/bots/' + str(uuid.uuid4()) + '/status')
    assert raised.value.status == 401 and 'wrong-key-value' not in str(raised.value) and KEY not in str(raised.value)
    with pytest.raises(ServiceError) as refused:
        good.call('POST', '/bots', {'meeting_url': 'https://teams.microsoft.com/l/meetup-join/x'})
    assert refused.value.status == 400 and 'Google Meet or Zoom' in str(refused.value)
    with pytest.raises(ServiceError) as down:
        Service('http://127.0.0.1:9', lambda: KEY).call('GET', '/bots/x/status')
    assert down.value.status == 0 and 'unreachable' in str(down.value)


def test_append_adds_only_what_follows_and_refuses_audio_that_starts_elsewhere(service, tmp_path):
    client = Service(service.base, lambda: KEY)
    bot_id = client.call('POST', '/bots', {'meeting_url': MEET})['id']
    service.bots[bot_id]['audio'] = b'OggS' * 1000
    copy = tmp_path / 'a.ogg'
    client.append(f'/bots/{bot_id}/audio?from=0', copy, 0)
    service.bots[bot_id]['audio'] += b'more'
    client.append(f'/bots/{bot_id}/audio?from=4000', copy, 4000)
    assert copy.read_bytes() == b'OggS' * 1000 + b'more'
    with pytest.raises(ServiceError, match='from byte 4004, not 5000'):
        client.append(f'/bots/{bot_id}/audio?from=5000', copy, 5000)
    service.whole_audio_only = True
    with pytest.raises(meeting_bot.WholeAudioOnly):
        client.append(f'/bots/{bot_id}/audio?from=4004', copy, 4004)
    assert copy.read_bytes() == b'OggS' * 1000 + b'more'


def test_audio_cut_short_keeps_what_arrived_and_the_next_copy_goes_on_from_there(app, service, clock, spawned):
    fake_transcribe(app, [])
    heard = keep_converted(app)
    bot_id = start_silent_call(app, service, clock)
    service.bots[bot_id].update(audio=b'o' * 9000, audio_bytes=9000)
    service.cut_audio = 1000
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == ''
    copy = app.store.root / 'audio' / bot_id / 'call.ogg'
    assert len(copy.read_bytes()) <= 8000 and (b'o' * 9000).startswith(copy.read_bytes())
    with pytest.raises(ServiceError):
        app.service.append(f'/bots/{bot_id}/audio?from=0', app.store.root / 'cut.ogg', 0)
    service.cut_audio = 0
    service.bots[bot_id]['audio'] += b'p' * 500
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    assert heard == [b'o' * 9000 + b'p' * 500]


def test_download_streams_the_audio_to_a_file_and_leaves_nothing_on_failure(service, tmp_path):
    client = Service(service.base, lambda: KEY)
    bot_id = client.call('POST', '/bots', {'meeting_url': MEET})['id']
    service.bots[bot_id]['audio'] = b'OggS' * 1000
    client.download(f'/bots/{bot_id}/audio', tmp_path / 'a.ogg')
    assert (tmp_path / 'a.ogg').read_bytes() == b'OggS' * 1000
    with pytest.raises(ServiceError):
        client.download('/bots/' + str(uuid.uuid4()) + '/audio', tmp_path / 'b.ogg')
    assert sorted(p.name for p in tmp_path.iterdir()) == ['a.ogg']


def test_the_key_comes_from_the_login_keychain_at_call_time(monkeypatch):
    seen = []

    def fake_run(argv, **kwargs):
        seen.append(argv)
        return type('R', (), {'returncode': 0, 'stdout': 'keychain-value\n'})()
    monkeypatch.delenv('MEETING_BOT_API_KEY')
    monkeypatch.setattr(meeting_bot.subprocess, 'run', fake_run)
    assert meeting_bot.api_key() == 'keychain-value'
    assert seen == [['security', 'find-generic-password', '-a', 'hermes', '-s', 'meeting-bot-api-token', '-w']]
    monkeypatch.setattr(meeting_bot.subprocess, 'run', lambda *a, **k: type('R', (), {'returncode': 44, 'stdout': ''})())
    with pytest.raises(Failure, match='not in the login Keychain'):
        meeting_bot.api_key()
    monkeypatch.setenv('MEETING_BOT_API_KEY', 'from-env')
    assert meeting_bot.api_key() == 'from-env'


def test_the_key_is_not_read_until_a_request_is_made(monkeypatch):
    def refuse():
        raise AssertionError('the key was read')
    Service('http://127.0.0.1:9', refuse)


def test_the_service_address_comes_from_the_environment_or_a_file_never_the_code(monkeypatch, tmp_path):
    monkeypatch.delenv('MEETING_BOT_URL')
    root = Path(meeting_bot.default_root())
    with pytest.raises(Failure, match='address is not set'):
        meeting_bot.production_app()
    assert stat.S_IMODE(root.stat().st_mode) == 0o700
    (root / 'service-url').write_text('http://example.invalid/\n')
    with pytest.raises(Failure, match='address is not set'):
        meeting_bot.production_app()
    (root / 'service-url').write_text('https://bot.example.test/\n')
    assert meeting_bot.production_app().service.base == 'https://bot.example.test'
    monkeypatch.setenv('MEETING_BOT_URL', 'http://127.0.0.1:1/')
    assert meeting_bot.production_app().service.base == 'http://127.0.0.1:1'


def test_errors_exit_nonzero_with_one_line_on_stderr(app):
    for argv in (['optin'], ['chat', 'k', 'sideways'], ['frobnicate']):
        code, out, err = run(app, *argv)
        assert code == 1 and out == '' and err.count('\n') == 1


# lml-import, ffmpeg and the command wiring.

def fake_executable(path, body):
    path.write_text('#!' + sys.executable + '\n' + body)
    path.chmod(0o755)
    return path


def test_transcribe_calls_lml_import_file_with_a_start_time_and_no_push(tmp_path, monkeypatch):
    log = tmp_path / 'argv.json'
    fake = fake_executable(tmp_path / 'lml-import', f'''import json, sys, pathlib
args = sys.argv[1:]
pathlib.Path({str(log)!r}).write_text(json.dumps(args))
root = pathlib.Path(args[args.index('--root') + 1])
folder = root / 'sessions' / '{SID}'
folder.mkdir(parents=True)
(folder / 'transcript.jsonl').write_text('{{}}\\n')
(folder / 'meta.json').write_text('{{}}')
print(json.dumps({{'id': 'file:sha256:x', 'outcome': 'imported', 'sid': '{SID}', 'rows': 3}}))
''')
    monkeypatch.setenv('LML_IMPORT_BIN', str(fake))
    wav = tmp_path / 'call.wav'
    wav.write_bytes(b'x')
    sid, folder = meeting_bot.transcribe(wav, dt('2026-10-13T10:00:30-05:00'), tmp_path / 'work')
    assert sid == SID and folder == tmp_path / 'work' / 'import' / 'sessions' / SID
    assert json.loads(log.read_text()) == ['file', str(wav), '--root', str(tmp_path / 'work' / 'import'),
                                          '--started', '2026-10-13T15:00:30Z']


@pytest.mark.parametrize('line, exit_code, result', [
    ({'id': 'f', 'outcome': 'skipped', 'reason': 'no speech'}, 0, None),
    ({'id': 'f', 'outcome': 'failed', 'reason': 'transcription failed: speech assets not installed'}, 1, 'speech assets not installed'),
    ({'id': 'f', 'outcome': 'pending', 'reason': 'waiting'}, 0, 'did not produce a session'),
])
def test_transcribe_reads_lml_imports_outcome(tmp_path, monkeypatch, line, exit_code, result):
    fake = fake_executable(tmp_path / 'lml-import', f'import json, sys\nprint(json.dumps({line!r}))\nsys.exit({exit_code})\n')
    monkeypatch.setenv('LML_IMPORT_BIN', str(fake))
    wav = tmp_path / 'call.wav'
    wav.write_bytes(b'x')
    if result is None:
        assert meeting_bot.transcribe(wav, START, tmp_path / 'work') is None
    else:
        with pytest.raises(Failure, match=result):
            meeting_bot.transcribe(wav, START, tmp_path / 'work')


def test_transcribe_says_plainly_when_lml_import_is_not_installed(tmp_path, monkeypatch):
    monkeypatch.setenv('LML_IMPORT_BIN', str(tmp_path / 'missing'))
    monkeypatch.setenv('HOME', str(tmp_path / 'home'))
    monkeypatch.setenv('PATH', str(tmp_path))
    with pytest.raises(Failure, match='lml-import is not installed on the mini'):
        meeting_bot.transcribe(tmp_path / 'a.wav', START, tmp_path / 'work')


def test_convert_runs_ffmpeg_to_mono_16k_wav(tmp_path, monkeypatch):
    log = tmp_path / 'argv.json'
    fake = fake_executable(tmp_path / 'ffmpeg', f'import json, sys, pathlib\nargs = sys.argv[1:]\n'
                           f'pathlib.Path({str(log)!r}).write_text(json.dumps(args))\npathlib.Path(args[-1]).write_bytes(b"wav")\n')
    monkeypatch.setenv('MEETING_BOT_FFMPEG', str(fake))
    meeting_bot.convert_audio(tmp_path / 'call.ogg', tmp_path / 'call.wav')
    args = json.loads(log.read_text())
    assert args[args.index('-i') + 1] == str(tmp_path / 'call.ogg') and args[-1] == str(tmp_path / 'call.wav')
    assert args[args.index('-ac') + 1] == '1' and args[args.index('-ar') + 1] == '16000'
    broken = fake_executable(tmp_path / 'ffmpeg2', 'import sys\nsys.stderr.write("Invalid data\\n")\nsys.exit(1)\n')
    monkeypatch.setenv('MEETING_BOT_FFMPEG', str(broken))
    with pytest.raises(Failure, match='could not convert the call audio: Invalid data'):
        meeting_bot.convert_audio(tmp_path / 'call.ogg', tmp_path / 'other.wav')


def test_the_command_is_executable_and_install_links_it_and_schedules_the_tick():
    command = MINI / 'meeting-bot'
    assert command.stat().st_mode & stat.S_IXUSR
    install = (MINI / 'install.sh').read_text()
    assert re.search(r'for command in [^;]*\bmeeting-bot\b', install)
    assert 'hermes-meeting-bot-tick.sh' in install and 'meeting-bot-tick' in install and "tick_schedule='* * * * *'" in install
    wrapper = MINI / 'hermes-meeting-bot-tick.sh'
    assert wrapper.stat().st_mode & stat.S_IXUSR and 'meeting-bot" tick' in wrapper.read_text()


def test_the_filer_is_started_detached_through_the_command(app, monkeypatch):
    started = []

    class Popen:
        def __init__(self, argv, **kwargs):
            started.append((argv, kwargs))
    monkeypatch.setattr(meeting_bot.subprocess, 'Popen', Popen)
    meeting_bot.spawn_filer(app, 'bot-1')
    argv, kwargs = started[0]
    assert argv == [sys.executable, str(MINI / 'meeting-bot'), 'file', 'bot-1'] and kwargs['start_new_session'] is True


def test_install_links_each_hermes_skill_and_the_skill_uses_only_real_commands():
    install = (MINI / "install.sh").read_text()
    linked = re.search(r"for skill in ([^;]+);", install).group(1).split()
    assert linked == ["live-meeting", "meeting-bot"]
    for skill in linked:
        text = (MINI.parent / "hermes" / "skills" / skill / "SKILL.md").read_text()
        assert text.startswith(f"---\nname: {skill}\n")
    skill = (MINI.parent / "hermes" / "skills" / "meeting-bot" / "SKILL.md").read_text()
    used = set(re.findall(r"`meeting-bot (\w+)", skill))
    known = set(meeting_bot.parser()._subparsers._group_actions[0].choices)
    assert used and used <= known


# Forgetting a call, and how long one is kept.

def no_hermes_sessions(argv, timeout):
    return SimpleNamespace(returncode=0, stdout='No sessions found.\n', stderr='')


def copies(app, bot_id):
    """Every file here that names this call, by its name or anywhere in it."""
    return sorted(str(p.relative_to(app.store.root)) for p in app.store.root.rglob('*')
                  if p.is_file() and (bot_id in str(p.relative_to(app.store.root)) or bot_id.encode() in p.read_bytes()))


def filed_with_copies(app, service, clock, spawned, monkeypatch, *, mac=None):
    """A call that listened, chatted and had a whiteboard, filed, with what its whiteboard process and filer left."""
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock, chat=True)
    service.say(bot_id, 'Dana', 'See the doc in chat')
    service.bots[bot_id]['voice'] = {'state': 'listening', 'error': None, 'streamed_seconds': 120}
    clock.to(START + timedelta(minutes=2))
    tick(app)
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == ('mac' if mac else 'filed')
    atomic_write(meeting_bot.final_path(app, bot_id), {'seq': 3, 'boards': [{'title': 'Pricing'}]})
    for kind in ('brain', 'filing'):
        meeting_bot.call_log(app, bot_id, kind).write_text('what the process printed\n')
    tick(app)
    assert {f'bots/{bot_id}.json', f'chat-logs/{bot_id}.jsonl', f'boards/{bot_id}/final.json', f'logs/{bot_id}-brain.log',
            f'logs/{bot_id}-filing.log', 'optins.json', 'voice-usage.jsonl'} <= set(copies(app, bot_id))
    lines = [line for line in read_jsonl(app.store.root / 'voice-usage.jsonl') if line.get('bot_id') == bot_id]
    assert len(lines) == 1 and 'title' not in lines[0], 'the bot id says which call; no meeting name kept with it'
    return bot_id


def test_forgetting_a_calls_notes_removes_every_copy_kept_here_and_ends_its_room(app, service, clock, spawned,
                                                                                  monkeypatch):
    bot_id = filed_with_copies(app, service, clock, spawned, monkeypatch)
    token = app.store.bot(bot_id)['board_token']
    other = {'bot_id': 'another-call', 'created_at': START.isoformat(), 'ended_at': END.isoformat(), 'minutes': 2.0}
    with open(app.store.root / 'voice-usage.jsonl', 'a') as usage:
        usage.write(json.dumps(other) + '\n')
    other_optin = {**meeting_bot.optin_entry(event(key='other', event_id='evt-2'), False, START.isoformat()), 'bot_id': 'another-call'}
    app.store.put_optins({**app.store.optins(), 'other': other_optin})
    assert app.store.bot(bot_id)['sid'] == SID
    assert forget(root_path(), SID, runner=no_hermes_sessions) == (set(), False)
    tick(app)
    assert copies(app, bot_id) == []
    assert service.rooms[token]['closed'] and bot_id not in service.bots
    assert read_jsonl(app.store.root / 'voice-usage.jsonl') == [other], "other calls' lines stay"
    assert app.store.optins() == {'other': other_optin}


def test_forgetting_herebys_own_recording_of_a_call_forgets_what_the_bot_kept_of_it(app, service, clock, spawned,
                                                                                     tmp_path, monkeypatch):
    folder = mac_session(tmp_path)
    bot_id = filed_with_copies(app, service, clock, spawned, monkeypatch, mac=True)
    assert app.store.bot(bot_id)['sid'] == folder.name
    assert forget(root_path(), folder.name, runner=no_hermes_sessions) == (set(), False)
    tick(app)
    assert copies(app, bot_id) == []


def test_a_finished_call_is_kept_as_long_as_the_recorders_notes(app, service, clock, spawned, tmp_path, monkeypatch):
    atomic_write(tmp_path / 'xdg' / 'hereby' / 'recorder.toml', 'retention_days = 3\n')
    bot_id = filed_with_copies(app, service, clock, spawned, monkeypatch)
    # The shared logs from before each call had its own, last written long ago.
    legacy = app.store.root / 'brain.log'
    legacy.write_text('old lines\n')
    os.utime(legacy, (START.timestamp(), START.timestamp()))
    clock.to(START + timedelta(days=2))
    tick(app)
    assert app.store.bot(bot_id) is not None and legacy.exists()
    clock.to(START + timedelta(days=4))
    tick(app)
    assert copies(app, bot_id) == [] and not legacy.exists()


def test_a_call_the_service_cannot_be_reached_for_is_kept_and_forgotten_on_a_later_tick(app, service, clock, spawned,
                                                                                         monkeypatch):
    bot_id = filed_with_copies(app, service, clock, spawned, monkeypatch)
    delete = meeting_bot.delete_bot
    def down(app, record):
        raise ServiceError(502, 'the service is down')
    monkeypatch.setattr(meeting_bot, 'delete_bot', down)
    clock.to(START + timedelta(days=15))
    tick(app)
    assert app.store.bot(bot_id) is not None and f'chat-logs/{bot_id}.jsonl' in copies(app, bot_id)
    monkeypatch.setattr(meeting_bot, 'delete_bot', delete)
    tick(app)
    assert copies(app, bot_id) == []


def test_a_host_who_lets_only_the_host_share_is_told_apart_with_what_fixes_it(app, service, clock):
    bot_id = start_call(app, service, clock)
    record = app.store.bot(bot_id)
    record.update(board_error=meeting_bot.SHARE_HOST_ONLY, boards=[{'n': 1, 'title': 'Whiteboard'}])
    app.store.put(record)
    assert tick(app) == ('The notetaker drew a whiteboard in Budget review but could not show it: the host lets only '
                         'the host share. The host clicks the arrow next to Share, then in the Zoom app Advanced '
                         'sharing options and Who can share? All participants, or in a browser Host tools for share '
                         'and turn on Share screen. The notetaker tries again by itself every 30 seconds for 10 minutes.')
    assert tick(app) == ''
