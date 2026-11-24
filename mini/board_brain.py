"""Hermes's side of a call's live whiteboard. One process per call (`meeting-bot brain <bot id>`, started by the tick
when the bot gets into the call) keeps a stream open to the call's board room on the bot service and takes each board
command the moment the room has it: spoken ones as soon as the speaker stops, typed ones within a second.

For each command it asks the model for small edits, streamed, and sends every edit to the room as soon as the model has
finished it, so the board on the call's screen grows a block or an item at a time while the model is still working.
Then the bot exports the board, and the picture and Excalidraw file are kept here for the meeting notes, as before.

The model is reached directly through the Messages API that <state root>/board-model.json names (the same gateway Hermes
itself uses):

  {"url": "http://127.0.0.1:8317", "key_file": "~/.config/...", "edit_model": "claude-haiku-5-5",
   "new_model": "claude-sonnet-5-5", "sketch_model": "claude-sonnet-5-5"}

A custom picture ("draw how our system talks to Stripe") is the one change that is not drawn at once: the command's
block goes up straight away saying Hermes is drawing it, and the picture is written in the background (draw_sketch),
shown as it comes and finished a few seconds later, while the next command goes ahead.

Without that file it asks through Hermes's own chat, which works but takes several seconds more.
"""
import http.client
import json
import secrets
import threading
import time
import urllib.parse
from datetime import datetime, timedelta
from pathlib import Path

import meeting_board

EDIT_MODEL = 'claude-haiku-5-5'
NEW_MODEL = 'claude-sonnet-5-5'
# The custom picture's model. Sonnet: on the same three pictures it was done in 2.9 to 7.5 s and laid each out cleanly,
# keeping the layout when asked for a change; Haiku was faster (2.7-4.9 s) but its labels overlapped and ran off the
# edge, and Opus (it always thinks) took 8-19 s. On a nine-part system map Sonnet routed an arrow to the wrong box in
# about one picture in five until it was asked to write its layout as a comment first (meeting_board.SKETCH_SYSTEM),
# and the brief stopped placing single parts; then four of four came out right, in 5.3-5.5 s. Asking it to think
# (adaptive, low or medium effort) changed nothing: it chose not to. Measured 2026-11-22,
# ~/research/hermes-rich-visuals/results/probe-sketch*/.
SKETCH_MODEL = 'claude-sonnet-5-5'
MODEL_SECONDS = 45
# How often a picture still being written is shown as it is so far.
SKETCH_EVERY_S = 1.2
# A command the room kept from before this process started is still carried out if it is this recent.
STALE = timedelta(seconds=90)
# Board commands one call may make, so a runaway chat or a stuck speaker cannot run up the model.
MAX_COMMANDS = 60
GOT_IT_CHARS = 200
# Waits before opening the room's stream again after it drops.
WAITS = (1, 2, 5, 10, 20)
# A board someone changed from the link is kept for the notes once their changes stop for this long.
KEEP_AFTER_S = 3
# The meeting chat line with the board link, said once per call and only with chat replies on.
LINK_LINE = 'Open the whiteboard to follow along or change it: '


class RoomError(Exception):
    pass


class Room:
    """A call's board room on the bot service: its event stream, and messages to it on one kept-open connection."""

    def __init__(self, base, token, key):
        self.url = urllib.parse.urlsplit(base)
        self.token, self._key, self._token, self._conn = token, key, None, None
        # The room's change count after the last message sent from here: a command whose boards are older than this
        # came with boards that miss changes made since.
        self.seq = 0

    def _connect(self, timeout):
        kind = http.client.HTTPSConnection if self.url.scheme == 'https' else http.client.HTTPConnection
        return kind(self.url.hostname, self.url.port, timeout=timeout)

    def _headers(self, extra=None):
        self._token = self._token or self._key()
        return {'Authorization': 'Bearer ' + self._token, 'User-Agent': 'hermes-meeting-bot', **(extra or {})}

    def _path(self, what):
        return f'{self.url.path.rstrip("/")}/rooms/{self.token}/{what}'

    def _call(self, method, what, body=None, timeout=20):
        data = None if body is None else json.dumps(body).encode()
        headers = self._headers({'Content-Type': 'application/json'} if data is not None else None)
        for attempt in (1, 2):
            try:
                if self._conn is None:
                    self._conn = self._connect(timeout)
                self._conn.request(method, self._path(what), data, headers)
                response = self._conn.getresponse()
                raw = response.read()
                if response.status != 200:
                    raise RoomError(f'the board room answered {response.status}')
                return json.loads(raw) if raw.strip() else None
            except (http.client.HTTPException, OSError, ValueError) as exc:
                if self._conn is not None:
                    self._conn.close()
                self._conn = None
                if attempt == 2:
                    raise RoomError(f'the board room is unreachable: {exc}') from None

    def send(self, *msgs):
        """Each message's result, in order: {'ok': True, ...} or {'ok': False, 'error': ...}."""
        answer = self._call('POST', 'send', {'msgs': list(msgs)}) or {}
        self.seq = max(self.seq, int(answer.get('seq') or 0))
        results = answer.get('results') or []
        return results + [{'ok': False, 'error': 'no answer'}] * (len(msgs) - len(results))

    def state(self):
        return self._call('GET', 'state') or {}

    def sibling(self):
        """The same room on a connection of its own, for a thread other than the one that sends edits."""
        return Room(urllib.parse.urlunsplit(self.url), self.token, self._key)

    def close(self):
        return self._call('POST', 'close')

    def events(self, after=0, timeout=40):
        """The room's events as dicts, as they happen; None for a keep-alive, so a reader can look around between."""
        conn = self._connect(timeout)
        try:
            conn.request('GET', self._path(f'events?after={int(after)}'), headers=self._headers({'Accept': 'text/event-stream'}))
            response = conn.getresponse()
            if response.status != 200:
                raise RoomError(f'the board room answered {response.status}')
            data = []
            for raw in response:
                line = raw.decode('utf-8', 'replace').rstrip('\r\n')
                if line.startswith('data:'):
                    data.append(line[5:].strip())
                elif line.startswith(':'):
                    yield None
                elif not line and data:
                    try:
                        yield json.loads('\n'.join(data))
                    except ValueError:
                        pass
                    data = []
        finally:
            conn.close()


