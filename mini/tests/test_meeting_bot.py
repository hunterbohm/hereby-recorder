"""The meeting bot against a fake bot service (a loopback HTTP server) and a fake calendar. No real service or calendar."""
import io
import json
import re
import stat
import sys
import threading
import uuid
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

import meeting_bot
from lml_common import atomic_write, dt, read_json
from meeting_bot import App, Failure, Service, ServiceError, Store, Usage

MINI = Path(__file__).resolve().parents[1]
KEY = 'test-key-not-real'
MEET = 'https://meet.google.com/abc-defg-hij'
START = dt('2026-10-13T10:00:00-05:00')
END = dt('2026-10-13T11:00:00-05:00')
KEYED = 'cal-event-1'
SID = '20261013-100000-abcd'


class FakeService:
    """The bot service's API over loopback: bots, their state changes, chat, audio and delete."""

    def __init__(self):
        self.bots, self.calls, self.audio_gets = {}, [], 0
        self.fail_create = 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, value=None, raw=None):
                body = raw if raw is not None else json.dumps(value).encode()
                self.send_response(status)
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
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def route(self, handler, method, path, body):
        if (method, path) == ('POST', '/bots'):
            if self.fail_create:
                self.fail_create -= 1
                return handler.reply(502, {'error': 'bot did not start: 500'})
            if not re.match(r'^https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}', body.get('meeting_url') or ''):
                return handler.reply(400, {'error': 'meeting_url must be a Google Meet link'})
            bot_id = str(uuid.uuid4())
            self.bots[bot_id] = {'state': 'joining', 'error': None, 'changes': [self.change('joining')], 'audio_bytes': 0,
                                 'chat': [], 'created_with': body, 'audio': b'', 'left': False, 'posted': []}
            return handler.reply(201, {'id': bot_id})
        match = re.fullmatch(r'/bots/([0-9a-f-]{36})(/status|/chat|/leave|/audio)?', path)
        bot = self.bots.get(match.group(1)) if match else None
        if bot is None:
            return handler.reply(404, {'error': 'not found'})
        action = match.group(2)
        if method == 'DELETE' and action is None:
            del self.bots[match.group(1)]
            return handler.reply(200, {'ok': True})
        if (method, action) == ('GET', '/status'):
            return handler.reply(200, {'state': bot['state'], 'error': bot['error'], 'changes': bot['changes'],
                                       'audio_bytes': bot['audio_bytes'], 'chat': bot['chat']})
        if (method, action) == ('POST', '/chat'):
            bot['posted'].append(body['message'])
            return handler.reply(200, {'ok': True})
        if (method, action) == ('POST', '/leave'):
            bot['left'] = True
            return handler.reply(200, {'ok': True})
        if (method, action) == ('GET', '/audio'):
            self.audio_gets += 1
            return handler.reply(200, raw=bot['audio'])
        return handler.reply(404, {'error': 'not found'})

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
def app(tmp_path, service, clock, calendar, spawned, answers):
    return App(Store(meeting_bot.default_root()), Service(service.base, lambda: KEY), events=calendar,
               schedule=lambda: [e for e in calendar.events], answer=answers, owner='Dana', spawn=spawned.append, now=clock,
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
    return meeting_bot.cmd_tick(app, None)


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
    assert bot['created_with'] == {'meeting_url': MEET, 'chat': True}
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'joining'
    tick(app)
    assert len(service.bots) == 1


def test_optin_refuses_what_it_cannot_join(app, calendar):
    calendar.events = [event(key='zoom', url='https://acme.zoom.us/j/123'), event(key='none', url=None),
                       event(key='over', start=START - timedelta(hours=3), end=START - timedelta(hours=2))]
    for key, reason in (('zoom', 'no Google Meet link'), ('none', 'no Google Meet link'), ('over', 'No upcoming calendar event'),
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

def test_join_takes_meet_links_only(app, service):
    for url in ('https://acme.zoom.us/j/1', 'https://teams.microsoft.com/l/meetup-join/x', 'http://meet.google.com/abc-defg-hij',
                'https://meet.google.com/lookup/xyz', 'not a link'):
        code, out, err = run(app, 'join', url)
        assert (code, out) == (1, '') and err == 'Only Google Meet links can be joined for now.\n'
    assert service.calls == []


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

def test_tick_starts_the_bot_one_minute_before_and_not_earlier(app, service, clock):
    optin(app)
    clock.to(START - timedelta(minutes=2))
    assert tick(app) == '' and service.bots == {}
    clock.to(START - timedelta(seconds=59))
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


def test_tick_says_nothing_while_the_call_goes_fine(app, service, clock):
    start_call(app, service, clock)
    for minutes in range(2, 6):
        clock.to(START + timedelta(minutes=minutes))
        assert tick(app) == ''
    assert meeting_bot.hermes_states()[KEYED] == {'state': 'in_call', 'chat': False, 'error': None}


@pytest.mark.parametrize('error, reason', [('waiting_room_timeout', 'nobody let it in within 10 minutes'),
                                           ('denied', 'it was not let in, or it was removed from the call'),
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


def test_a_bot_the_service_lost_is_failed(app, service, clock):
    bot_id = start_call(app, service, clock)
    del service.bots[bot_id]
    assert tick(app) == 'The notetaker could not record Budget review: the bot service lost it.'


def test_a_bot_whose_container_restarted_is_failed_and_removed(app, service, clock):
    bot_id = start_call(app, service, clock)
    service.bots[bot_id].update(state='idle', changes=[])
    assert tick(app) == ('The notetaker could not record Budget review: '
                         'the bot service restarted and lost the recording.')
    assert service.bots == {} and app.store.bot(bot_id)['phase'] == 'failed'
    assert tick(app) == ''


@pytest.mark.parametrize('error, reason', [('service_restart', 'the bot service restarted'),
                                           ('browser_stuck', 'its browser stopped responding')])
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


def test_two_ticks_never_run_together(app, service, clock):
    optin(app)
    clock.to(START - timedelta(seconds=30))
    with meeting_bot.try_lock(app.store.root / 'tick.lock') as got:
        assert got and tick(app) == ''
    assert service.bots == {}


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
    clock.to(START + timedelta(minutes=58))
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
    assert tick(app) == 'Budget review no longer has a Google Meet link, so the notetaker will not join.'
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
    assert service.bots == {} and ('GET', f'/bots/{bot_id}/audio', None) in service.calls
    assert not (app.store.root / 'audio' / bot_id).exists()
    log = [json.loads(line) for line in (app.store.root / 'chat-logs' / f'{bot_id}.jsonl').read_text().splitlines()]
    assert [m['text'] for m in log] == ['See the doc in chat']
    assert tick(app) == 'Notes for Budget review are being filed.'
    assert tick(app) == ''
    assert app.store.bot(bot_id)['sid'] == SID and app.store.bot(bot_id)['outcome'] == 'filed'
    assert meeting_bot.hermes_states()[KEYED]['state'] == 'done'


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
    assert calls == [] and service.audio_gets == 0 and service.bots == {}
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
        good.call('POST', '/bots', {'meeting_url': 'https://acme.zoom.us/j/1'})
    assert refused.value.status == 400 and 'Google Meet' in str(refused.value)
    with pytest.raises(ServiceError) as down:
        Service('http://127.0.0.1:9', lambda: KEY).call('GET', '/bots/x/status')
    assert down.value.status == 0 and 'unreachable' in str(down.value)


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
    assert 'hermes-meeting-bot-tick.sh' in install and 'meeting-bot-tick' in install and "'every 1m'" in install
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