class Model:
    """The Messages API, streamed: each finished edit as the model makes it."""

    def __init__(self, url, key, edit_model=EDIT_MODEL, new_model=NEW_MODEL, sketch_model=SKETCH_MODEL):
        self.url, self.key = urllib.parse.urlsplit(url), key
        self.edit_model, self.new_model, self.sketch_model = edit_model, new_model, sketch_model

    def pick(self, kind, command):
        """The stronger model for a board that is rebuilt (grouped, sorted, split); the fast one for everything else,
        which is most changes, a board's first block and a block drawn another way ("make that a pie chart") included."""
        command = meeting_board.bare(command)
        if meeting_board.REARRANGE.search(command) and not meeting_board.CONVERT.search(command):
            return self.new_model
        return self.edit_model

    def _stream(self, body):
        kind_of = http.client.HTTPSConnection if self.url.scheme == 'https' else http.client.HTTPConnection
        conn = kind_of(self.url.hostname, self.url.port, timeout=MODEL_SECONDS)
        conn.request('POST', self.url.path.rstrip('/') + '/v1/messages', json.dumps(body),
                     {'content-type': 'application/json', 'x-api-key': self.key, 'anthropic-version': '2023-06-01'})
        response = conn.getresponse()
        if response.status != 200:
            conn.close()
            raise RuntimeError(f'the model answered {response.status}')
        return conn, response

    def edits(self, board, command, kind):
        conn, response = self._stream(meeting_board.request(board, command, self.pick(kind, command)))
        try:
            yield from meeting_board.edits(response)
        finally:
            conn.close()

    def draw(self, title, brief, previous=None, shows=None):
        """A custom picture's SVG as the model writes it, a piece at a time."""
        conn, response = self._stream(meeting_board.sketch_request(title, brief, self.sketch_model, previous=previous,
                                                                   shows=shows))
        try:
            yield from meeting_board.text_deltas(response)
        finally:
            conn.close()


class HermesModel:
    """The same edits through Hermes's own chat: one reply, applied at the end. For a mini without board-model.json."""

    def __init__(self, ask):
        self.ask = ask

    def edits(self, board, command, kind):
        yield from meeting_board.fallback_edits(self.ask(meeting_board.fallback_prompt(board, command)))

    def draw(self, title, brief, previous=None, shows=None):
        asked = meeting_board.sketch_request(title, brief, '', previous=previous, shows=shows)
        yield self.ask(f"{meeting_board.SKETCH_SYSTEM}\n\n{asked['messages'][0]['content']}")


def load_model(root, ask):
    """The model from <root>/board-model.json, or Hermes's chat when there is none."""
    try:
        config = json.loads((Path(root) / 'board-model.json').read_text(encoding='utf-8'))
        key = Path(config['key_file']).expanduser().read_text(encoding='utf-8').strip()
        return Model(config['url'], key, config.get('edit_model') or EDIT_MODEL, config.get('new_model') or NEW_MODEL,
                     config.get('sketch_model') or SKETCH_MODEL)
    except (OSError, ValueError, KeyError, TypeError):
        return HermesModel(ask)


def switch(room, nav, boards, cmd):
    """Puts boards on screen as navigate() asked (one, two side by side, all of them) or renames one, with what it did in
    the status bar, in one message to the room; nothing waits on a model. Returns the run_command() result: kind 'show'
    for one board, 'view' for two or all, 'edit' for a new name (a change to the board, kept for the notes)."""
    if nav.get('error'):
        room.send({'t': 'caption', 'state': 'failed', 'detail': nav['error'][:200], 'cmd': cmd})
        raise ValueError(nav['error'])
    if nav.get('rename'):
        n = nav['rename']
        renamed = room.send({'t': 'op', 'n': n, 'op': {'op': 'title', 'text': nav['title']}, 'cmd': cmd},
                            {'t': 'caption', 'state': 'done', 'detail': nav['detail'][:200], 'cmd': cmd})[0]
        if not renamed.get('ok'):
            reason = str(renamed.get('error') or 'that name was refused').capitalize() + '.'
            room.send({'t': 'caption', 'state': 'failed', 'detail': reason[:200], 'cmd': cmd})
            raise ValueError(reason)
        return {'kind': 'edit', 'board': n, 'title': nav['title'], 'done': ['title'], 'refused': []}
    n = nav.get('show') or nav.get('n')
    msg = {'t': 'show', 'n': n, 'cmd': cmd}
    if nav.get('split'):
        msg['split'] = nav['split']
    elif nav.get('all'):
        msg['all'] = True
    shown = room.send(msg, {'t': 'caption', 'state': 'done', 'detail': nav['detail'][:200], 'cmd': cmd})[0]
    if not shown.get('ok'):
        reason = str(shown.get('error') or 'that could not be shown').capitalize() + '.'
        room.send({'t': 'caption', 'state': 'failed', 'detail': reason[:200], 'cmd': cmd})
        raise ValueError(reason)
    return {'kind': 'show' if nav.get('show') else 'view', 'board': n, 'title': boards[n - 1].get('title'),
            'done': [], 'refused': []}


def run_command(room, model, state, text, cmd=None, any_text=False, context=None, drawn=None, last=None):
    """Carry out one board command against the room as it is (`state`: its boards, the one on screen as `current` (of two
    side by side, the one the next change goes to), the one last on screen as `last`, how they are on screen as `view`,
    and those on screen lately as `recent`). Returns what happened: {'board': n, 'title', 'done': [edit names],
    'refused': [errors], 'kind', 'blocks': [ids of the blocks it changed]} (an undo also gives the boards it put back as
    'changed' and how many are left as 'count'; a recap its chat line as 'text') or None when it is not a board command
    (`any_text`: everything is, as for the owner's texts, but frustration with nothing asked never is). `context` is
    what the model is also told about the command, never shown on the board. `last` is what the change before this one
    did ({'board': n, 'blocks': [ids], 'text': its words}), so "that's not a circle" draws that again. A custom picture
    asked for is drawn on a thread of its own from the moment its block is up, and `drawn(n)` is called once it is on
    board n. Raises on a failure, after telling the board."""
    boards, current = state.get('boards') or [], state.get('current')
    # A change after "stop sharing" goes to the board last shown, and puts it back on screen.
    shown = current or state.get('last')
    view = state.get('view') or {'mode': 'one'}
    if meeting_board.frustrated(text):
        return None
    fixing = meeting_board.correction(text)
    found = meeting_board.intent(text, bool(boards)) or (('edit', None) if any_text else None)
    if not found:
        return None
    kind, number = found
    if kind in ('show', 'view'):
        # Which boards are on screen, by rule: the screen changes with no model and no "drawing" first.
        nav = meeting_board.navigate(text, boards, shown, view, state.get('recent') or ())
        if nav:
            return switch(room, nav, boards, cmd)
        if kind == 'show' and not boards:
            nav = {'error': 'There is no whiteboard in this call yet.'}
            return switch(room, nav, boards, cmd)
        # Not about the screen after all ("show how refunds work", "just add a risk"): what it is otherwise.
        found = meeting_board.intent(text, bool(boards), views=False) or (('edit', None) if any_text else None)
        if not found:
            return None
        kind, number = found
    if kind == 'undo':
        # The room puts the boards back and says so on screen itself; no model, so nothing to show meanwhile.
        undone = room.send({'t': 'undo', 'cmd': cmd})[0]
        if not undone.get('ok'):
            # Not a failure to tell the owner about: the board says so, and nothing changed.
            room.send({'t': 'caption', 'state': 'failed', 'detail': 'There is nothing to undo.', 'cmd': cmd})
            return {'kind': kind, 'board': None, 'changed': [], 'count': len(boards), 'done': [],
                    'refused': ['There is nothing to undo.']}
        return {'kind': kind, 'board': undone.get('current'), 'changed': undone.get('changed') or [],
                'count': int(undone.get('boards') or 0), 'done': ['undo'], 'refused': []}
    room.send({'t': 'caption', 'state': 'drawing', 'text': meeting_board.bare(text), 'cmd': cmd})
    try:
        if kind == 'stop':
            room.send({'t': 'stop', 'cmd': cmd}, {'t': 'caption', 'state': 'done', 'detail': 'Board taken off screen', 'cmd': cmd})
            return {'kind': kind, 'board': current, 'done': [], 'refused': []}
        if kind == 'show':
            n = number or shown or len(boards)
            if not n or not 1 <= n <= len(boards):
                raise ValueError(f'There is no whiteboard {n} in this call.' if n else 'There is no whiteboard in this call yet.')
            room.send({'t': 'show', 'n': n, 'cmd': cmd},
                      {'t': 'caption', 'state': 'done', 'detail': f'Board {n}: {boards[n - 1]["title"]}', 'cmd': cmd})
            return {'kind': kind, 'board': n, 'title': boards[n - 1]['title'], 'done': [], 'refused': []}
        if kind == 'recap':
            made = room.send({'t': 'recap', 'cmd': cmd})[0]
            if not made.get('ok'):
                raise ValueError((made.get('error') or 'no recap').capitalize() + '.')
            room.send({'t': 'caption', 'state': 'done', 'detail': 'Recap: action items, decisions and open risks', 'cmd': cmd})
            return {'kind': kind, 'board': made['n'], 'title': 'Recap', 'text': made.get('text') or '', 'done': ['recap'],
                    'refused': []}
        named = meeting_board.template(text, bool(boards)) if kind == 'new' else None
        # An empty board already there is used instead of a new tab, so asking again never leaves empty boards behind.
        spare = meeting_board.spare_board(boards, shown, text, named[0]['title'] if named else None) if kind == 'new' else None
        # Which board changed, said in the status bar when two are on screen.
        where = None
        if named:
            # A board by name is ready at once; the model adds only what the request asks for on top.
            board, more = named
            if spare:
                n = spare
                # Put on screen again, which also asks the call for the share again when it refused it before.
                msgs = [{'t': 'show', 'n': n, 'cmd': cmd}]
                if board['blocks'] or board['title'] != boards[n - 1].get('title'):
                    msgs.append({'t': 'set', 'n': n, 'board': board, 'cmd': cmd})
                refused_at = next((a for a in room.send(*msgs) if not a.get('ok')), None)
                if refused_at:
                    raise ValueError(refused_at.get('error') or 'the whiteboard could not be shown')
                if len(msgs) == 1 and not more:
                    room.send({'t': 'caption', 'state': 'done', 'detail': 'Ready: say “Hey Hermes, draw …”', 'cmd': cmd})
                    return {'kind': 'show', 'board': n, 'title': boards[n - 1].get('title'), 'done': [], 'refused': []}
            else:
                made = room.send({'t': 'new', 'board': board, 'cmd': cmd})[0]
                if not made.get('ok'):
                    raise ValueError(made.get('error') or 'no new board')
                n = made['n']
            base = board
            if not more:
                detail = f'Started “{board["title"]}”' + (
                    f': {", ".join(b["title"] for b in board["blocks"])}' if board['blocks'] else '')
                room.send({'t': 'caption', 'state': 'done', 'detail': detail[:200], 'cmd': cmd})
                return {'kind': 'new', 'board': n, 'title': board['title'], 'done': ['template'], 'refused': []}
            kind, started = 'edit', board['title']
        elif spare:
            room.send({'t': 'show', 'n': spare, 'cmd': cmd})
            n, base, kind, started = spare, boards[spare - 1], 'new', None
        elif kind == 'new' or not shown or shown > len(boards):
            made = room.send({'t': 'new', 'cmd': cmd})[0]
            if not made.get('ok'):
                raise ValueError(made.get('error') or 'no new board')
            n, base, kind, started = made['n'], json.loads(json.dumps(meeting_board.EMPTY)), 'new', None
        else:
            # A change goes to the board it names ("add a risk to the hiring board"), else to the one on screen (of two
            # side by side, the one changed last). "That's not a circle" goes to the board of the change it is about.
            # A board not on screen comes on screen, alone, to be changed there.
            n = meeting_board.board_for(text, boards, state.get('recent') or ()) or (
                last['board'] if fixing and last and 1 <= int(last.get('board') or 0) <= len(boards) else shown)
            base, started = boards[n - 1], None
            split = (view.get('boards') or []) if view.get('mode') == 'split' else []
            if n in split:
                where = meeting_board.board_name(base)
            elif n != current or view.get('mode') == 'all':
                room.send({'t': 'show', 'n': n, 'cmd': cmd})
        # The blocks the last change drew, when it was on this board and they are still there.
        ids = {b.get('id') for b in base.get('blocks') or []}
        before = [b for b in (last or {}).get('blocks') or [] if b in ids] if (last or {}).get('board') == n else []
        if fixing and before:
            about = f'(the change before this one was "{last.get("text") or ""}", which drew {", ".join(before)})'
            context = f'{context} {about}' if context else about
        done, said, refused, sketches, touched, title = [], [], [], [], [], base.get('title')
        # The blocks this command put up, with what has gone in them: a board by name's own, and each new one but a picture.
        added = {b['id']: json.loads(json.dumps(b)) for b in base.get('blocks') or [] if b.get('id')} if started else {}

        def put(name, given):
            """One edit to board n, as soon as the model has made it."""
            nonlocal title
            job = None
            if name == 'sketch':
                # The block goes up now, saying it is being drawn, and the picture is drawn from now on (draw_sketch).
                job = sketch_job(room, n, given, ask=text)
                name, given = 'block', job['op']
            result = room.send({'t': 'op', 'n': n, 'op': {**given, 'op': name}, 'cmd': cmd})[0]
            if result.get('ok') and job:
                sketches.append(job)
                threading.Thread(target=draw_sketch, args=(room.sibling(), model, job), kwargs={'cmd': cmd, 'drawn': drawn},
                                 daemon=True).start()
            block = given.get('block') if name == 'item' else given.get('id') if name == 'block' else None
            if result.get('ok') and block and block not in touched:
                touched.append(block)
            if result.get('ok') and name == 'block' and given.get('type', 'sketch') != 'sketch' and (
                    block not in ids or block in added):
                added.setdefault(block, {'items': []}).update({k: v for k, v in given.items() if k != 'after'})
            elif result.get('ok') and name == 'item' and block in added:
                added[block].setdefault('items', []).append({k: v for k, v in given.items() if k not in ('block', 'after')})
            if result.get('ok') and result.get('same'):
                # Sent again as it was: nothing to say.
                done.append(name)
            elif result.get('ok'):
                done.append(name)
                said.append({'what': str(result.get('what') or name), 'added': result.get('added'),
                             'block': result.get('block'), 'joined': result.get('joined')})
                if name == 'title':
                    title = given.get('text') or title
            else:
                refused.append(str(result.get('error') or 'refused'))

        for name, given in model.edits(base, f'{meeting_board.bare(text)} {context}' if context else text, kind):
            put(name, meeting_board.corners(given, text) if name == 'block' else given)
        # The fast model can stop once the block asked to see is up, before what goes in it ("draw a flow chart for
        # refunds" left an empty flow in 1 of 2 runs, 2026-11-22), or make no edit for "try again" about a block that is
        # no picture. Either way it is asked once more, saying which block. A picture is drawn again without it, below.
        name_of = lambda found: ', '.join(f'the {b.get("type")} “{b.get("title")}” (id {b.get("id")})' for b in found)
        empty = [b for b in added.values() if not b.get('items')]
        blocks = [b for b in base.get('blocks') or [] if isinstance(b, dict)]
        wrong = [b for b in blocks if b.get('id') in before] if before else blocks[-1:]
        wrong = [b for b in wrong if b.get('type') != 'sketch'] if fixing and not done else []
        why = (f'{name_of(empty)} is up but empty: add what goes in it now' if empty and meeting_board.visual_ask(text)
               else f'{name_of(wrong)} came out wrong: fix it now with block and item calls on its ids' if wrong else None)
        if why:
            now = {**base, 'title': title, 'blocks': [b for b in blocks if b.get('id') not in added] + list(added.values())}
            said_now = f'{meeting_board.bare(text)} {context}' if context else meeting_board.bare(text)
            for name, given in model.edits(now, f'{said_now} ({why}. Change nothing else.)', 'edit'):
                put(name, meeting_board.corners(given, text) if name == 'block' else given)
        if not done:
            # Asked to see something, or told the last picture is wrong, and the model drew nothing: a picture all the same.
            picture = fallback_picture(base, text, before, fixing)
            if picture:
                put('sketch', picture)
        if not done:
            raise ValueError(refused[0] if refused else 'Hermes found nothing to change. Say it again, like “Hey Hermes, add …”')
        if not title or title == meeting_board.EMPTY['title']:
            # A board is named for what it shows once it shows something: its first block's name.
            first = next((d['block'] for d in said if d.get('block')), None) or next(
                (b.get('title') for b in base.get('blocks') or [] if b.get('title')), None)
            named_now = meeting_board.words(first, 60)
            if named_now and room.send({'t': 'op', 'n': n, 'op': {'op': 'title', 'text': named_now}, 'cmd': cmd})[0].get('ok'):
                title = named_now
        detail = meeting_board.sentence(said, started=title if kind == 'new' or started else None, refused=len(refused))
        if where:
            detail = f'{detail} on {where}'
        room.send({'t': 'caption', 'state': 'done', 'detail': detail[:200], 'cmd': cmd})
        return {'kind': kind if not started else 'new', 'board': n, 'title': title, 'done': done, 'refused': refused,
                'sketches': [job['id'] for job in sketches], 'blocks': touched}
    except Exception as exc:
        try:
            room.send({'t': 'caption', 'state': 'failed', 'detail': str(exc)[:200], 'cmd': cmd})
        except RoomError:
            pass
        raise


def fallback_picture(board, text, before, fixing):
    """The custom picture to draw when the model made no edit for a command (a sketch call, or None). Tonight's call
    (2026-11-22) asked "draw a circle" and "can you show the visualization of Palestine and Israel?" and the model made
    neither, so the board said there was nothing to change. A request to draw something always gets a picture: the
    drawing model draws what was asked. "That's not a circle" draws the last picture again, or, on an empty board, what
    it says the picture should be. A request that names nothing to draw ("draw it") gets none."""
    blocks = [b for b in board.get('blocks') or [] if isinstance(b, dict)]
    said = meeting_board.bare(text)
    if fixing:
        # The picture the last change drew, or with no word of it (a Hermes that started over), the last on the board.
        redo = next((b for b in blocks if b.get('id') in before and b.get('type') == 'sketch'), None) if before else next(
            (b for b in reversed(blocks) if b.get('type') == 'sketch'), None)
        if redo:
            return {'id': redo['id'], 'brief': f'Said about this picture: "{said}". Draw it again so that it is right.'}
    what = meeting_board.subject(text)
    if not what or not (meeting_board.visual_ask(text) or fixing and not blocks):
        return None
    taken = {b.get('id') for b in blocks}
    stem = meeting_board.ident('-'.join(what.lower().split()[:3]))[:20] or 'picture'
    block_id = next(f'{stem}{n or ""}' for n in range(len(taken) + 2) if f'{stem}{n or ""}' not in taken)
    return {'id': block_id, 'title': ' '.join(what.split()[:4]), 'brief': f'{what}, as asked in the meeting: "{said}"'}


def sketch_job(room, n, given, ask=None):
    """A custom picture asked for on board n: the block op that puts it up as being drawn (or, for one already there,
    marks it as being drawn again), and what draw_sketch needs. A change to a picture is drawn from the picture as it is
    now, so the room is asked for it. A new picture the model gave no title is named for what was asked (`ask`)."""
    block_id = meeting_board.ident(given.get('id')) or 'sketch'
    brief = meeting_board.words(given.get('brief'), meeting_board.COMMAND_CHARS * 2)
    title = meeting_board.words(given.get('title'), 40)
    current = None
    for board in (room.state().get('boards') or [])[n - 1:n]:
        current = next((b for b in board.get('blocks') or [] if b.get('id') == block_id), None)
    nonce = secrets.token_hex(4)
    if current and current.get('type') == 'sketch':
        # What the block says it shows: what it was drawn from, then the change (the room keeps the last 400 characters).
        said = f"{current.get('brief') or ''} Then: {brief}".strip()
        op = {'id': block_id, 'brief': said[-400:], 'drawing': nonce, **({'title': title} if title else {})}
        return {'id': block_id, 'n': n, 'nonce': nonce, 'title': title or current.get('title') or 'Sketch', 'brief': brief,
                'previous': current.get('svg') or None, 'shows': current.get('brief') or None, 'op': op}
    title = title or meeting_board.words(meeting_board.subject(ask), 40) or 'Sketch'
    op = {'id': block_id, 'type': 'sketch', 'title': title, 'brief': brief, 'drawing': nonce,
          **({'after': given['after']} if given.get('after') else {})}
    return {'id': block_id, 'n': n, 'nonce': nonce, 'title': title, 'brief': brief, 'previous': None, 'op': op}


def draw_sketch(room, model, job, cmd=None, drawn=None, clock=time.monotonic):
    """Writes a custom picture into its block: a new one shown as it comes (its first part at once, then every
    SKETCH_EVERY_S), then whole; a change to
    one only whole, so the picture there stays up (marked as being redrawn) until the new one is ready, and stays if it
    fails. It stops at once when the picture was asked for again since (the room refuses an old drawing). On a failure
    the block says so. Returns 'drawn', 'replaced' or 'failed'."""
    def send(**fields):
        op = {'op': 'sketch', 'id': job['id'], 'drawing': job['nonce'], **fields}
        return room.send({'t': 'op', 'n': job['n'], 'op': op, 'cmd': cmd})[0]

    # Asked for again, undone or taken away since: this drawing is no longer wanted, and nothing is said.
    unwanted = lambda answer: not answer.get('ok') and any(
        words in str(answer.get('error')) for words in ('asked for again', 'there is no picture'))
    text, shown, last = [], None, None
    pieces = model.draw(job['title'], job['brief'], job['previous'], job.get('shows'))
    try:
        for piece in pieces:
            text.append(piece)
            # The first part goes up as soon as there is something to see, then the picture so far every SKETCH_EVERY_S.
            if job['previous'] or last is not None and clock() - last < SKETCH_EVERY_S:
                continue
            partial = meeting_board.svg_start(''.join(text))
            if partial and partial != shown and meeting_board.draws_something(partial):
                last = clock()
                if unwanted(send(svg=partial)):
                    return 'replaced'
                shown = partial
        svg = meeting_board.svg_of(''.join(text))
        if not svg:
            raise ValueError('no picture came back')
        answer = send(svg=svg, done=True)
        if unwanted(answer):
            return 'replaced'
        if not answer.get('ok'):
            raise ValueError(str(answer.get('error') or 'the picture was refused'))
        room.send({'t': 'caption', 'state': 'done', 'detail': f"Drew {job['title']}"[:200], 'cmd': cmd})
        if drawn:
            drawn(job['n'])
        return 'drawn'
    except Exception as exc:
        reason = str(exc) if isinstance(exc, (ValueError, RoomError)) else 'the model did not answer'
        try:
            send(failed=reason[:80])
            room.send({'t': 'caption', 'state': 'failed', 'detail': f"Hermes could not draw {job['title']}. Say it again.",
                       'cmd': cmd})
        except (RoomError, OSError):
            pass
        return 'failed'
    finally:
        close = getattr(pieces, 'close', None)
        if close:
            close()


class Brain:
    """One call's board, driven by its room's events. The meeting bot hands it what it needs from the rest of the mini:
    `store` (the bot records), `keep(n)` (export and keep board n), `say(text)` (a chat line, only with chat replies
    on; true when said), `lock()` (one board command at a time per call), `describe(exc)`, `now()` (aware datetime) and
    `sleep(s)`."""

    def __init__(self, store, bot_id, room, model, *, keep, say, lock, describe, now, sleep):
        self.store, self.bot_id, self.room, self.model = store, bot_id, room, model
        self.keep, self.say, self.lock, self.describe, self.now, self.sleep = keep, say, lock, describe, now, sleep
        self.export_lock = threading.Lock()
        # Boards people changed from the link, each waiting (a timer) to be kept.
        self.waiting = {}
        # The words of each recent command that changed a board, by its id: a phrase the bot took as carrying one on
        # ("due Friday", `continues`) goes with that command.
        self.changed = {}
        # What the last command that changed a board did (run_command's `last`), for "that's not a circle".
        self.last = None

    def record(self):
        with self.store.lock():
            return self.store.bot(self.bot_id)

    def update(self, **fields):
        with self.store.lock():
            record = self.store.bot(self.bot_id)
            if record:
                record.update(fields)
                self.store.put(record)
            return record

    def live(self):
        record = self.record()
        return bool(record and record['phase'] == 'in_call' and not record.get('cancel') and record.get('board_token'))

    def run(self):
        """Follow the room until the call is over."""
        failures = 0
        while self.live():
            try:
                for event in self.room.events(after=(self.record() or {}).get('room_seq', 0)):
                    failures = 0
                    if not self.live():
                        return self.done()
                    if event is not None:
                        self.receive(event)
            except (RoomError, OSError, http.client.HTTPException):
                pass
            self.sleep(WAITS[min(failures, len(WAITS) - 1)])
            failures += 1
        return self.done()

    def done(self):
        """The call is over and the bot's browser is closed. Boards still waiting to be kept are left to the filer, which
        keeps what the bot drew of them as it left."""
        for timer in self.waiting.values():
            timer.cancel()
        self.waiting = {}
        return 'call over'

    def receive(self, event):
        if event.get('t') == 'presenting':
            self.update(presenting=bool(event.get('on')), board_error=event.get('error'))
        if event.get('t') == 'board' and event.get('by') == 'person':
            self.keep_soon(int(event.get('n') or 0))
            return None
        if event.get('t') == 'undone' and event.get('by') == 'person':
            self.after_undo(event.get('changed') or [], len(event.get('boards') or []), soon=True)
            return None
        if event.get('t') == 'board' and event.get('recap') and event.get('auto'):
            # The bot is leaving the call and put up the recap: it goes into the notes, and in the chat with chat
            # replies on, while the bot is still there to say it.
            self.later(self.say, str(event.get('text') or ''))
            self.later(self.keep_board, int(event.get('n') or 0))
            return None
        if event.get('t') != 'command':
            return None
        seq = int(event.get('seq') or 0)
        record = self.record() or {}
        if seq <= int(record.get('room_seq') or 0):
            return None
        # The command counts as done here only once it is handled: a process that stops part way is sent it again when
        # it starts over. One the room marks `finished` was done before then; the room makes no second board for it.
        # (An error moves the cursor on too, so one command can never stop the process over and over.)
        try:
            if event.get('finished'):
                return None
            try:
                heard = datetime.fromisoformat(str(event.get('at')).replace('Z', '+00:00'))
                if self.now() - heard > STALE:
                    return self.missed(event)
            except ValueError:
                pass
            return self.handle(event)
        finally:
            self.update(room_seq=seq)

    def missed(self, event):
        """A board command too old to carry out now (the process was away): the board's caption says so, so nobody takes
        it for done."""
        text = str(event.get('text') or '')
        if event.get('source') == 'voice':
            text = meeting_board.spoken(text)
        if meeting_board.intent(text, True):
            try:
                self.room.send({'t': 'caption', 'state': 'failed', 'text': meeting_board.bare(text),
                                'detail': 'Missed while Hermes was away. Say it again.', 'cmd': event.get('id')})
            except RoomError:
                pass
        return None

    @staticmethod
    def said_to_board(event, text, has_board):
        """With a board up, anything said straight to Hermes is for the board unless it is a question (the owner gets
        those by text) or small talk: "Hey Hermes, our goal is …", "Hey Hermes, the beta is done". The model makes the change it
        asks for, or none, and the board says so ("Say it again"), so a misheard command is said again rather than taken
        for done (a rehearsal call heard "add a goal" as "Atagul" and the goal was lost without a word)."""
        command = meeting_board.POLITE.sub('', meeting_board.bare(text))
        asked = command.endswith('?') or meeting_board.QUESTION.match(command)
        return bool(event.get('source') == 'voice' and event.get('direct') and has_board and command and not asked
                    and not meeting_board.CHATTER.match(command))

    def handle(self, event):
        """One command from the room. Not every command is for the board; the tick answers questions."""
        text = str(event.get('text') or '')
        if event.get('source') == 'voice':
            text = meeting_board.spoken(text)
        record = self.record()
        if not record:
            return None
        # A command said while the last one was still being drawn came with the boards from before that change, and one
        # replayed after a reconnect comes with none: both start from the boards as they are now.
        stale = lambda: 'boards' not in event or max(
            self.room.seq, int((self.record() or {}).get('room_written') or 0)) > int(event.get('seq') or 0)
        carried = str(event.get('continues') or '')
        context = None
        if carried:
            # Said right after a command that changed a board, and carrying it on: it is not a command of its own (it has no
            # "Hermes" and may be no sentence), and it changes the item that command made, not a new one.
            before = self.changed.get(carried)
            if not before:
                return None
            context = f'(this goes with the change just made for "{before}": change that same item or board, add no new one)'
        else:
            if meeting_board.frustrated(text):
                # Frustration with nothing asked ("what the f---?"): nothing changes and nothing is said. The status bar,
                # which shows what the bot heard, goes back to what it showed before.
                if event.get('source') == 'voice':
                    try:
                        self.room.send({'t': 'caption', 'state': 'idle', 'cmd': event.get('id')})
                    except RoomError:
                        pass
                return None
            has_board = bool(event.get('boards') or record.get('boards') or stale())
            if not meeting_board.intent(text, has_board) and not self.said_to_board(event, text, has_board):
                return None
        # The bot's own chat lines (said by Hermes) are never commands.
        if event.get('source') == 'chat' and text in {m.get('text') for m in record.get('said') or []}:
            return None
        if int(record.get('board_commands') or 0) >= MAX_COMMANDS:
            return None
        self.update(board_commands=int(record.get('board_commands') or 0) + 1)
        if event.get('source') == 'voice':
            self.later(self.say, f'Got it: {meeting_board.bare(text)[:GOT_IT_CHARS]}')
        before = self.room.seq
        try:
            with self.lock():
                state = self.room.state() if stale() else event
                try:
                    result = run_command(self.room, self.model, state, text, cmd=event.get('id'), any_text=True,
                                         context=context, drawn=lambda n: self.later(self.keep_board, n), last=self.last)
                finally:
                    self.update(room_written=max(self.room.seq, int((self.record() or {}).get('room_written') or 0)))
        except Exception as exc:
            reason = str(exc) if isinstance(exc, (ValueError, RoomError)) else self.describe(exc)
            self.update(board_failed=reason.rstrip('.') + '.')
            self.say("Sorry, I couldn't change the whiteboard.")
            # Edits made before the failure stay on the board, so its picture is kept for the notes all the same. The
            # room is asked here, on the one thread that talks to it; only the export runs on its own.
            if self.room.seq > before:
                try:
                    n = self.room.state().get('last')
                except RoomError:
                    n = None
                if n:
                    self.later(self.keep_board, n)
            return None
        if result is None:
            return None
        if result['kind'] in ('new', 'edit') and not carried:
            self.changed[event.get('id')] = meeting_board.bare(text)[:200]
            for old in list(self.changed)[:-20]:
                del self.changed[old]
        if result['kind'] in ('new', 'edit') and result.get('blocks'):
            self.last = {'board': result['board'], 'blocks': result['blocks'], 'text': meeting_board.bare(text)[:200]}
        elif result['kind'] == 'undo':
            self.last = None
        if result['kind'] == 'stop':
            self.update(presenting=False)
        elif result['kind'] == 'undo':
            self.after_undo(result['changed'], result['count'])
        elif result.get('board'):
            if result['kind'] == 'recap' and result.get('text'):
                self.later(self.say, result['text'])
            # Putting a board on screen changes no board: nothing new to keep, and the shared screen is not asked to draw
            # a board for the notes while it is moving between boards.
            if result['kind'] not in ('show', 'view'):
                self.later(self.keep_board, result['board'])
            if not (self.record() or {}).get('board_link_posted'):
                self.later(self.post_link)
        return result

    def after_undo(self, changed, count, soon=False):
        """An undo put boards back: each is kept for the notes again, and a board it took away is no longer kept."""
        with self.store.lock():
            record = self.store.bot(self.bot_id)
            if record and any(int(b.get('n') or 0) > count for b in record.get('boards') or []):
                record['boards'] = [b for b in record['boards'] if int(b.get('n') or 0) <= count]
                record['board'] = record['boards'][-1]['n'] if record['boards'] else None
                self.store.put(record)
        for n in changed:
            if 1 <= int(n) <= count:
                if soon:
                    self.keep_soon(int(n))
                else:
                    self.later(self.keep_board, int(n))

    def later(self, work, *args):
        """Off the command path: a chat line or a board's export never holds up the next command."""
        threading.Thread(target=work, args=args, daemon=True).start()

    def after(self, seconds, work, *args):
        timer = threading.Timer(seconds, work, args)
        timer.daemon = True
        timer.start()
        return timer

    def keep_soon(self, n):
        """Someone changed board n from the link: it is kept once their changes stop for KEEP_AFTER_S."""
        if n < 1:
            return
        timer = self.waiting.pop(n, None)
        if timer:
            timer.cancel()
        self.waiting[n] = self.after(KEEP_AFTER_S, self.kept_after, n)

    def kept_after(self, n):
        self.waiting.pop(n, None)
        self.keep_board(n)

    def post_link(self):
        """The board link in the meeting chat, once per call, when chat replies are on."""
        record = self.record() or {}
        url = record.get('board_url')
        if url and not record.get('board_link_posted') and self.say(LINK_LINE + url):
            self.update(board_link_posted=True)
            # The link is the room's to know now, so the shared screen shows it too, as a short link and a QR code.
            try:
                self.room.sibling().send({'t': 'link'})
            except RoomError:
                pass

    def keep_board(self, n):
        """Board n's picture and file, kept for the notes. One at a time per call."""
        with self.export_lock:
            try:
                self.keep(n)
            except Exception as exc:
                self.update(board_failed=f'the board picture was not kept ({self.describe(exc)}).')
