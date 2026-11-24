"""The meeting whiteboard on the mini: which messages are board commands, how a streamed model reply becomes edits, and
the whiteboard process that carries out a call's board commands from its board room (each edit sent as the model
finishes it, captions, the picture and file kept, the boards filed with the notes). Against the fake bot service and a
stand-in model; no real model, no real call."""
import json
import shutil
import subprocess
import sys
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

import board_brain
import meeting_board
import meeting_bot
from lml_common import read_json
from test_meeting_bot import (KEYED, MINI, SID, START, Follow, answers, app, brains, calendar, clock, end_call,
                              fake_transcribe, ok, run, service, spawned, start_call, tick)

FIXTURES = (answers, app, brains, calendar, clock, service, spawned)  # pytest finds these by name


# Which messages are board commands.

@pytest.mark.parametrize('text, has_board, expected', [
    ('Hermes, start a whiteboard to plan the launch', False, ('new', None)),
    ('Hermes make a whiteboard', True, ('new', None)),
    ('@Hermes: new board for hiring', True, ('new', None)),
    ('Hermes, add a column for risks', False, ('edit', None)),
    ('Hermes, make this a timeline', True, ('edit', None)),
    ('Hermes, put "call Kim" on the board', False, ('edit', None)),
    ('Hermes, group these by owner', True, ('edit', None)),
    ('Hermes, could you please add Kim to owners', True, ('edit', None)),
    ('Hermes, stop sharing', True, ('stop', None)),
    ('Hermes, please stop presenting the board', True, ('stop', None)),
    ('Hermes, show board 2', True, ('show', 2)),
    ('Hermes, go back to the whiteboard', True, ('show', None)),
    # With a board up, decisions and owned action items said as statements, as the board's prompts ask.
    ('Hermes, we decided to launch on web first', True, ('edit', None)),
    ('Hermes, decided to launch on web first. And mobile in q two.', True, ('edit', None)),
    ("Hermes, we've agreed on two pilots", True, ('edit', None)),
    ('Hermes, Lee will send the deck by Friday', True, ('edit', None)),
    ("Hermes, Lee'll send the deck by Friday", True, ('edit', None)),
    ('Hermes, Lee owns the designer hire, due Friday', True, ('edit', None)),
    ('Hermes, the pricing page is due next Tuesday', True, ('edit', None)),
    # A change asked for with a verb after "also", "and", or after where it goes; a goal or a number said as a statement.
    ('Hermes, also add January to the chart', True, ('edit', None)),
    ('Hermes, chart signups: 120 in May, 180 in June', True, ('edit', None)),
    ('Hermes, compare Priya and Sam on craft', True, ('edit', None)),
    ('Hermes, our goal is ten paying pilots', True, ('edit', None)),
    ('Hermes, after support checks the order, add a decision: is it under fifty dollars?', True, ('edit', None)),
    ('Hermes, on the chart, add January at 340', True, ('edit', None)),
    # Not board commands: a question, a request with no board up yet, and the board named in a question.
    ('Hermes, what did we decide last week?', True, None),
    ('Hermes, group these by owner', False, None),
    ('Hermes, what is on the board?', True, None),
    ('Hermes, we decided to launch on web first', False, None),
    ('Hermes, who owns the designer hire?', True, None),
    ('Hermes, can we get this due Friday?', True, None),
    ('Hermes, Lee will be late', True, None),
    ('Hermes, when we launch, what happens?', True, None),
    ('Hermes, is it under fifty?', True, None),
    ('Hermes', True, None),
])
def test_which_messages_are_board_commands(text, has_board, expected):
    assert meeting_board.intent(text, has_board) == expected


# A model's reply as edits.

def sse(*events):
    return [line for event in events for line in (f'data: {json.dumps(event)}', '')]


def tool_call(index, name, given, pieces=2):
    text = json.dumps(given)
    step = max(1, len(text) // pieces + 1)
    return [{'type': 'content_block_start', 'index': index, 'content_block': {'type': 'tool_use', 'name': name, 'input': {}}},
            *({'type': 'content_block_delta', 'index': index, 'delta': {'type': 'input_json_delta',
                                                                        'partial_json': text[i:i + step]}}
              for i in range(0, len(text), step)),
            {'type': 'content_block_stop', 'index': index}]


def test_each_edit_comes_out_the_moment_its_tool_call_ends():
    lines = sse({'type': 'message_start'}, *tool_call(0, 'block', {'id': 'risks', 'type': 'list', 'title': 'Risks'}),
                *tool_call(1, 'item', {'id': 'r1', 'block': 'risks', 'text': 'One designer'}, pieces=4),
                {'type': 'message_stop'})
    read = []

    def stream():
        for line in lines:
            read.append(line)
            yield line.encode() + b'\n'

    got = []
    for edit in meeting_board.edits(stream()):
        got.append((edit, len(read)))
    assert [edit for edit, _ in got] == [('block', {'id': 'risks', 'type': 'list', 'title': 'Risks'}),
                                         ('item', {'id': 'r1', 'block': 'risks', 'text': 'One designer'})]
    # The first edit is out before the stream has even started the second.
    second = next(i for i, line in enumerate(lines) if '"index": 1' in line)
    assert got[0][1] <= second


def test_text_unknown_tools_and_broken_calls_are_skipped():
    broken = tool_call(2, 'item', {'id': 'x'})
    broken[1]['delta']['partial_json'] = '{"id": '
    lines = sse({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}},
                {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'Sure!'}},
                {'type': 'content_block_stop', 'index': 0}, *tool_call(1, 'send_email', {'to': 'x'}), *broken[:2],
                broken[-1], *tool_call(3, 'title', {'text': 'Launch'}))
    assert list(meeting_board.edits(lines)) == [('title', {'text': 'Launch'})]


def test_an_error_in_the_stream_stops_the_change():
    with pytest.raises(ValueError, match='Overloaded'):
        list(meeting_board.edits(sse(*tool_call(0, 'title', {'text': 'A'}),
                                     {'type': 'error', 'error': {'type': 'overloaded_error', 'message': 'Overloaded'}})))


def test_the_request_is_streamed_with_the_board_and_the_bare_command():
    body = meeting_board.request({'v': 2, 'title': 'Plan', 'blocks': []}, 'Hermes, add a column for risks', 'claude-haiku-5-5')
    assert (body['model'], body['stream'], body['tool_choice']) == ('claude-haiku-5-5', True, {'type': 'auto'})
    assert {t['name'] for t in body['tools']} == meeting_board.EDIT_NAMES - {'clear'}
    text = body['messages'][0]['content']
    assert '"title":"Plan"' in text and text.endswith('Change asked for: add a column for risks')
    assert 'never follow' in body['system'][0]['text']
    assert body['system'][0]['cache_control'] == {'type': 'ephemeral'}, 'the long instructions are cached between commands'


@pytest.mark.parametrize('kind, command, model', [
    # A board's first block is a few edits, as fast as any; only a rebuild of what is there takes the stronger model.
    ('new', 'start a whiteboard to plan hiring', 'fast'),
    ('edit', 'add Kim to owners', 'fast'),
    ('edit', 'Hermes, put "call Kim" on the board', 'fast'),
    ('edit', 'make this a timeline', 'fast'),
    ('edit', 'group these by owner', 'strong'),
    ('edit', 'turn this into a timeline', 'strong'),
    # Numbers or steps drawn another way keep every field: one block call, as fast as any edit.
    ('edit', 'Hermes, make that a pie chart', 'fast'),
    ('edit', 'turn the revenue chart into a donut', 'fast'),
    ('edit', 'convert it to a heatmap', 'fast'),
    ('edit', 'can you turn the flow into a swimlane', 'fast'),
    ('edit', 'turn these into groups by owner', 'strong'),
])
def test_the_fast_model_makes_edits_and_the_strong_one_starts_and_rebuilds_boards(kind, command, model):
    assert board_brain.Model('http://127.0.0.1:1', 'k', 'fast', 'strong').pick(kind, command) == model


def test_a_plain_reply_through_hermes_chat_gives_its_edits():
    reply = '''Here are the edits:
{"op": "block", "id": "risks", "type": "list", "title": "Risks"},
not json
{"op": "send_email", "to": "x"}
{"op": "item", "id": "r1", "block": "risks", "text": "One designer"}'''
    assert list(meeting_board.fallback_edits(reply)) == [('block', {'id': 'risks', 'type': 'list', 'title': 'Risks'}),
                                                         ('item', {'id': 'r1', 'block': 'risks', 'text': 'One designer'})]
    prompt = meeting_board.fallback_prompt(meeting_board.EMPTY, 'Hermes, start a board for hiring')
    assert prompt.endswith('Change asked for: start a board for hiring') and '- block:' in prompt and '- link:' in prompt


@pytest.mark.parametrize('done, started, refused, said', [
    ([], None, 0, 'No change'),
    ([{'what': 'Added “Hire a designer” to Action items, owner Lee', 'added': 'Action items'}], None, 0,
     'Added “Hire a designer” to Action items, owner Lee'),
    ([{'what': 'x', 'added': 'Risks'}, {'what': 'y', 'added': 'Risks'}, {'what': 'z', 'added': 'Goals'}], None, 1,
     'Added 2 items to Risks and 1 to Goals (1 skipped)'),
    # A few changes each say what they did.
    ([{'what': 'Named the board “Plan”'}, {'what': 'Removed “Old”'}], None, 0, 'Named the board “Plan”; removed “Old”'),
    ([{'what': 'Changed “Craft”: Priya 5'}, {'what': 'Changed “Speed”: Priya 4'}, {'what': 'Changed “Team fit”: Priya 4'}], None,
     0, 'Changed “Craft”: Priya 5; changed “Speed”: Priya 4; changed “Team fit”: Priya 4'),
    # A new block with what went in it, beside another change.
    ([{'what': 'Picked “Priya” in Candidates'}, {'what': 'Added the list “Decisions”', 'block': 'Decisions'},
      {'what': 'Added “Offer Priya” to Decisions', 'added': 'Decisions'}], None, 0,
     'Picked “Priya” in Candidates; added the list “Decisions” with 1 item'),
    ([{'what': 'Added the timeline “Plan”', 'block': 'Plan'}] + [{'what': 'x', 'added': 'Plan'}] * 3, None, 0,
     'Added the timeline “Plan” with 3 items'),
    # Arrows go with the steps they join; an arrow alone says itself.
    ([{'what': 'Joined “Kit” to “Email”', 'joined': 'To do'}], None, 0, 'Joined “Kit” to “Email”'),
    ([{'what': 'Added “Kit” to To do', 'added': 'To do'}, {'what': 'Added “Email” to To do', 'added': 'To do'},
      {'what': 'Joined “Kit” to “Email”', 'joined': 'To do'}], None, 0, 'Added 2 items to To do, and 1 arrow'),
    ([{'what': 'Added “Manager approves” to Refunds', 'added': 'Refunds'}] + [{'what': 'j', 'joined': 'Refunds'}] * 3, None, 0,
     'Added “Manager approves” to Refunds, and 3 arrows'),
    # Too much for the status bar: the change that says the most, and how many more.
    ([{'what': f'Changed “A long item name number {i}”'} for i in range(4)], None, 0,
     'Changed “A long item name number 0”, and 3 more changes'),
    ([{'what': 't'}, {'what': 's', 'block': 'Goals'}, {'what': 's', 'block': 'Risks'}, {'what': 'n', 'added': 'Goals'}],
     'Q1 launch', 0, 'Started “Q1 launch”: 2 blocks, 1 item'),
])
def test_the_status_bar_says_what_changed_in_words(done, started, refused, said):
    assert meeting_board.sentence(done, started=started, refused=refused) == said


def test_every_kind_of_block_reads_in_the_notes_the_way_it_looks():
    board = {'v': 2, 'title': 'Refunds', 'blocks': [
        {'id': 'f', 'type': 'flow', 'title': 'Refund process', 'items': [
            {'id': 'a', 'text': 'Customer asks', 'shape': 'start'}, {'id': 'b', 'text': 'Under $50?', 'shape': 'decision'},
            {'id': 'c', 'text': 'Manager approves'}, {'id': 'd', 'text': 'Finance pays'}],
         'links': [{'from': 'b', 'to': 'c', 'label': 'No'}, {'from': 'b', 'to': 'd', 'label': 'Yes'}]},
        {'id': 't', 'type': 'timeline', 'title': 'Plan', 'items': [{'id': 'm', 'text': 'Beta', 'when': 'Jan 15', 'status': 'done'},
                                                                    {'id': 'n', 'text': 'Launch', 'when': 'Mar 3'}]},
        {'id': 'c', 'type': 'chart', 'title': 'Signups', 'unit': 'signups',
         'items': [{'id': 'o', 'text': 'October', 'value': 120}, {'id': 'p', 'text': 'November', 'value': 180}]},
        {'id': 'tb', 'type': 'table', 'title': 'Candidates', 'columns': [{'id': 'pr', 'name': 'Priya'}, {'id': 'sa', 'name': 'Sam'}],
         'pick': 'pr', 'items': [{'id': 'cr', 'text': 'Craft', 'cells': {'pr': 5, 'sa': 3}}]},
        {'id': 'x', 'type': 'matrix', 'title': 'Fixes', 'x': {'low': 'Low effort', 'high': 'High effort'},
         'y': {'low': 'Low impact', 'high': 'High impact'}, 'quadrants': {'tl': 'Quick wins'},
         'items': [{'id': 'q', 'text': 'Auto-approve', 'quadrant': 'tl'}]},
        {'id': 's', 'type': 'stats', 'title': 'Numbers',
         'items': [{'id': 'k', 'text': 'Refunds last month', 'value': '340', 'note': 'up from 290', 'trend': 'up'}]},
        {'id': 'mm', 'type': 'mindmap', 'title': 'Ideas', 'items': [{'id': 'p1', 'text': 'Pricing'},
                                                                     {'id': 'p2', 'text': 'Annual plan', 'parent': 'p1'}]},
        {'id': 'a', 'type': 'list', 'title': 'Action items', 'kind': 'actions',
         'items': [{'id': 'h', 'text': 'Call references', 'owner': 'Jordan', 'due': 'Thu Nov 26'}]},
        {'id': 'dd', 'type': 'list', 'title': 'Decisions', 'kind': 'decisions', 'items': [{'id': 'o1', 'text': 'Offer Priya'}]},
        {'id': 'empty', 'type': 'list', 'title': 'Risks', 'kind': 'risks', 'items': []}]}
    assert meeting_board.board_text(board) == {
        'markdown': '**Refund process**\n1. Customer asks (start)\n2. Under $50? (decision)\n3. Manager approves\n'
                    '4. Finance pays\n- Under $50? → Manager approves (No)\n- Under $50? → Finance pays (Yes)\n\n'
                    '**Plan**\n- Jan 15: Beta (done)\n- Mar 3: Launch\n\n'
                    '**Signups**\n- October: 120 signups\n- November: 180 signups\n\n'
                    '**Candidates**\n- Craft: Priya 5/5, Sam 3/5\n- Total: Priya 5, Sam 3\n- Picked: Priya\n\n'
                    '**Fixes**\n- Quick wins: Auto-approve\n\n'
                    '**Numbers**\n- Refunds last month: 340 (up from 290, up)\n\n'
                    '**Ideas**\n- Pricing\n  - Annual plan\n\n'
                    '**Action items**\n- Call references: Jordan, due Thu Nov 26\n\n'
                    '**Decisions**\n- Offer Priya',
        'actions': [{'text': 'Call references', 'owner': 'Jordan', 'due': 'Thu Nov 26'}],
        'decisions': ['Candidates: Priya', 'Offer Priya']}


@pytest.mark.parametrize('axes, said, corners', [
    # The model named the top left "Big bets" for high impact and low effort: put right by place.
    ((('Low effort', 'High effort'), ('Low impact', 'High impact')), 'a two by two of impact and effort',
     {'tl': 'Quick wins', 'tr': 'Big bets', 'bl': 'Fill-ins', 'br': 'Time sinks'}),
    # Impact across and effort up: the corners follow.
    ((('Low impact', 'High impact'), ('Low effort', 'High effort')), 'impact across, effort up',
     {'tl': 'Time sinks', 'tr': 'Big bets', 'bl': 'Fill-ins', 'br': 'Quick wins'}),
    # Names the speaker gave, and axes that are not impact and effort, stay as the model gave them.
    ((('Low effort', 'High effort'), ('Low impact', 'High impact')), 'call the top left big bets',
     {'tl': 'Big bets', 'tr': 'Major projects', 'bl': 'Fill-ins', 'br': 'Time sinks'}),
    ((('Cheap', 'Pricey'), ('Slow', 'Fast')), 'vendors by price and speed',
     {'tl': 'Big bets', 'tr': 'Major projects', 'bl': 'Fill-ins', 'br': 'Time sinks'}),
])
def test_an_impact_and_effort_2x2_names_its_corners_by_where_they_are(axes, said, corners):
    (x_low, x_high), (y_low, y_high) = axes
    op = {'id': 'm', 'type': 'matrix', 'x': {'low': x_low, 'high': x_high}, 'y': {'low': y_low, 'high': y_high},
          'quadrants': {'tl': 'Big bets', 'tr': 'Major projects', 'bl': 'Fill-ins', 'br': 'Time sinks'}}
    assert meeting_board.corners(op, said)['quadrants'] == corners
    assert meeting_board.corners({'id': 'm', 'title': 'Fixes'}, said) == {'id': 'm', 'title': 'Fixes'}


def test_a_board_as_text_for_the_notes_with_its_action_items_and_decisions():
    board = {'title': 'Q1 launch', 'layout': 'columns', 'arrows': [], 'sections': [
        {'id': 'goals', 'title': 'Goals', 'kind': 'goals', 'notes': [{'id': 'g1', 'text': '10 paying pilots'}]},
        {'id': 'risks', 'title': 'Risks', 'kind': 'risks', 'notes': [{'id': 'r1', 'text': 'Only one designer', 'level': 'high'}]},
        {'id': 'empty', 'title': 'Pros', 'kind': 'pros', 'notes': []},
        {'id': 'actions', 'title': 'Action items', 'kind': 'actions', 'notes': [
            {'id': 'a1', 'text': 'Hire a  contract designer', 'owner': 'Lee', 'due': 'Fri Dec 5'},
            {'id': 'a2', 'text': 'Book Stripe review #task'}]},
        {'id': 'decisions', 'title': 'Decisions', 'kind': 'decisions', 'notes': [{'id': 'd1', 'text': 'Web first'}]}]}
    assert meeting_board.board_text(board) == {
        'markdown': '**Goals**\n- 10 paying pilots\n\n**Risks**\n- Only one designer (high risk)\n\n**Action items**\n'
                    '- Hire a contract designer: Lee, due Fri Dec 5\n- Book Stripe review \\#task: no owner\n\n'
                    '**Decisions**\n- Web first',
        'actions': [{'text': 'Hire a contract designer', 'owner': 'Lee', 'due': 'Fri Dec 5'},
                    {'text': 'Book Stripe review #task', 'owner': None, 'due': None}],
        'decisions': ['Web first']}


def test_a_flow_as_text_lists_its_arrows():
    board = {'title': 'Signup', 'layout': 'flow', 'sections': [
        {'id': 's1', 'title': 'Sign up', 'kind': 'notes', 'notes': [{'id': 'n1', 'text': 'Email'}]},
        {'id': 's2', 'title': 'Pay', 'kind': 'notes', 'notes': [{'id': 'n2', 'text': 'Card'}]}],
        'arrows': [{'from': 's1', 'to': 's2', 'label': 'then'}, {'from': 'gone', 'to': 's2'}]}
    assert meeting_board.board_text(board)['markdown'] == ('**Sign up**\n- Email\n\n**Pay**\n- Card\n\n**Arrows**\n'
                                                           '- Sign up → Pay (then)')
    assert meeting_board.board_text(None) == {'markdown': '', 'actions': [], 'decisions': []}


def test_the_recaps_more_row_is_not_an_action_item():
    board = {'title': 'Recap', 'layout': 'columns', 'recap': True, 'arrows': [], 'sections': [
        {'id': 'actions', 'title': 'Action items', 'kind': 'actions', 'notes': [
            {'id': 'a1', 'text': 'Hire a designer', 'owner': 'Lee'}, {'id': 'actionsmore', 'text': '+2 more on the boards'}]},
        {'id': 'decisions', 'title': 'Decisions', 'kind': 'decisions', 'notes': [
            {'id': 'decisionsmore', 'text': '+1 more on the boards'}]}]}
    assert meeting_board.board_text(board) == {
        'markdown': '**Action items**\n- Hire a designer: Lee\n- +2 more on the boards\n\n**Decisions**\n- +1 more on the boards',
        'actions': [{'text': 'Hire a designer', 'owner': 'Lee', 'due': None}], 'decisions': []}


@pytest.mark.parametrize('text, expected', [
    ('Hermes, undo', ('undo', None)), ('Hermes, no, not that', ('undo', None)), ('Hermes, undo that please', ('undo', None)),
    ('Hermes, scratch that.', ('undo', None)), ('Hermes, recap', ('recap', None)), ("Hermes, let's wrap up", ('recap', None)),
    ('Hermes, give us a recap of the call', ('recap', None)), ('Hermes, start a retro', ('new', None)),
    ('Hermes, make a decision log', ('new', None)), ('Hermes, start an agenda for Monday', ('new', None)),
    # Not undo or recap: these say more, and go to the model as changes or to Hermes as questions.
    ('Hermes, undo the pricing section and add hiring', ('edit', None)), ('Hermes, what was the recap?', None),
])
def test_undo_recap_and_named_boards_are_board_commands(text, expected):
    assert meeting_board.intent(text, True) == expected


@pytest.mark.parametrize('text, title, blocks, more', [
    # A plain whiteboard starts empty: what is said first decides its first block.
    ('Hermes, start a whiteboard', 'Whiteboard', [], False),
    ('Hermes, new board.', 'Whiteboard', [], False),
    ('Hermes, start a whiteboard for the design hire', 'Design hire', [], False),
    ('Hermes, start a meeting board for Q1 launch', 'Q1 launch', [], False),
    ('Hermes, start a blank whiteboard', 'Whiteboard', [], False),
    # A board asked for by its kind is shaped at once.
    ('Hermes, start a retro for the launch', 'Launch retro', ['Went well', "Didn't go well", 'Ideas'], False),
    ('Hermes, can you make a decision log', 'Decision log', ['Decisions'], False),
    ('Hermes, open a pros and cons board for hiring', 'Hiring pros and cons', ['Pros', 'Cons'], False),
    ('Hermes, start an agenda with pricing, hiring and launch', 'Agenda', ['Agenda'], True),
    ('Hermes, make an action items list', 'Action items', ['Action items'], False),
    ('Hermes, start a timeline', 'Timeline', ['Timeline'], False),
    ('Hermes, make a mind map of pricing ideas', 'Pricing ideas', ['Pricing ideas'], False),
])
def test_a_board_by_name_is_ready_with_no_model(text, title, blocks, more):
    board, extra = meeting_board.template(text)
    assert board['v'] == 2
    assert (board['title'], [b['title'] for b in board['blocks']], extra) == (title, blocks, more)
    assert meeting_board.template('Hermes, start a whiteboard to plan the launch') is None
    assert meeting_board.template('Hermes, start a timeline')[0]['blocks'][0]['type'] == 'timeline'


# Moving between boards: by rule, with no model, so the screen changes at once.

def four_boards():
    block = lambda i, title: {'id': f'b{i}', 'type': 'list', 'title': title, 'kind': 'notes', 'items': []}
    return [{'v': 2, 'title': 'Q1 launch', 'blocks': [block(1, 'Goals'), block(2, 'Launch plan')]},
            {'v': 2, 'title': 'Pricing', 'blocks': [block(3, 'Plans'), block(4, 'Open questions')]},
            {'v': 2, 'title': 'Design hire', 'blocks': [block(5, 'Candidates'), block(6, 'Risks')]},
            {'v': 2, 'title': 'Whiteboard', 'blocks': [block(7, 'Open questions')]}]


@pytest.mark.parametrize('text, expected', [
    # A board by its name, however loosely; one named by its first block until it has a title of its own.
    ('Hermes, show the hiring board', {'show': 3, 'detail': 'Showing Design hire'}),
    ('Hermes, go back to pricing', {'show': 2, 'detail': 'Showing Pricing'}),
    ('Hermes, the launch one.', {'show': 1, 'detail': 'Showing Q1 launch'}),
    ("Hermes, let's look at the launch plan", {'show': 1, 'detail': 'Showing Q1 launch'}),
    ('Hermes, show the questions board', {'show': 4, 'detail': 'Showing Open questions'}),
    # Not quite a name: the closest board, and the status bar says so.
    ('Hermes, show the risks', {'show': 3, 'detail': 'Showing Design hire, the closest to “risks”'}),
    ('Hermes, show the prizing board.', {'show': 2, 'detail': 'Showing Pricing, the closest to “prizing”'}),
    # By number or place, next and previous.
    ('Hermes, show board 2', {'show': 2, 'detail': 'Showing Pricing'}),
    ('Hermes, the fourth board', {'show': 4, 'detail': 'Showing Open questions'}),
    ('Hermes, show the last board', {'show': 4, 'detail': 'Showing Open questions'}),
    ('Hermes, next board', {'show': 2, 'detail': 'Showing Pricing'}),
    ('Hermes, previous one', {'error': 'Q1 launch is the first board.'}),
    # Every board at once, two side by side, and back to one.
    ('Hermes, show all boards', {'all': True, 'n': 1, 'detail': 'Showing all 4 boards. Say a name to open one'}),
    ('Hermes, overview', {'all': True, 'n': 1, 'detail': 'Showing all 4 boards. Say a name to open one'}),
    ('Hermes, put the launch board and the hiring board side by side',
     {'split': [1, 3], 'n': 1, 'detail': 'Showing Q1 launch and Design hire side by side'}),
    ('Hermes, split view with pricing', {'split': [1, 2], 'n': 1, 'detail': 'Showing Q1 launch and Pricing side by side'}),
    ('Hermes, side by side', {'split': [1, 2], 'n': 1, 'detail': 'Showing Q1 launch and Pricing side by side'}),
    ('Hermes, put launch, pricing and hiring side by side',
     {'split': [1, 2], 'n': 1, 'detail': 'Showing Q1 launch and Pricing side by side (two fit at once)'}),
    ('Hermes, just the hiring board', {'show': 3, 'detail': 'Showing Design hire'}),
    ('Hermes, close the split view', {'show': 1, 'detail': 'Showing Q1 launch'}),
    # A new name, for this board or another.
    ('Hermes, call this board Pricing v2', {'rename': 1, 'title': 'Pricing v2', 'detail': 'Named the board “Pricing v2”'}),
    ('Hermes, rename the hiring board to design hire Q1',
     {'rename': 3, 'title': 'Design hire Q1', 'detail': 'Named the board “Design hire Q1”'}),
    # Asked for and not there: said so, with the names there are.
    ('Hermes, show the marketing board',
     {'error': 'No board is called “marketing”. Say one of: Q1 launch, Pricing, Design hire, Open questions.'}),
    ('Hermes, show board 7', {'error': 'There is no whiteboard 7 in this call.'}),
    # Not about which board is on screen: a change, a new board, a question.
    ('Hermes, show how refunds work', None),
    ('Hermes, add a risk to the hiring board', None),
    ('Hermes, start a new board for marketing', None),
])
def test_boards_are_shown_by_name_number_or_place_alone_side_by_side_or_all_at_once(text, expected):
    assert meeting_board.navigate(text, four_boards(), current=1, view={'mode': 'one'}, recent=[1, 2]) == expected
    if expected:
        assert meeting_board.intent(text, True)[0] in ('show', 'view')


def test_side_by_side_with_no_board_named_puts_the_one_on_screen_beside_the_one_before():
    boards = four_boards()
    assert meeting_board.navigate('Hermes, split the screen', boards, current=3, recent=[3, 1])['split'] == [3, 1]
    assert meeting_board.navigate('Hermes, side by side with the launch board', boards, current=3, recent=[3])['split'] == [3, 1]
    assert meeting_board.navigate('Hermes, side by side', boards[:1], current=1) == {
        'error': 'There is only one board. Start another to see two side by side.'}
    assert meeting_board.navigate('Hermes, next board', boards, current=4) == {'error': 'Open questions is the last board.'}


def test_a_change_that_names_a_board_goes_to_that_board():
    boards = four_boards()
    assert meeting_board.board_for('Hermes, add a risk to the hiring board: Priya starts in April', boards) == 3
    assert meeting_board.board_for('Hermes, on board 2, add annual pricing', boards) == 2
    assert meeting_board.board_for('Hermes, add a risk', boards) is None
    assert meeting_board.board_for('Hermes, add a new board for marketing', boards) is None
    assert meeting_board.board_for('Hermes, add a step to board 9', boards) is None
    assert [meeting_board.board_name(b) for b in boards] == ['Q1 launch', 'Pricing', 'Design hire', 'Open questions']


def test_the_model_is_taught_the_kinds_and_told_the_date():
    body = meeting_board.request(meeting_board.EMPTY, 'Hermes, Lee owns the designer hire, due Friday', 'fast',
                                 today=datetime(2026, 11, 20, 15, tzinfo=timezone.utc))
    assert body['messages'][0]['content'].startswith('Today is Friday, November 20, 2026.')
    tools = {t['name']: t['input_schema'] for t in body['tools']}
    assert set(tools['item']['properties']) >= {'owner', 'due', 'level', 'value', 'cells', 'quadrant', 'parent'}
    assert set(tools['block']['properties']['type']['enum']) == set(meeting_board.TYPES)
    assert 'never guessed' in body['system'][0]['text']


def test_the_model_comes_from_board_model_json_or_else_hermes_chat(tmp_path):
    asked = []
    fallback = board_brain.load_model(tmp_path, lambda text: asked.append(text) or '{"op": "title", "text": "Hiring"}')
    assert isinstance(fallback, board_brain.HermesModel)
    assert list(fallback.edits(meeting_board.EMPTY, 'retitle the board Hiring', 'edit')) == [('title', {'text': 'Hiring'})]
    assert len(asked) == 1
    (tmp_path / 'key').write_text('gateway-key\n')
    (tmp_path / 'board-model.json').write_text(json.dumps({'url': 'http://127.0.0.1:8317', 'key_file': str(tmp_path / 'key'),
                                                          'edit_model': 'fast'}))
    model = board_brain.load_model(tmp_path, asked.append)
    assert (model.key, model.edit_model, model.new_model) == ('gateway-key', 'fast', board_brain.NEW_MODEL)


def test_the_model_is_streamed_from_the_messages_api():
    seen = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            seen.append((self.path, self.headers['x-api-key'], body['model'], body['stream']))
            raw = '\n'.join(sse(*tool_call(0, 'title', {'text': 'Hiring'}),
                                *tool_call(1, 'block', {'id': 'roles', 'type': 'list', 'title': 'Roles'}))) + '\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(raw.encode())))
            self.end_headers()
            self.wfile.write(raw.encode())

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True).start()
    try:
        model = board_brain.Model(f'http://127.0.0.1:{server.server_port}', 'gateway-key', 'fast', 'strong')
        assert list(model.edits(meeting_board.EMPTY, 'group the board by owner', 'edit')) == [
            ('title', {'text': 'Hiring'}), ('block', {'id': 'roles', 'type': 'list', 'title': 'Roles'})]
    finally:
        server.shutdown()
    assert seen == [('/v1/messages', 'gateway-key', 'strong', True)]


# The call's whiteboard process.

class Scribe:
    """Stands in for the model: records each (board title, command, kind) and makes a few edits like a model would."""

    def __init__(self):
        self.asked, self.error, self.plan = [], None, None

    def edits(self, board, command, kind):
        command = meeting_board.bare(command)
        self.asked.append((board['title'], command, kind))
        if self.error:
            raise self.error
        if self.plan is not None:
            yield from self.plan
            return
        if kind == 'new':
            yield 'title', {'text': command.split(' plan ', 1)[-1] if ' plan ' in command else 'Whiteboard'}
        if not any(b['id'] == 'ideas' for b in board['blocks']) or kind == 'new':
            yield 'block', {'id': 'ideas', 'type': 'list', 'title': 'Ideas'}
        yield 'item', {'id': f'n{len(self.asked)}', 'block': 'ideas', 'text': command[:80]}


@pytest.fixture
def scribe(app):
    stand_in = Scribe()
    app.model = lambda root: stand_in
    return stand_in


def brain_of(app, bot_id):
    brain = meeting_bot.make_brain(app, bot_id)
    brain.later = lambda work, *args: work(*args)
    return brain


def heard(service, clock, bot_id, text, **kwargs):
    """A command the bot heard just now, as the room sends it to the whiteboard process."""
    at = clock().astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
    return service.hear(bot_id, text, at=at, **kwargs)


def picture(app, bot_id, n):
    return (app.store.root / 'boards' / bot_id / f'board-{n}.png').read_bytes()


def sent(service, bot_id):
    """What the whiteboard process sent the room: captions as their state, edits as their name."""
    return [m['state'] if m['t'] == 'caption' else m['op']['op'] if m['t'] == 'op' else m['t']
            for m in service.room_of(bot_id)['msgs']]


def test_the_tick_starts_the_calls_whiteboard_process_and_restarts_it_if_it_stops(app, service, clock, brains):
    bot_id = start_call(app, service, clock)
    assert brains == [bot_id]
    clock.to(clock() + timedelta(seconds=10))
    tick(app)
    assert brains == [bot_id]
    lock = app.store.root / 'locks' / f'brain-{bot_id}.lock'
    with meeting_bot.try_lock(lock) as got:
        assert got
        clock.to(clock() + timedelta(minutes=1))
        tick(app)
        assert brains == [bot_id]
    tick(app)
    assert brains == [bot_id, bot_id]


def test_a_spoken_command_is_drawn_edit_by_edit_and_kept_with_chat_replies_off(app, service, clock, scribe, answers):
    bot_id = start_call(app, service, clock)
    event = heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch')
    result = brain_of(app, bot_id).receive(event)
    assert (result['kind'], result['board'], result['done']) == ('new', 1, ['title', 'block', 'item'])
    assert scribe.asked == [('Whiteboard', 'start a whiteboard to plan the launch', 'new')]
    assert sent(service, bot_id) == ['drawing', 'new', 'title', 'block', 'item', 'done']
    msgs = service.room_of(bot_id)['msgs']
    assert msgs[0]['text'] == 'start a whiteboard to plan the launch' and msgs[-1]['detail'] == 'Started “the launch”: 1 block, 1 item'
    assert {m['cmd'] for m in msgs} == {event['id']}
    assert picture(app, bot_id, 1) == b'PNG the launch'
    record = app.store.bot(bot_id)
    assert (record['board'], record['boards'][0]['title'], record['board_commands'], record['room_seq']) == (
        1, 'the launch', 1, event['seq'])
    # Nobody gets a chat line or a text.
    assert service.bots[bot_id]['posted'] == [] and answers.questions == []


def test_the_next_command_edits_the_board_on_screen(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, add the press kit', source='chat', sender='Lee'))
    assert scribe.asked[1] == ('the launch', 'add the press kit', 'edit')
    board = service.room_of(bot_id)['boards']
    assert len(board) == 1 and [n['text'] for n in board[0]['blocks'][0]['items']] == [
        'start a whiteboard to plan the launch', 'add the press kit']


def test_a_command_said_while_the_last_was_drawn_starts_from_the_newer_board(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    first = heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch')
    second = heard(service, clock, bot_id, 'Hermes, add the press kit')
    assert second['boards'] == []
    brain.receive(first)
    brain.receive(second)
    assert scribe.asked[1] == ('the launch', 'add the press kit', 'edit')
    assert len(service.room_of(bot_id)['boards']) == 1


def test_a_command_replayed_after_a_reconnect_starts_from_the_boards_as_they_are(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain_of(app, bot_id).receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    replayed = heard(service, clock, bot_id, 'Hermes, add the press kit')
    for key in ('boards', 'current', 'last'):
        del replayed[key]
    brain_of(app, bot_id).receive(replayed)
    assert scribe.asked[1] == ('the launch', 'add the press kit', 'edit')
    assert len(service.room_of(bot_id)['boards']) == 1


def test_a_change_after_stop_sharing_goes_to_the_last_board_and_shows_it_again(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, stop sharing the board'))
    room = service.room_of(bot_id)
    assert (room['current'], room['presenting'], app.store.bot(bot_id)['presenting']) == (None, False, False)
    brain.receive(heard(service, clock, bot_id, 'Hermes, add Kim to the board'))
    assert (room['current'], room['presenting'], len(room['boards'])) == (1, True, 1)
    assert sent(service, bot_id)[-4:] == ['drawing', 'show', 'item', 'done']


def test_a_spoken_add_heard_as_at_is_still_a_change_to_the_board(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan hiring'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, at a risk. We only have one designer.'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, at a high level, what is left?'))
    assert [a[1:] for a in scribe.asked] == [('start a whiteboard to plan hiring', 'new'), ('add a risk. We only have one designer.', 'edit')]


def test_a_spoken_add_a_goal_run_together_into_one_word_is_still_a_change_to_the_board(app, service, clock, scribe):
    # How speech-to-text heard "Hermes, add a goal: ten paying pilots by the end of March." in a rehearsal call
    # (2026-11-21); the goal never reached the board.
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a meeting board for the Q one launch.'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, Atagul, 10 paying pilots by the end of March.'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, Adarisk: one designer.'))
    assert [a[1:] for a in scribe.asked] == [('add a goal, 10 paying pilots by the end of March.', 'edit'),
                                             ('add a risk: one designer.', 'edit')]


def test_a_spoken_command_that_starts_with_the_kind_of_item_adds_one(app, service, clock, scribe):
    # How speech-to-text heard "Hermes, add a high risk: we only have one designer, and she is booked through January."
    # in a rehearsal call (2026-11-21); the board said it was no change it knew.
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a meeting board for the Q one launch.'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, High risk. We only have one designer. And she is booked through January.'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, action item: Lee will hire a contract designer.'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, risks? Which risks do we have?'))
    assert [a[1:] for a in scribe.asked][:2] == [
        ('add a high risk. We only have one designer. And she is booked through January.', 'edit'),
        ('add an action item: Lee will hire a contract designer.', 'edit')]
    assert meeting_board.spoken('Hermes, risks are fine for now.') == 'Hermes, risks are fine for now.'
    assert meeting_board.spoken('Hermes, a note: ask Kim.') == 'Hermes, add a note: ask Kim.'


def test_anything_said_to_hermes_with_a_board_up_goes_to_the_board_and_a_change_it_cannot_find_says_so(app, service, clock,
                                                                                                         scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a meeting board for hiring'))
    before = len(service.room_of(bot_id)['msgs'])
    # Said straight to Hermes as statements: the model makes the change ("our goal is …"), or finds none and the board
    # asks for it again.
    brain.receive(heard(service, clock, bot_id, 'Hermes, our goal is two hires by March.'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, the beta is done.'))
    scribe.plan = []
    brain.receive(heard(service, clock, bot_id, 'Hermes, Zorbly, the frobnicator.'))
    # Not for the board: a question, small talk, and a typed line that asks for no change.
    brain.receive(heard(service, clock, bot_id, 'Hermes, what did we decide?'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, thanks!'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, Zorbly, the frobnicator.', source='chat', sender='Lee'))
    assert [a[1:] for a in scribe.asked] == [('our goal is two hires by March.', 'edit'), ('the beta is done.', 'edit'),
                                             ('Zorbly, the frobnicator.', 'edit')]
    failed = [m for m in service.room_of(bot_id)['msgs'][before:] if m.get('state') == 'failed']
    assert len(failed) == 1 and 'Say it again' in failed[0]['detail']


def test_a_spoken_quarter_written_as_words_reaches_the_board_as_q1(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    started = brain.receive(heard(service, clock, bot_id, "Hermes, start a meeting board for the Q one launch."))
    brain.receive(heard(service, clock, bot_id, "Hermes, add a decision: ship in Q two, not q three."))
    assert started["title"].startswith("Q1 launch")
    assert [a[1] for a in scribe.asked] == ["add a decision: ship in Q2, not Q3."]
    assert meeting_board.spoken("Hermes, add a risk about the Quote one customer") == "Hermes, add a risk about the Quote one customer"


def test_spoken_commands_and_the_board_link_get_chat_lines_only_with_chat_replies_on(app, service, clock, scribe):
    bot_id = start_call(app, service, clock, chat=True)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, add the press kit', source='chat', sender='Lee'))
    link = board_brain.LINK_LINE + app.store.bot(bot_id)['board_url']
    assert service.bots[bot_id]['posted'] == ['Got it: start a whiteboard to plan the launch', link]
    # Once the link is in the chat, the shared screen shows it too, as a short link and a QR code; once.
    assert sent(service, bot_id).count('link') == 1


def test_a_got_it_line_is_sent_without_holding_the_store_so_the_board_is_not_kept_waiting(app, service, clock, scribe):
    bot_id = start_call(app, service, clock, chat=True)
    free = []
    def look():
        with meeting_bot.try_lock(app.store.root / 'lock') as got:
            free.append(got)
            # Already in `said` while in flight, so the bot never takes its own line for a command.
            free.append('Got it: start a whiteboard to plan the launch' in [m['text'] for m in app.store.bot(bot_id)['said']])
    service.on_chat = look
    brain_of(app, bot_id).receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    assert free[:2] == [True, True]


def test_every_chat_line_is_sent_one_at_a_time(app, service, clock, scribe):
    bot_id = start_call(app, service, clock, chat=True)
    held = []
    def look():
        with meeting_bot.try_lock(app.store.root / 'locks' / f'chat-{meeting_bot.safe_key(bot_id)}.lock') as got:
            held.append(not got)
    service.on_chat = look
    ok(app, 'say', 'hello')
    brain_of(app, bot_id).receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    assert held and all(held)


def test_a_board_texted_by_the_owner_posts_the_link_once_with_chat_replies_on(app, service, clock, scribe):
    bot_id = start_call(app, service, clock, chat=True)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    ok(app, 'board', 'add the press kit')
    link = board_brain.LINK_LINE + app.store.bot(bot_id)['board_url']
    assert service.bots[bot_id]['posted'] == [link]


def test_the_owner_turns_the_board_link_off_or_makes_a_new_one_and_the_chat_never_gets_it(app, service, clock, scribe):
    bot_id = start_call(app, service, clock, chat=True)
    room = service.room_of(bot_id)
    assert ok(app, 'board-link', 'off') == {'bot_id': bot_id, 'board_url': None}
    assert room['link'] == 2 and app.store.bot(bot_id)['board_url'] is None
    ok(app, 'board', 'start a whiteboard to plan the launch')
    assert service.bots[bot_id]['posted'] == [], 'a link turned off is never posted'
    assert ok(app, 'board-link', 'new') == {'bot_id': bot_id, 'board_url': 'https://bots.test/b/#edit-3'}
    assert app.store.bot(bot_id)['board_url'] == 'https://bots.test/b/#edit-3'
    ok(app, 'board', 'add the press kit')
    assert service.bots[bot_id]['posted'] == [], 'the owner hands out a link they made again'
    assert 'link' not in sent(service, bot_id), 'and the shared screen shows no short link for it'
    assert ok(app, 'board-link', 'view') == {'bot_id': bot_id, 'view_url': 'https://bots.test/b/#watch-3'}
    assert room['link'] == 3, 'a watch-only link leaves the board link working'


def test_a_board_link_cannot_be_changed_for_a_call_that_is_over(app, service, clock, scribe):
    bot_id = start_call(app, service, clock, chat=True)
    service.room_of(bot_id)['closed'] = True
    code, out, err = run(app, 'board-link', 'new')
    assert (code, err) == (1, 'That call is over, so its board link already stopped working.\n')


def test_the_board_link_waits_for_chat_replies_to_be_turned_on(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    assert service.bots[bot_id]['posted'] == [] and not app.store.bot(bot_id).get('board_link_posted')
    assert 'link' not in sent(service, bot_id), 'no link on screen without chat replies'
    ok(app, 'chat', KEYED, 'on')
    brain.receive(heard(service, clock, bot_id, 'Hermes, add the press kit', source='chat', sender='Lee'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, add a budget', source='chat', sender='Lee'))
    assert service.bots[bot_id]['posted'][-1].startswith(board_brain.LINK_LINE)
    assert sum(p.startswith(board_brain.LINK_LINE) for p in service.bots[bot_id]['posted']) == 1


def test_a_named_board_is_on_screen_at_once_with_no_model(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, start a retro for the launch'))
    assert (result['kind'], result['title'], scribe.asked) == ('new', 'Launch retro', [])
    assert sent(service, bot_id) == ['drawing', 'new', 'done']
    msgs = service.room_of(bot_id)['msgs']
    assert [(b['type'], b['kind']) for b in msgs[1]['board']['blocks']] == [('list', 'pros'), ('list', 'cons'), ('list', 'notes')]
    assert msgs[-1]['detail'] == "Started “Launch retro”: Went well, Didn't go well, Ideas"
    assert picture(app, bot_id, 1) == b'PNG Launch retro'
    # Asking for content too, the model fills in the board by name, with the fast model.
    brain.receive(heard(service, clock, bot_id, 'Hermes, start an agenda with pricing and hiring'))
    assert scribe.asked == [('Agenda', 'start an agenda with pricing and hiring', 'edit')]
    assert sent(service, bot_id)[-3:] == ['block', 'item', 'done']


def test_a_plain_whiteboard_starts_empty_with_no_model_and_the_first_thing_said_shapes_it(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard'))
    assert (result['kind'], scribe.asked) == ('new', [])
    assert service.room_of(bot_id)['boards'] == [{'v': 2, 'title': 'Whiteboard', 'blocks': []}]
    assert sent(service, bot_id) == ['drawing', 'new', 'done']
    brain.receive(heard(service, clock, bot_id, 'Hermes, chart signups: 120 in May, 180 in June'))
    assert scribe.asked == [('Whiteboard', 'chart signups: 120 in May, 180 in June', 'edit')]


def test_hermes_undo_takes_back_the_last_command_and_the_notes_follow(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    brain.receive(heard(service, clock, bot_id, 'Hermes, add the press kit'))
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, no, not that'))
    assert (result['kind'], result['changed'], len(scribe.asked)) == ('undo', [1], 2)
    room = service.room_of(bot_id)
    assert [n['text'] for n in room['boards'][0]['blocks'][0]['items']] == ['start a whiteboard to plan the launch']
    # No model and nothing drawn: the room puts the board back and says so itself.
    assert sent(service, bot_id)[-1] == 'undo'
    # Undoing the command that made the board takes it away, and it is no longer kept for the notes.
    brain.receive(heard(service, clock, bot_id, 'Hermes, undo'))
    assert room['boards'] == [] and app.store.bot(bot_id)['boards'] == []
    assert brain.receive(heard(service, clock, bot_id, 'Hermes, undo'))['refused'] == ['There is nothing to undo.']
    assert sent(service, bot_id)[-1] == 'failed' and not app.store.bot(bot_id).get('board_failed')


def test_each_text_from_the_owner_is_its_own_undo_step(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    ok(app, 'board', 'add the press kit')
    assert ok(app, 'board', 'undo')['undone'] is True
    board = service.room_of(bot_id)['boards']
    assert len(board) == 1 and [n['text'] for n in board[0]['blocks'][0]['items']] == ['start a whiteboard to plan the launch']


def test_an_undo_from_the_link_is_kept_once_the_changes_stop(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    timers = []
    brain.after = lambda seconds, work, *args: timers.append((seconds, work, args)) or Held()
    brain.receive({'t': 'undone', 'by': 'person', 'seq': 50, 'changed': [1], 'boards': [{'title': 'x'}]})
    assert [(t[0], t[2]) for t in timers] == [(board_brain.KEEP_AFTER_S, (1,))]


def test_a_recap_is_drawn_with_no_model_and_said_in_chat_only_with_replies_on(app, service, clock, scribe):
    bot_id = start_call(app, service, clock, chat=True)
    brain = brain_of(app, bot_id)
    assert brain.receive(heard(service, clock, bot_id, 'Hermes, recap')) is None
    assert app.store.bot(bot_id)['board_failed'].startswith('There is nothing to recap yet')
    brain.receive(heard(service, clock, bot_id, 'Hermes, start an action items list'))
    room = service.room_of(bot_id)
    room['boards'][0]['blocks'][0]['items'].append({'id': 'h', 'text': 'Hire a designer', 'owner': 'Lee'})
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, recap', source='chat', sender='Lee'))
    assert (result['kind'], result['board'], scribe.asked) == ('recap', 2, [])
    assert service.bots[bot_id]['posted'][-1] == 'Recap. Action items: Hire a designer.'
    assert picture(app, bot_id, 2) == b'PNG Recap'
    # The bot leaving the call puts the recap up itself; Hermes says it in the chat and keeps it.
    room['boards'][1]['title'] = 'Recap, final'
    brain.receive({'t': 'board', 'by': 'hermes', 'recap': True, 'auto': True, 'n': 2, 'seq': 80, 'text': 'Recap. Done.'})
    assert service.bots[bot_id]['posted'][-1] == 'Recap. Done.' and picture(app, bot_id, 2) == b'PNG Recap, final'
    ok(app, 'chat', KEYED, 'off')
    brain.receive({'t': 'board', 'by': 'hermes', 'recap': True, 'auto': True, 'n': 2, 'seq': 81, 'text': 'Recap. Again.'})
    assert service.bots[bot_id]['posted'][-1] == 'Recap. Done.'


class Held:
    """A timer that has not gone off."""
    cancelled = False

    def cancel(self):
        self.cancelled = True


def test_a_board_changed_from_the_link_is_kept_once_the_changes_stop(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch'))
    timers = []
    brain.after = lambda seconds, work, *args: timers.append((seconds, work, args, Held())) or timers[-1][3]
    service.room_of(bot_id)['boards'][0]['title'] = 'Launch plan'
    brain.receive({'t': 'board', 'by': 'person', 'n': 1, 'seq': 90, 'changed': ['title']})
    brain.receive({'t': 'board', 'by': 'hermes', 'n': 1, 'seq': 91, 'changed': []})
    brain.receive({'t': 'board', 'by': 'person', 'n': 1, 'seq': 92, 'changed': ['title']})
    assert [(t[0], t[3].cancelled) for t in timers] == [(board_brain.KEEP_AFTER_S, True), (board_brain.KEEP_AFTER_S, False)]
    assert picture(app, bot_id, 1) == b'PNG the launch'
    _, work, args, _ = timers[-1]
    work(*args)
    assert picture(app, bot_id, 1) == b'PNG Launch plan' and brain.waiting == {}
    # A change just before the call ends is not asked of the bot's closed browser; the filer keeps it (next test).
    service.room_of(bot_id)['boards'][0]['title'] = 'Launch plan, final'
    brain.receive({'t': 'board', 'by': 'person', 'n': 1, 'seq': 93, 'changed': ['title']})
    assert brain.done() == 'call over'
    assert picture(app, bot_id, 1) == b'PNG Launch plan' and timers[-1][3].cancelled and brain.waiting == {}


def test_a_change_made_as_the_call_ends_is_filed_from_what_the_bot_drew_as_it_left(app, service, clock, spawned, scribe,
                                                                                   tmp_path, monkeypatch):
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    ok(app, 'board', 'new whiteboard for hiring')
    board = {**service.room_of(bot_id)['boards'][0], 'title': 'Launch plan, final'}
    service.room_of(bot_id)['boards'][0] = board
    service.bots[bot_id]['final'] = [{'n': 1, 'title': board['title'], 'board': board, 'png': 'UE5HIGZpbmFs',
                                      'scene': json.dumps({'type': 'excalidraw', 'title': board['title']})}]
    service.bots[bot_id]['final_fail'] = 2
    end_call(app, service, clock, bot_id, spawned)
    slept = []
    app.sleep = slept.append
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    assert slept == [2, 2]
    session = tmp_path / 'live-meeting-test' / 'sessions' / SID
    assert (session / 'board-1.png').read_bytes() == b'PNG final' and (session / 'board-2.png').read_bytes() == b'PNG Hiring'
    assert [b['title'] for b in read_json(session / 'boards.json')['boards']] == ['Launch plan, final', 'Hiring']
    # Every picture shows its board's final version, so there is nothing more to tell.
    assert tick(app) == 'Notes for Budget review are being filed, with its 2 whiteboards.'


def test_commands_that_are_not_for_the_board_old_or_already_done_are_skipped(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    assert brain.receive(heard(service, clock, bot_id, 'Hermes, what did we decide about pricing?')) is None
    old = service.hear(bot_id, 'Hermes, start a whiteboard to plan hiring', at='2026-10-13T14:00:00.000Z')
    assert brain.receive(old) is None
    done = heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan hiring')
    assert brain.receive(done)['board'] == 1
    assert brain.receive(done) is None
    assert brain.receive({'t': 'board', 'seq': 99, 'n': 1}) is None
    assert len(scribe.asked) == 1 and app.store.bot(bot_id)['room_seq'] == done['seq']


# Each command is done once: the process moves its cursor past a command only once it has handled it, a process that
# stopped part way does it again without a second board, and the room marks finished commands so none is done twice.

def test_a_command_counts_as_done_only_once_it_is_handled(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    event = heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch')
    cursor, edits = [], scribe.edits

    def watched(board, command, kind):
        cursor.append(app.store.bot(bot_id)['room_seq'])
        yield from edits(board, command, kind)
    scribe.edits = watched
    brain_of(app, bot_id).receive(event)
    assert cursor == [0] and app.store.bot(bot_id)['room_seq'] == event['seq']


def test_a_command_a_stopped_process_left_half_done_is_done_again_without_a_second_board(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    event = heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch')
    # The process that got it made the board and stopped there: no edits, no caption, its cursor never moved on.
    app.service.room(service.bots[bot_id]['token']).send({'t': 'new', 'cmd': event['id']})
    replayed = {k: v for k, v in event.items() if k not in ('boards', 'current', 'last')}
    assert brain_of(app, bot_id).receive(replayed)['board'] == 1
    room = service.room_of(bot_id)
    assert [b['title'] for b in room['boards']] == ['the launch'] and room['events'][-1]['finished'] is True


def test_a_command_the_room_marks_finished_is_not_done_again(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    event = heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch')
    brain_of(app, bot_id).receive(event)
    assert event['finished'] is True
    # A process whose cursor is behind (it stopped after the caption, before saving it) is sent the command again.
    with app.store.lock():
        record = app.store.bot(bot_id)
        record['room_seq'] = 0
        app.store.put(record)
    assert brain_of(app, bot_id).receive(dict(event)) is None
    assert len(scribe.asked) == 1 and len(service.room_of(bot_id)['boards']) == 1


def test_a_phrase_that_carries_on_a_command_changes_what_that_command_made(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    first = heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan hiring')
    assert brain.receive(first)['kind'] == 'new'
    command = heard(service, clock, bot_id, 'Hermes, add an action item: Lee will hire a contract designer.')
    assert brain.receive(command)['kind'] == 'edit'
    on = heard(service, clock, bot_id, 'Hermes, And it is due Friday, December 5.', continues=command['id'])
    assert brain.receive(on)['done']
    title, asked, kind = scribe.asked[-1]
    assert asked.startswith('And it is due Friday, December 5.') and 'Lee will hire a contract designer' in asked
    assert 'add no new one' in asked and kind == 'edit'
    # "Owner is Lee." is no board command on its own (no verb the board knows), but carries the same command on.
    owner = heard(service, clock, bot_id, 'Hermes, Owner is Lee.', continues=command['id'])
    assert meeting_board.intent(owner['text'], True) is None
    assert brain.receive(owner)['done'] and scribe.asked[-1][1].startswith('Owner is Lee.')
    # The board's status bar shows the words said, not the note to the model, under the new command's own id.
    drawing = [m for m in service.room_of(bot_id)['msgs'] if m.get('state') == 'drawing' and m.get('cmd') == on['id']]
    assert drawing == [{'t': 'caption', 'state': 'drawing', 'text': 'And it is due Friday, December 5.', 'cmd': on['id']}]


def test_a_phrase_that_carries_on_nothing_the_board_changed_is_dropped(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    question = heard(service, clock, bot_id, 'Hermes, what did we decide about pricing?')
    assert brain.receive(question) is None
    asked = len(scribe.asked)
    assert brain.receive(heard(service, clock, bot_id, 'Hermes, due Friday.', continues=question['id'])) is None
    assert brain.receive(heard(service, clock, bot_id, 'Hermes, due Friday.', continues='v-unknown')) is None
    assert len(scribe.asked) == asked


def test_a_board_command_too_old_to_carry_out_says_so_on_the_board(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    old = service.hear(bot_id, 'Hermes, add the press kit', at='2026-10-13T14:00:00.000Z')
    assert brain.receive(old) is None
    assert service.room_of(bot_id)['msgs'][-1] == {'t': 'caption', 'state': 'failed', 'text': 'add the press kit',
                                                   'detail': 'Missed while Hermes was away. Say it again.', 'cmd': old['id']}
    sent = len(service.room_of(bot_id)['msgs'])
    assert brain.receive(service.hear(bot_id, 'Hermes, what did we decide?', at='2026-10-13T14:00:00.000Z')) is None
    assert len(service.room_of(bot_id)['msgs']) == sent and scribe.asked == []


def test_the_bots_own_chat_lines_are_never_board_commands(app, service, clock, scribe):
    bot_id = start_call(app, service, clock, chat=True)
    app.store.put({**app.store.bot(bot_id), 'said': [{'at': 'x', 'text': 'Hermes, add a column for risks'}]})
    brain = brain_of(app, bot_id)
    assert brain.receive(heard(service, clock, bot_id, 'Hermes, add a column for risks', source='chat',
                               sender="Owner's AI Notetaker")) is None
    assert scribe.asked == []


def test_board_commands_are_capped_per_call(app, service, clock, scribe, monkeypatch):
    monkeypatch.setattr(board_brain, 'MAX_COMMANDS', 2)
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    for n in range(4):
        brain.receive(heard(service, clock, bot_id, f'Hermes, add idea {n} to the board'))
    assert len(scribe.asked) == 2 and app.store.bot(bot_id)['board_commands'] == 2


def test_a_change_the_model_cannot_make_is_told_once_and_said_in_chat_when_replies_are_on(app, service, clock, scribe):
    scribe.error = ValueError('the model made no change')
    bot_id = start_call(app, service, clock, chat=True)
    brain = brain_of(app, bot_id)
    assert brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan hiring')) is None
    assert sent(service, bot_id)[-1] == 'failed'
    assert service.bots[bot_id]['posted'] == ['Got it: start a whiteboard to plan hiring', "Sorry, I couldn't change the whiteboard."]
    clock.to(clock() + timedelta(minutes=1))
    assert tick(app) == 'The notetaker could not change the whiteboard in Budget review: the model made no change.'
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard again'))
    assert tick(app) == ''


def test_edits_made_before_a_failure_are_still_kept_for_the_notes(app, service, clock, scribe):
    def broken():
        yield 'title', {'text': 'the launch'}
        raise ValueError('the model stopped')

    scribe.plan = broken()
    bot_id = start_call(app, service, clock)
    assert brain_of(app, bot_id).receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan hiring')) is None
    assert app.store.bot(bot_id)['board_failed'] == 'the model stopped.'
    assert picture(app, bot_id, 1) == b'PNG the launch'


def test_edits_the_room_refuses_are_skipped_and_a_change_with_none_left_fails(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    scribe.plan = [('block', {'id': 'a', 'type': 'list', 'title': 'A'}), ('item', {'id': 'x', 'block': 'nowhere', 'text': 'lost'})]
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan hiring'))
    assert (result['done'], result['refused']) == (['block'], ['there is no block nowhere'])
    # The board is named for its first block once it has one.
    assert service.room_of(bot_id)['msgs'][-1]['detail'] == 'Started “A”: 1 block (1 skipped)'
    scribe.plan = [('item', {'id': 'y', 'block': 'nowhere', 'text': 'lost'})]
    assert brain.receive(heard(service, clock, bot_id, 'Hermes, add a note to the board')) is None
    assert app.store.bot(bot_id)['board_failed'] == 'there is no block nowhere.'


def test_a_board_the_call_will_not_show_is_told_once(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    service.room_of(bot_id)['can_present'] = False
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard'))
    brain.receive({'t': 'presenting', 'on': False, 'error': 'the host does not let guests present'})
    clock.to(clock() + timedelta(minutes=1))
    assert tick(app) == ('The notetaker drew a whiteboard in Budget review but could not show it: '
                         'the host does not let guests present.')
    assert tick(app) == ''


def test_the_process_follows_the_room_until_the_call_is_over(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    heard(service, clock, bot_id, 'Hermes, start a whiteboard to plan the launch')
    heard(service, clock, bot_id, 'Hermes, add the press kit')
    naps = []

    def sleep(seconds):
        naps.append(seconds)
        if len(naps) == 2:
            app.store.put({**app.store.bot(bot_id), 'phase': 'ended'})

    brain = brain_of(app, bot_id)
    brain.sleep = sleep
    assert brain.run() == 'call over'
    # The room's stream ended twice (the fake room sends what it has and closes); each command was done once.
    assert naps == [1, 1] and [a[1] for a in scribe.asked] == ['start a whiteboard to plan the launch', 'add the press kit']


def test_a_second_process_for_the_same_call_does_nothing(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    with meeting_bot.try_lock(app.store.root / 'locks' / f'brain-{bot_id}.lock') as got:
        assert got and run(app, 'brain', bot_id) == (0, '', '')
    assert scribe.asked == []


# Texts from the owner.

def test_the_follower_answers_a_chat_question_within_seconds(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    clock.to(START + timedelta(minutes=2))
    follow = Follow(app, clock, {2: lambda: service.say(bot_id, 'Dana Whitfield', 'Hermes, what did we decide about pricing?'),
                                 4: lambda: service.move(bot_id, 'ended')})
    told = follow.run()
    assert follow.naps[:3] == [meeting_bot.LOOK_S] * 3 and answers.questions == ['what did we decide about pricing?']
    assert told.startswith('You asked Hermes in Budget review: what did we decide about pricing?')


def test_texts_from_the_owner_draw_new_boards_show_old_ones_and_stop(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    first = ok(app, 'board', 'add risks to the board')
    # Named for its first block, once it has one.
    assert {k: first[k] for k in ('bot_id', 'board', 'title', 'presenting', 'share_error', 'board_url')} == {
        'bot_id': bot_id, 'board': 1, 'title': 'Ideas', 'presenting': True, 'share_error': None,
        'board_url': f"https://bots.test/b/{service.bots[bot_id]['token']}"}
    second = ok(app, 'board', 'start a new whiteboard for hiring')
    assert (second['board'], second['title']) == (2, 'Hiring')
    asked = len(scribe.asked)
    assert ok(app, 'board', 'show board 1')['title'] == 'Ideas' and len(scribe.asked) == asked
    assert service.room_of(bot_id)['current'] == 1
    stopped = ok(app, 'board', 'stop sharing the board')
    assert (stopped['presenting'], service.room_of(bot_id)['presenting'], app.store.bot(bot_id)['presenting']) == (
        False, False, False)
    # Any other text is a change to the board last shown, which goes back on screen.
    again = ok(app, 'board', 'Kim owns the launch email')
    assert (again['board'], again['presenting']) == (1, True)
    assert [b['title'] for b in app.store.bot(bot_id)['boards']] == ['Ideas', 'Hiring']
    assert app.store.bot(bot_id)['room_written'] == service.room_of(bot_id)['seq']


@pytest.mark.parametrize('argv, message', [
    (('board', 'show board 4'), 'There is no whiteboard 4 in this call.'),
    (('board', '   '), 'Say what to put on the whiteboard.'),
])
def test_board_texts_that_cannot_be_done(app, service, clock, scribe, argv, message):
    start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard')
    code, _, err = run(app, *argv)
    assert (code, err.strip()) == (1, message)


def test_a_board_text_with_no_call_under_way(app, scribe):
    assert run(app, 'board', 'start a whiteboard') == (1, '', 'Hermes is not in a call.\n')


def test_a_call_from_before_live_boards_says_so(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    app.store.put({**app.store.bot(bot_id), 'board_token': None})
    assert run(app, 'board', 'start a whiteboard')[2].startswith('This call has no whiteboard.')


# Filing.

def test_the_boards_are_filed_with_the_call_and_the_room_is_closed(app, service, clock, spawned, scribe, tmp_path,
                                                                   monkeypatch):
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    ok(app, 'board', 'new whiteboard for hiring')
    end_call(app, service, clock, bot_id, spawned)
    assert service.room_of(bot_id)['closed'] is True
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    session = tmp_path / 'live-meeting-test' / 'sessions' / SID
    assert read_json(session / 'boards.json') == {'boards': [
        {'n': 1, 'title': 'the launch', 'picture': 'board-1.png', 'source': 'board-1.excalidraw',
         'markdown': '**Ideas**\n- start a whiteboard to plan the launch', 'actions': [], 'decisions': []},
        {'n': 2, 'title': 'Hiring', 'picture': 'board-2.png', 'source': 'board-2.excalidraw',
         'markdown': '', 'actions': [], 'decisions': []}]}
    assert (session / 'board-2.png').read_bytes() == b'PNG Hiring'
    assert json.loads((session / 'board-1.excalidraw').read_text())['type'] == 'excalidraw'
    assert tick(app) == 'Notes for Budget review are being filed, with its 2 whiteboards.'
    assert ok(app, 'status')['bots'][0]['presenting'] is False


# The final boards. Before the room closes, the mini keeps its boards as the call left them; filing checks each kept
# picture against them, so the notes never quietly show an older board than people saw.

def test_the_rooms_final_boards_are_kept_before_it_closes(app, service, clock, spawned, scribe):
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    room = service.room_of(bot_id)
    end_call(app, service, clock, bot_id, spawned)
    kept = read_json(app.store.root / 'boards' / bot_id / 'final.json')
    assert kept['boards'] == room['boards'] and kept['seq'] == room['seq'] and kept['current'] == 1
    assert room['closed'] is True and app.store.bot(bot_id)['room_closed'] is True


def test_a_room_that_cannot_be_read_stays_open_until_a_later_tick_keeps_its_boards(app, service, clock, spawned, scribe):
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    room = service.room_of(bot_id)
    room['state_fail'] = 1000
    end_call(app, service, clock, bot_id, spawned)
    assert room['closed'] is False and not (app.store.root / 'boards' / bot_id / 'final.json').exists()
    room['state_fail'] = 0
    tick(app)
    assert room['closed'] is True and read_json(app.store.root / 'boards' / bot_id / 'final.json')['boards'] == room['boards']


def test_a_room_that_never_answers_is_left_to_empty_itself(app, service, clock, spawned, scribe):
    bot_id = start_call(app, service, clock)
    room = service.room_of(bot_id)
    room['state_fail'] = 1000
    end_call(app, service, clock, bot_id, spawned)
    clock.to(START + timedelta(hours=11))
    tick(app)
    assert not app.store.bot(bot_id).get('room_closed')
    clock.to(START + timedelta(hours=13))
    tick(app)
    assert app.store.bot(bot_id)['room_closed'] == 'emptied' and room['closed'] is False


def test_a_board_whose_picture_is_older_than_its_final_version_is_filed_with_its_final_text_and_told(
        app, service, clock, spawned, scribe, tmp_path, monkeypatch):
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    # A change in the call's last seconds that the bot did not draw again as it left.
    board = service.room_of(bot_id)['boards'][0]
    board['blocks'][0]['items'].append({'id': 'late', 'text': 'Ship on Friday'})
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    session = tmp_path / 'live-meeting-test' / 'sessions' / SID
    assert (session / 'board-1.png').read_bytes() == b'PNG the launch'
    assert 'Ship on Friday' in read_json(session / 'boards.json')['boards'][0]['markdown']
    assert tick(app) == ('Notes for Budget review are being filed, with its whiteboard.\n'
                         'The picture of whiteboard "the launch" in Budget review shows it before its last change. '
                         'The notes have its final text.')
    assert tick(app) == ''


def test_a_board_with_no_picture_is_told_with_where_its_final_version_is(app, service, clock, spawned, scribe, tmp_path,
                                                                         monkeypatch):
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    room = service.room_of(bot_id)
    room['boards'].append({**json.loads(json.dumps(room['boards'][0])), 'title': 'Hiring'})
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    session = tmp_path / 'live-meeting-test' / 'sessions' / SID
    assert [b['title'] for b in read_json(session / 'boards.json')['boards']] == ['the launch']
    final = app.store.root / 'boards' / bot_id / 'final.json'
    assert tick(app) == ('Notes for Budget review are being filed, with its whiteboard.\n'
                         f'Whiteboard "Hiring" in Budget review has no picture, so it is not in the notes. '
                         f'The final version is kept in {final}.')
    assert read_json(final)['boards'][1]['title'] == 'Hiring'


def test_final_boards_that_cannot_be_read_are_told(app, service, clock, spawned, scribe, tmp_path, monkeypatch):
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    service.room_of(bot_id)['state_fail'] = 1000
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    assert tick(app) == ('Notes for Budget review are being filed, with its whiteboard.\n'
                         'Hermes could not read the final whiteboards of Budget review, so a change made in the '
                         "call's last seconds may be missing from the notes.")


def test_final_boards_that_cannot_be_read_are_told_even_when_no_picture_was_kept(app, service, clock, spawned, scribe,
                                                                                tmp_path, monkeypatch):
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    # The bot never drew it, so no picture of it is kept here.
    with app.store.lock():
        record = app.store.bot(bot_id)
        record.update(boards=[], board=None)
        app.store.put(record)
    shutil.rmtree(app.store.root / 'boards' / bot_id)
    service.room_of(bot_id)['state_fail'] = 1000
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    assert tick(app) == ('Notes for Budget review are being filed.\n'
                         'Hermes could not read the final whiteboards of Budget review, so a change made in the '
                         "call's last seconds may be missing from the notes.")


def test_a_call_with_no_board_says_nothing_about_boards_when_its_room_cannot_be_read(app, service, clock, spawned,
                                                                                    scribe, tmp_path, monkeypatch):
    monkeypatch.setenv('LML_DONE_CMD', 'true')
    fake_transcribe(app, [])
    bot_id = start_call(app, service, clock)
    # A question to Hermes goes through the room too, but is no board.
    brain_of(app, bot_id).receive(heard(service, clock, bot_id, 'Hermes, what did we decide last week?'))
    assert app.store.bot(bot_id)['room_seq'] > 0 and not app.store.bot(bot_id)['board_commands']
    service.room_of(bot_id)['state_fail'] = 1000
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'filed'
    assert tick(app) == 'Notes for Budget review are being filed.'


def test_when_hereby_recorded_the_call_the_boards_go_with_its_recording(app, service, clock, spawned, scribe, tmp_path):
    from test_meeting_bot import mac_session
    fake_transcribe(app, [])
    folder = mac_session(tmp_path)
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard to plan the launch')
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'mac'
    assert (folder / 'board-1.png').read_bytes() == b'PNG the launch' and (folder / 'boards.json').exists()
    assert tick(app) == ('Hereby already recorded Budget review, so Hermes made no second note. It kept the meeting chat '
                         'and added its whiteboard to that recording.')


def test_a_silent_call_keeps_its_boards_and_says_where(app, service, clock, spawned, scribe):
    fake_transcribe(app, [], silent=True)
    bot_id = start_call(app, service, clock)
    ok(app, 'board', 'start a whiteboard')
    end_call(app, service, clock, bot_id, spawned)
    assert ok(app, 'file', bot_id)['filing'] == 'silent'
    folder = app.store.root / 'boards' / bot_id
    assert (folder / 'board-1.png').exists()
    assert tick(app) == f'Nobody spoke in Budget review, so there are no notes to file. Its whiteboard is kept in {folder}.'


@pytest.mark.parametrize('name, accepted', [('board-1.png', True), ('board-12.excalidraw', True), ('boards.json', True),
                                            ('board-1.exe', False), ('../board-1.png', False), ('board-x.png', False)])
def test_the_recorder_takes_board_files_and_nothing_else(tmp_path, name, accepted):
    result = subprocess.run([sys.executable, str(MINI / 'live-meeting-receive'), SID, name, '0'], input=b'data',
                            capture_output=True)
    assert (result.returncode == 0) == accepted
    assert ((tmp_path / 'live-meeting-test' / 'sessions' / SID / name).exists()) == accepted


# What the tick still does with what was said.

def test_a_spoken_board_command_is_never_taken_as_a_question(app, service, clock, answers):
    bot_id = start_call(app, service, clock, chat=True)
    service.speak(bot_id, 'Hermes, put the launch dates on a timeline.')
    service.say(bot_id, 'Lee', 'Hermes, add a column for risks')
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == '' and answers.questions == []
    assert service.bots[bot_id]['posted'] == []


def test_near_misses_the_bot_heard_are_kept_once_each_with_the_calls_record_only(app, service, clock, answers):
    bot_id = start_call(app, service, clock)
    misses = [{'id': 'n1', 'text': 'Please put the launch dates on a timeline.', 'at': '2026-10-13T15:10:00.000Z'},
              {'id': 'n2', 'text': 'Let me start a whiteboard.', 'started': True, 'at': '2026-10-13T15:10:05.000Z'},
              {'id': 'n3', 'text': '   '}, 'not a near miss']
    service.bots[bot_id]['near_misses'] = misses
    clock.to(START + timedelta(minutes=2))
    tick(app)
    clock.to(START + timedelta(minutes=3))
    service.bots[bot_id]['near_misses'] = [*misses, {'id': 'n4', 'text': 'x' * 300}]
    tick(app)
    kept = app.store.bot(bot_id)['near_misses']
    assert kept == [misses[0], misses[1], {'id': 'n4', 'text': 'x' * 200, 'at': None}]
    assert answers.questions == [] and service.bots[bot_id]['posted'] == []


def test_a_spoken_question_reaches_the_owner_only_with_chat_on_and_only_when_said_to_hermes(app, service, clock, answers):
    bot_id = start_call(app, service, clock)
    service.speak(bot_id, 'Hermes, what did we decide about pricing?')
    clock.to(START + timedelta(minutes=2))
    assert tick(app) == '' and answers.questions == []
    ok(app, 'chat', KEYED, 'on')
    service.speak(bot_id, 'Hermes is taking the notes today', direct=False)
    service.speak(bot_id, 'Hermes, Kim will do it.')
    service.speak(bot_id, 'Hermes, what did we decide about pricing?')
    clock.to(START + timedelta(minutes=3))
    texts = tick(app)
    assert answers.questions == ['what did we decide about pricing?']
    assert texts.startswith('You asked Hermes in Budget review: what did we decide about pricing?')
    assert service.bots[bot_id]['posted'] == [meeting_bot.SENT_NOTE]


def test_spoken_commands_that_reach_the_per_call_limit_are_told_once(app, service, clock):
    bot_id = start_call(app, service, clock)
    service.bots[bot_id]['voice'] = {'state': 'capped', 'error': 'reached the 240-minute limit for one call',
                                     'streamed_seconds': 14400}
    clock.to(START + timedelta(minutes=6))
    assert tick(app) == ('Spoken commands stopped in Budget review (reached the 240-minute limit for one call). Typed '
                         'ones in the meeting chat still work.')
    assert tick(app) == ''


def test_streamed_minutes_are_shown_logged_once_per_call_and_a_failed_stream_is_told_once(app, service, clock, spawned):
    bot_id = start_call(app, service, clock)
    service.bots[bot_id]['voice'] = {'state': 'listening', 'error': None, 'streamed_seconds': 330}
    clock.to(START + timedelta(minutes=6))
    assert tick(app) == ''
    assert ok(app, 'status')['bots'][0]['voice_minutes'] == 5.5
    service.bots[bot_id]['voice'] = {'state': 'failed', 'error': 'Deepgram closed the stream (1006)', 'streamed_seconds': 600}
    clock.to(START + timedelta(minutes=10))
    assert tick(app) == ('Spoken commands stopped working in Budget review (Deepgram closed the stream (1006)). Typed ones '
                         'in the meeting chat still work.')
    assert tick(app) == ''
    end_call(app, service, clock, bot_id, spawned)
    tick(app)
    lines = (app.store.root / 'voice-usage.jsonl').read_text().splitlines()
    assert [json.loads(line)['minutes'] for line in lines] == [10.0]


# The richer pictures: new kinds of blocks, numbers drawn another way, and Hermes's own pictures.

def test_the_model_is_taught_the_richer_pictures_and_when_each_fits():
    system = meeting_board.SYSTEM
    for words in ('donut', 'stacked', 'heatmap', 'funnel', 'roadmap', 'tree', 'swimlane', 'sketch', 'target', 'points',
                  'parts of a whole, a donut', 'stages with counts, a funnel', 'who reports to whom, a tree'):
        assert words in system, words
    tools = {t['name']: t['input_schema']['properties'] for t in meeting_board.TOOLS}
    assert tools['block']['type']['enum'] == list(meeting_board.TYPES)
    assert tools['block']['style']['enum'] == ['bar', 'line', 'stacked', 'donut', 'pie', 'heatmap']
    assert {'lane', 'start', 'end', 'target', 'points'} <= set(tools['item'])
    assert set(tools['sketch']) == {'id', 'title', 'brief', 'after'}
    assert 'sketch' in meeting_board.EDIT_NAMES
    assert meeting_board.BOARD_WORDS.search('put up an org chart') and meeting_board.BOARD_WORDS.search('a funnel please')


def test_the_edit_model_reads_a_custom_picture_as_what_it_shows_never_its_svg():
    board = {'v': 2, 'title': 'Systems', 'blocks': [
        {'id': 'arch', 'type': 'sketch', 'title': 'Stripe', 'brief': 'App to API to Stripe', 'items': [],
         'svg': '<svg viewBox="0 0 1000 520">' + '<rect width="1" height="1"/>' * 500 + '</svg>', 'drawing': 'd1'},
        {'id': 'c', 'type': 'chart', 'title': 'Revenue', 'items': [{'id': 'a', 'text': 'Q1', 'value': 1}]}]}
    shown = json.loads(meeting_board.compact(board))
    assert shown['blocks'][0] == {'id': 'arch', 'type': 'sketch', 'title': 'Stripe', 'brief': 'App to API to Stripe', 'items': []}
    assert shown['blocks'][1] == board['blocks'][1]
    assert '<svg' not in meeting_board.fallback_prompt(board, 'add a risk')


def test_the_richer_pictures_read_in_the_notes_the_way_they_look():
    board = {'v': 2, 'title': 'QBR', 'blocks': [
        {'id': 'd', 'type': 'chart', 'style': 'donut', 'title': 'Revenue by region', 'unit': '$',
         'items': [{'id': 'na', 'text': 'North America', 'value': 620}, {'id': 'eu', 'text': 'Europe', 'value': 280},
                   {'id': 'as', 'text': 'Asia', 'value': 100}]},
        {'id': 'f', 'type': 'funnel', 'title': 'Pipeline', 'items': [{'id': 'l', 'text': 'Leads', 'value': 1800},
                                                                     {'id': 'w', 'text': 'Won', 'value': 240}]},
        {'id': 'r', 'type': 'roadmap', 'title': 'Roadmap', 'items': [
            {'id': 'p', 'text': 'Payments v2', 'lane': 'Platform', 'start': 'Jan', 'end': 'Mar', 'status': 'now'},
            {'id': 'q', 'text': 'Mobile app', 'start': 'Q2'}]},
        {'id': 't', 'type': 'tree', 'title': 'Team', 'items': [{'id': 'pr', 'text': 'Priya', 'note': 'Head of design'},
                                                               {'id': 'sa', 'text': 'Sam', 'parent': 'pr'}]},
        {'id': 's', 'type': 'swimlane', 'title': 'Refunds', 'items': [{'id': 'a', 'text': 'Takes the request', 'lane': 'Support'},
                                                                       {'id': 'b', 'text': 'Approves it', 'lane': 'Finance'}],
         'links': [{'from': 'b', 'to': 'a', 'label': 'No'}]},
        {'id': 'k', 'type': 'stats', 'title': 'KPIs', 'items': [{'id': 'n', 'text': 'Net retention', 'value': '112%',
                                                                  'target': '115%', 'points': [104, 108, 112]}]},
        {'id': 'x', 'type': 'sketch', 'title': 'Stripe', 'brief': 'The app calls our API, which calls Stripe', 'items': [],
         'svg': '<svg/>'},
        {'id': 'y', 'type': 'sketch', 'title': 'Regions', 'brief': 'Three circles', 'items': [], 'drawing': 'd1'}]}
    assert meeting_board.board_text(board)['markdown'] == (
        '**Revenue by region**\n- North America: $620 (62%)\n- Europe: $280 (28%)\n- Asia: $100 (10%)\n\n'
        '**Pipeline**\n1. Leads: 1,800\n2. Won: 240 (13% of the stage before)\n\n'
        '**Roadmap**\n- Platform: Payments v2, Jan to Mar (under way)\n- Mobile app, Q2\n\n'
        '**Team**\n- Priya (Head of design)\n  - Sam\n\n'
        '**Refunds**\n1. Takes the request (Support)\n2. Approves it (Finance)\n- Approves it → Takes the request (No)\n\n'
        '**KPIs**\n- Net retention: 112% (target 115%, recent 104 → 108 → 112)\n\n'
        '**Stripe**\n- Picture by Hermes: The app calls our API, which calls Stripe\n\n'
        '**Regions**\n- Picture by Hermes: Three circles (still being drawn when the board was kept)')


def test_money_reads_in_the_notes_the_way_the_board_shows_it():
    board = {'v': 2, 'title': 'QBR', 'blocks': [
        {'id': 'b', 'type': 'chart', 'title': 'Bookings', 'unit': '$M', 'columns': [{'id': 'c', 'name': 'Core'},
                                                                                   {'id': 'a', 'name': 'Add-ons'}],
         'items': [{'id': 'q2', 'text': 'Q2', 'cells': {'c': 1.9, 'a': 0.6}}]},
        {'id': 'r', 'type': 'chart', 'style': 'line', 'title': 'Revenue', 'unit': '$M',
         'items': [{'id': 'q3', 'text': 'Q3', 'value': 4.2}, {'id': 'f', 'text': 'Q4 forecast', 'value': '4.6M'}]},
        {'id': 'f', 'type': 'funnel', 'title': 'Pipeline', 'unit': 'leads', 'items': [{'id': 'l', 'text': 'Leads', 'value': 4800}]}]}
    assert meeting_board.board_text(board)['markdown'] == (
        '**Bookings**\n- Q2: Core $1.9M, Add-ons $0.6M\n\n'
        '**Revenue**\n- Q3: $4.2M\n- Q4 forecast: $4.6M\n\n'
        '**Pipeline**\n1. Leads: 4,800 leads')


class PictureRoom:
    """A board room for a custom picture: records what is sent, answers each op as `answer(op)` says."""

    def __init__(self, blocks=(), answer=None):
        self.msgs, self.blocks, self.answer = [], list(blocks), answer or (lambda op: {'ok': True})

    def send(self, *msgs):
        self.msgs += msgs
        return [self.answer(m['op']) if m['t'] == 'op' else {'ok': True} for m in msgs]

    def state(self):
        return {'boards': [{'title': 'Systems', 'blocks': self.blocks}], 'current': 1}

    def sibling(self):
        return self


class Painter:
    """Stands in for the picture model: gives its SVG a piece at a time."""

    def __init__(self, svg, error=None):
        self.svg, self.error, self.asked = svg, error, []

    def draw(self, title, brief, previous=None, shows=None):
        self.asked.append((title, brief, previous))
        for at in range(0, len(self.svg), 40):
            yield self.svg[at:at + 40]
        if self.error:
            raise self.error


SVG = ('<svg viewBox="0 0 1000 520"><rect x="24" y="24" width="200" height="80" rx="14" fill="#ffffff"/>'
       '<text x="124" y="64">Our API</text><rect x="400" y="24" width="200" height="80" rx="14" fill="#ffffff"/>'
       '<text x="500" y="64">Stripe</text></svg>')


def ticking(step=1.0):
    now = [0.0]

    def clock():
        now[0] += step
        return now[0]
    return clock


def test_a_custom_picture_goes_up_at_once_saying_it_is_drawn_and_is_drawn_after_the_command(monkeypatch):
    started = []
    monkeypatch.setattr(board_brain.threading, 'Thread',
                        lambda target, args, kwargs, daemon: type('T', (), {'start': lambda self: started.append((args, kwargs))})())
    room = PictureRoom()

    class Asks:
        def edits(self, board, command, kind):
            yield 'sketch', {'id': 'arch', 'title': 'How we pay', 'brief': 'The app calls our API, which calls Stripe'}
    state = {'boards': [{'title': 'Systems', 'blocks': []}], 'current': 1}
    result = board_brain.run_command(room, Asks(), state, 'Hermes, draw how our system talks to Stripe', cmd='c1',
                                     drawn='keep')
    ops = [m['op'] for m in room.msgs if m['t'] == 'op']
    assert len(ops) == 1 and ops[0]['op'] == 'block' and ops[0]['type'] == 'sketch'
    assert (ops[0]['id'], ops[0]['title'], ops[0]['brief']) == ('arch', 'How we pay', 'The app calls our API, which calls Stripe')
    assert ops[0]['drawing']
    assert [m['state'] for m in room.msgs if m['t'] == 'caption'] == ['drawing', 'done'], 'the command is done; the picture follows'
    assert result['sketches'] == ['arch']
    (args, kwargs), = started
    job = args[2]
    assert (job['nonce'], job['previous'], kwargs) == (ops[0]['drawing'], None, {'cmd': 'c1', 'drawn': 'keep'})


def test_a_custom_picture_shows_as_it_comes_then_whole_and_is_kept_for_the_notes():
    room, kept = PictureRoom(), []
    job = {'id': 'arch', 'n': 1, 'nonce': 'd1', 'title': 'How we pay', 'brief': 'x', 'previous': None}
    assert board_brain.draw_sketch(room, Painter(SVG), job, cmd='c1', drawn=kept.append, clock=ticking(0.5)) == 'drawn'
    ops = [m['op'] for m in room.msgs if m['t'] == 'op']
    assert all(op['op'] == 'sketch' and op['drawing'] == 'd1' for op in ops)
    assert len(ops) >= 3 and not any(op.get('done') for op in ops[:-1]), 'parts first, as they come'
    assert all(op['svg'].startswith('<svg') for op in ops)
    assert ops[-1] == {'op': 'sketch', 'id': 'arch', 'drawing': 'd1', 'svg': SVG, 'done': True}
    assert room.msgs[-1] == {'t': 'caption', 'state': 'done', 'detail': 'Drew How we pay', 'cmd': 'c1'}
    assert kept == [1]


def test_a_custom_picture_asked_for_again_or_undone_stops_without_a_word():
    for error in ('that picture was asked for again since', 'there is no picture arch'):
        room = PictureRoom(answer=lambda op, error=error: {'ok': False, 'error': error})
        job = {'id': 'arch', 'n': 1, 'nonce': 'd1', 'title': 'Pay', 'brief': 'x', 'previous': None}
        assert board_brain.draw_sketch(room, Painter(SVG), job, clock=ticking(2)) == 'replaced'
        assert len(room.msgs) == 1 and not [m for m in room.msgs if m['t'] == 'caption']


def test_a_custom_picture_that_cannot_be_drawn_says_so_on_its_block():
    for painter in (Painter(SVG[:60], error=OSError('timed out')), Painter('I cannot draw that.')):
        room, kept = PictureRoom(), []
        job = {'id': 'arch', 'n': 1, 'nonce': 'd1', 'title': 'Pay', 'brief': 'x', 'previous': None}
        assert board_brain.draw_sketch(room, painter, job, drawn=kept.append, clock=ticking(0.1)) == 'failed'
        failed = [m['op'] for m in room.msgs if m['t'] == 'op' and m['op'].get('failed')]
        assert failed and failed[0]['drawing'] == 'd1'
        assert room.msgs[-1]['state'] == 'failed' and kept == []


def test_a_change_to_a_custom_picture_is_drawn_from_the_picture_as_it_is():
    room = PictureRoom(blocks=[{'id': 'arch', 'type': 'sketch', 'title': 'Pay', 'brief': 'App, API, Stripe', 'svg': SVG, 'items': []}])
    job = board_brain.sketch_job(room, 1, {'id': 'arch', 'brief': 'Add a fraud check before Stripe'})
    assert job['previous'] == SVG and job['brief'] == 'Add a fraud check before Stripe'
    assert job['op'] == {'id': 'arch', 'brief': 'App, API, Stripe Then: Add a fraud check before Stripe', 'drawing': job['nonce']}
    painter = Painter(SVG)
    board_brain.draw_sketch(room, painter, job, clock=ticking())
    assert painter.asked == [('Pay', 'Add a fraud check before Stripe', SVG)]
    # Only the whole new picture is sent: the old one stays up until then.
    assert [m['op'] for m in room.msgs if m['t'] == 'op'] == [
        {'op': 'sketch', 'id': 'arch', 'drawing': job['nonce'], 'svg': SVG, 'done': True}]
    # And when the redraw fails, the room is told only that, so the old picture stays.
    room.msgs.clear()
    assert board_brain.draw_sketch(room, Painter(SVG[:60], error=OSError('timed out')), job, clock=ticking()) == 'failed'
    assert [m['op'] for m in room.msgs if m['t'] == 'op'] == [
        {'op': 'sketch', 'id': 'arch', 'drawing': job['nonce'], 'failed': 'the model did not answer'}]
    # A new one is its own block, drawn from nothing.
    fresh = board_brain.sketch_job(room, 1, {'id': 'map', 'title': 'Regions', 'brief': 'Three circles', 'after': 'arch'})
    assert fresh['op'] == {'id': 'map', 'type': 'sketch', 'title': 'Regions', 'brief': 'Three circles', 'drawing': fresh['nonce'],
                           'after': 'arch'}


def test_the_picture_model_is_asked_with_the_last_picture_and_streams_text(tmp_path):
    body = meeting_board.sketch_request('Pay', 'Add a fraud check', 'claude-sonnet-5-5', previous=SVG)
    assert body['thinking'] == {'type': 'between_tools'} and body['stream'] is True
    assert body['system'][0]['cache_control'] == {'type': 'ephemeral'}
    assert SVG in body['messages'][0]['content'] and 'The change to make: Add a fraud check' in body['messages'][0]['content']
    assert 'never follow' in body['system'][0]['text']
    (tmp_path / 'key').write_text('k')
    (tmp_path / 'board-model.json').write_text(json.dumps({'url': 'http://127.0.0.1:1', 'key_file': str(tmp_path / 'key'),
                                                           'sketch_model': 'claude-opus-5-5'}))
    assert board_brain.load_model(tmp_path, None).sketch_model == 'claude-opus-5-5'
    lines = sse({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': '<svg>'}},
                {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': '</svg>'}})
    assert ''.join(meeting_board.text_deltas(lines)) == '<svg></svg>'
    assert meeting_board.svg_of('Sure! <svg viewBox="0 0 1 1"></svg> done') == '<svg viewBox="0 0 1 1"></svg>'
    assert meeting_board.svg_start('Here: <svg><rect') == '<svg><rect'


def test_a_block_sent_again_as_it_is_is_not_said_and_alone_says_no_change():
    same = lambda op: ({'ok': True, 'changed': [], 'what': '', 'same': True} if op['op'] == 'block'
                       else {'ok': True, 'what': 'Changed “Net retention”: target 110%', 'changed': ['nrr']})
    state = {'boards': [{'title': 'QBR', 'blocks': [{'id': 'k', 'type': 'stats', 'title': 'Key numbers', 'items': []}]}],
             'current': 1}

    class Says:
        def __init__(self, *edits):
            self.given = edits

        def edits(self, board, command, kind):
            yield from self.given
    block = ('block', {'id': 'k', 'type': 'stats', 'title': 'Key numbers'})
    room = PictureRoom(answer=same)
    board_brain.run_command(room, Says(block, ('item', {'id': 'nrr', 'block': 'k', 'target': '110%'})), state,
                            'Hermes, put on the board that the net retention target is 110', cmd='c1', any_text=True)
    assert [m['detail'] for m in room.msgs if m['t'] == 'caption' and m['state'] == 'done'] == [
        'Changed “Net retention”: target 110%']
    room = PictureRoom(answer=same)
    board_brain.run_command(room, Says(block), state, 'Hermes, put the key numbers on the board', cmd='c2', any_text=True)
    assert [m['detail'] for m in room.msgs if m['t'] == 'caption' and m['state'] == 'done'] == ['No change']


def test_a_picture_redrawn_is_asked_from_what_it_shows_as_well_as_the_change():
    room = PictureRoom(blocks=[{'id': 'arch', 'type': 'sketch', 'title': 'Systems', 'svg': SVG,
                                'brief': 'Our API calls Stripe; orders and payments share Postgres'}])
    job = board_brain.sketch_job(room, 1, {'id': 'arch', 'brief': 'Add Redis in front of orders'})
    assert (job['previous'], job['shows'], job['brief']) == (SVG, 'Our API calls Stripe; orders and payments share Postgres',
                                                             'Add Redis in front of orders')
    asked = meeting_board.sketch_request(job['title'], job['brief'], 'claude-sonnet-5-5', previous=job['previous'],
                                         shows=job['shows'])['messages'][0]['content']
    assert asked.endswith('What it shows: Our API calls Stripe; orders and payments share Postgres\n'
                          'The change to make: Add Redis in front of orders')
    assert 'What it shows' not in meeting_board.sketch_request('Systems', 'x', 'm')['messages'][0]['content']


def call_with_boards(app, service, clock, view=None, current=1):
    bot_id = start_call(app, service, clock)
    room = service.room_of(bot_id)
    room.update(boards=four_boards(), current=current, last=current, view=view or {'mode': 'one'})
    return bot_id, room, brain_of(app, bot_id)


def test_a_board_asked_for_by_name_is_on_screen_in_one_message_with_no_model(app, service, clock, scribe):
    bot_id, room, brain = call_with_boards(app, service, clock)
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, show the hiring board'))
    assert (result['kind'], result['board'], scribe.asked) == ('show', 3, [])
    assert sent(service, bot_id)[-2:] == ['show', 'done'] and room['current'] == 3
    assert room['msgs'][-1]['detail'] == 'Showing Design hire'
    brain.receive(heard(service, clock, bot_id, 'Hermes, put the launch board and the hiring board side by side'))
    assert (room['view'], room['current']) == ({'mode': 'split', 'boards': [1, 3]}, 3)
    brain.receive(heard(service, clock, bot_id, 'Hermes, show all the boards'))
    assert room['view'] == {'mode': 'all'}
    # A name no board has: nothing moves, and the status bar names the boards there are.
    brain.receive(heard(service, clock, bot_id, 'Hermes, show the marketing board'))
    assert room['view'] == {'mode': 'all'} and room['msgs'][-1]['state'] == 'failed'
    assert 'Say one of: Q1 launch, Pricing' in room['msgs'][-1]['detail']
    assert scribe.asked == []
    # Undo puts the screen back as it was before the last move.
    brain.receive(heard(service, clock, bot_id, 'Hermes, undo'))
    assert (room['view'], room['current']) == ({'mode': 'split', 'boards': [1, 3]}, 3)


def test_with_two_boards_side_by_side_a_change_goes_to_the_board_it_names_or_the_one_changed_last(app, service, clock, scribe):
    bot_id, room, brain = call_with_boards(app, service, clock, view={'mode': 'split', 'boards': [1, 3]}, current=1)
    brain.receive(heard(service, clock, bot_id, 'Hermes, add a risk to the hiring board: Priya starts in April'))
    assert scribe.asked[-1][0] == 'Design hire' and room['current'] == 3
    assert room['view'] == {'mode': 'split', 'boards': [1, 3]}, 'the screen stays as it is'
    assert room['msgs'][-1]['detail'].endswith(' on Design hire')
    # No board named: the one changed last.
    brain.receive(heard(service, clock, bot_id, 'Hermes, add a risk: the offer may be late'))
    assert scribe.asked[-1][0] == 'Design hire'
    brain.receive(heard(service, clock, bot_id, 'Hermes, add a goal to the launch board: ten pilots'))
    assert scribe.asked[-1][0] == 'Q1 launch' and room['current'] == 1


def test_a_change_to_a_board_not_on_screen_puts_it_on_screen_first(app, service, clock, scribe):
    bot_id, room, brain = call_with_boards(app, service, clock)
    brain.receive(heard(service, clock, bot_id, 'Hermes, add a question to the pricing board: annual discount?'))
    assert scribe.asked[-1][0] == 'Pricing' and room['current'] == 2
    told = sent(service, bot_id)
    assert told[-4:] == ['show', 'block', 'item', 'done']


def test_a_board_is_renamed_by_rule_and_the_name_kept_for_the_notes(app, service, clock, scribe):
    bot_id, room, brain = call_with_boards(app, service, clock)
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, call this board Launch plan'))
    assert (result['kind'], result['board'], scribe.asked) == ('edit', 1, [])
    assert room['boards'][0]['title'] == 'Launch plan'
    assert app.store.bot(bot_id)['boards'][0]['title'] == 'Launch plan'


def test_a_typed_command_that_starts_with_a_greeting_and_the_name_is_read_like_one_without():
    # The bot's tile tells people to say "Hey Hermes"; typed in the chat, the greeting comes with the command.
    assert meeting_board.bare('Hey Hermes, add a goal: ten paying pilots by March') == 'add a goal: ten paying pilots by March'
    assert meeting_board.intent('Hey Hermes, add a goal: ten paying pilots by March', True) == ('edit', None)
    assert meeting_board.intent('Okay. Hermes, add a risk: the review could slip', True) == ('edit', None)
    assert meeting_board.intent('ok hermes undo', True) == ('undo', None)
    # Only a greeting that opens the command goes; one elsewhere is part of what was said.
    assert meeting_board.bare('Mark the launch status OK, Hermes') == 'Mark the launch status OK'
    assert meeting_board.bare('say hi Hermes') == 'say hi'


# The four lines from a real call (2026-11-22) that left its boards empty, and what each does now.

@pytest.mark.parametrize('text, has_board, expected', [
    ('Hermes, start a whiteboard.', True, ('new', None)),
    # A request to see something drawn is for the board, with a board up or not, and asked as a question too.
    ('Hermes, draw a circle.', True, ('edit', None)),
    ('Hermes, draw a circle.', False, ('edit', None)),
    ('Hermes, can you show the visualization of Palestine and Israel?', False, ('edit', None)),
    ('Hermes, show me what a sales funnel looks like.', False, ('edit', None)),
    ('Hermes, can you show me how photosynthesis works?', False, ('edit', None)),
    ('Hermes, ugh, draw a circle.', True, ('edit', None)),
    # The last thing drawn said to be wrong, with something there to have been wrong.
    ("Hermes, that's not a circle.", True, ('edit', None)),
    ('Hermes, no, I said a square.', True, ('edit', None)),
    ("Hermes, that's not a circle.", False, None),
    # Frustration with nothing asked is nothing at all.
    ('Hermes, what the f---?', True, None),
    ('Hermes, what the hell is that?', True, None),
    ('Hermes, are you kidding me?', True, None),
    ('Hermes, ugh, come on.', True, None),
    # Still questions, and still not corrections.
    ('Hermes, what did we decide?', True, None),
    ('Hermes, okay, what did we decide?', True, None),
    ("Hermes, it's not due until Friday?", True, None),
])
def test_asks_to_draw_corrections_and_frustration_are_told_apart(text, has_board, expected):
    assert meeting_board.intent(text, has_board) == expected


def test_what_a_request_to_draw_names_is_its_pictures_title():
    assert meeting_board.subject('Hermes, draw a circle.') == 'Circle'
    assert meeting_board.subject('Hermes, can you show the visualization of Palestine and Israel?') == 'Palestine and Israel'
    assert meeting_board.subject("Hermes, that's not a circle.") == 'Circle'
    assert meeting_board.subject('Hermes, show me a comparison of iPhone and Android.') == 'iPhone and Android'
    for nothing in ('Hermes, draw it out.', 'Hermes, can you draw that?', "Hermes, that's not what I asked for.", 'Hermes, try again.'):
        assert meeting_board.subject(nothing) == '', nothing


def test_a_request_for_a_new_board_uses_an_empty_one_that_is_up():
    empty, hiring = {'title': 'Whiteboard', 'blocks': []}, {'title': 'Hiring', 'blocks': []}
    full = {'title': 'Q1 launch', 'blocks': [{'id': 'r', 'type': 'list', 'title': 'Risks', 'items': []}]}
    assert meeting_board.spare_board([empty], 1, 'Hermes, start a whiteboard.') == 1
    assert meeting_board.spare_board([empty, full], 2, 'Hermes, start a whiteboard.') == 1
    assert meeting_board.spare_board([full], 1, 'Hermes, start a whiteboard.') is None
    assert meeting_board.spare_board([empty], 1, 'Hermes, start another whiteboard.') is None
    # An empty board named for something else is kept for it, unless the request is for that name.
    assert meeting_board.spare_board([hiring], 1, 'Hermes, start a whiteboard.') is None
    assert meeting_board.spare_board([hiring], 1, 'Hermes, start a whiteboard for hiring', 'Hiring') == 1


def test_a_board_by_name_asked_for_with_an_empty_board_up_goes_on_that_board(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    brain = brain_of(app, bot_id)
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard.'))
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, start a retro for the launch'))
    room = service.room_of(bot_id)
    assert (result['kind'], result['board'], len(room['boards'])) == ('new', 1, 1)
    assert room['boards'][0]['title'] == 'Launch retro' and sent(service, bot_id)[-3:] == ['show', 'set', 'done']
    # With something on it, a new board is a new tab.
    scribe.plan = [('block', {'id': 'w', 'type': 'list', 'title': 'Went well'})]
    brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard.'))
    assert len(room['boards']) == 2


def test_the_four_lines_that_left_a_real_calls_boards_empty(app, service, clock, scribe, monkeypatch):
    drawn = []
    monkeypatch.setattr(board_brain, 'draw_sketch', lambda room, model, job, **kwargs: drawn.append(job))
    bot_id = start_call(app, service, clock, chat=True)
    brain = brain_of(app, bot_id)
    room = service.room_of(bot_id)

    def wait_for(count):
        for _ in range(100):
            if len(drawn) >= count:
                return
            threading.Event().wait(0.01)

    # 1. Said three times while the call would not let the bot share its screen: one board, put on screen again each time
    # (which asks the call for the share again), with no model.
    for _ in range(3):
        brain.receive(heard(service, clock, bot_id, 'Hermes, start a whiteboard.'))
    assert (len(room['boards']), room['current'], sent(service, bot_id).count('new'), sent(service, bot_id).count('show')) == (
        1, 1, 1, 2)
    assert room['msgs'][-1]['detail'] == 'Ready: say “Hey Hermes, draw …”' and scribe.asked == []

    # 2. The model drew nothing for "draw a circle": a picture of a circle all the same, and the board is named for it.
    scribe.plan = []
    result = brain.receive(heard(service, clock, bot_id, 'Hermes, draw a circle.'))
    wait_for(1)
    assert (result['kind'], result['board'], result['blocks']) == ('edit', 1, ['circle'])
    assert room['boards'][0]['title'] == 'Circle'
    assert [(b['id'], b['type'], b['title']) for b in room['boards'][0]['blocks']] == [('circle', 'sketch', 'Circle')]
    assert drawn[0]['brief'] == 'Circle, as asked in the meeting: "draw a circle."'
    assert room['msgs'][-1]['state'] == 'done'

    # 3. Frustration: the model is not asked, nothing changes, nothing is said (no "Got it", no text to the owner), and
    # the status bar goes back to what it showed.
    asked, boards, posted = len(scribe.asked), json.loads(json.dumps(room['boards'])), list(service.bots[bot_id]['posted'])
    event = heard(service, clock, bot_id, 'Hermes, what the f---?')
    assert brain.receive(event) is None
    assert (len(scribe.asked), room['boards'], service.bots[bot_id]['posted']) == (asked, boards, posted)
    assert room['msgs'][-1] == {'t': 'caption', 'state': 'idle', 'cmd': event['id']}
    assert meeting_bot.spoken_question({'text': 'Hermes, what the f---?', 'direct': True}) is None

    # 4. "That's not a circle": the model is told what the last change drew, and when it does nothing, the circle is drawn
    # again on its own block, never a new one.
    brain.receive(heard(service, clock, bot_id, "Hermes, that's not a circle."))
    wait_for(2)
    assert scribe.asked[-1][1] == """that's not a circle. (the change before this one was "draw a circle.", which drew circle)"""
    assert drawn[1]['id'] == 'circle' and drawn[1]['brief'].startswith('Said about this picture: "that\'s not a circle."')
    assert len(room['boards'][0]['blocks']) == 1 and room['msgs'][-1]['state'] == 'done'

    # 5. The model drew nothing for the visualization: a picture all the same, beside the circle.
    brain.receive(heard(service, clock, bot_id, 'Hermes, can you show the visualization of Palestine and Israel?'))
    wait_for(3)
    assert [b['title'] for b in room['boards'][0]['blocks']] == ['Circle', 'Palestine and Israel']
    assert drawn[2]['title'] == 'Palestine and Israel'
    assert not app.store.bot(bot_id).get('board_failed')


def test_a_request_to_draw_with_no_board_up_starts_one(app, service, clock, scribe):
    bot_id = start_call(app, service, clock)
    scribe.plan = [('block', {'id': 'cycle', 'type': 'flow', 'title': 'Water cycle'}),
                   ('item', {'id': 'e', 'block': 'cycle', 'text': 'Evaporation'})]
    result = brain_of(app, bot_id).receive(heard(service, clock, bot_id, 'Hermes, show me a visualization of the water cycle.'))
    room = service.room_of(bot_id)
    assert (result['kind'], result['board'], room['boards'][0]['title']) == ('new', 1, 'Water cycle')


class Says:
    """Stands in for the model: gives the edits it is made with, and notes what it was asked."""

    def __init__(self, *edits):
        self.given, self.asked = edits, []

    def edits(self, board, command, kind):
        self.asked.append(command)
        yield from self.given


def test_a_picture_the_model_draws_itself_needs_no_stand_in(monkeypatch):
    monkeypatch.setattr(board_brain.threading, 'Thread',
                        lambda target, args, kwargs, daemon: type('T', (), {'start': lambda self: None})())
    state = {'boards': [{'title': 'Whiteboard', 'blocks': []}], 'current': 1}
    # As the room answers: a new block's answer names it.
    room = PictureRoom(answer=lambda op: {'ok': True, **({'block': op['title']} if op['op'] == 'block' else {})})
    model = Says(('block', {'id': 'conflict', 'type': 'timeline', 'title': 'Israeli–Palestinian conflict'}),
                 ('item', {'id': 'e1', 'block': 'conflict', 'text': 'UN partition plan', 'when': '1947'}))
    board_brain.run_command(room, model, state, 'Hermes, can you show the visualization of Palestine and Israel?', cmd='c1',
                            any_text=True)
    ops = [m['op'] for m in room.msgs if m['t'] == 'op']
    assert [op['op'] for op in ops] == ['block', 'item', 'title'] and ops[-1]['text'] == 'Israeli–Palestinian conflict'
    # A request that names nothing to draw, with nothing made, is said again as before.
    room = PictureRoom()
    with pytest.raises(ValueError, match='Say it again'):
        board_brain.run_command(room, Says(), state, 'Hermes, draw it.', cmd='c2', any_text=True)
    # Nor is a picture made up for a correction with nothing drawn to correct and nothing named.
    with pytest.raises(ValueError, match='Say it again'):
        board_brain.run_command(PictureRoom(), Says(), state, 'Hermes, try again.', cmd='c3', any_text=True)


class Turns(Says):
    """Stands in for the model asked more than once: each ask gives the next set of edits."""

    def __init__(self, *turns):
        super().__init__()
        self.turns = list(turns)

    def edits(self, board, command, kind):
        self.asked.append((command, json.loads(json.dumps(board))))
        yield from self.turns.pop(0) if self.turns else ()


def test_a_block_asked_to_see_and_left_empty_is_filled_in():
    state = {'boards': [{'title': 'Whiteboard', 'blocks': []}], 'current': 1}
    room = PictureRoom(answer=lambda op: {'ok': True, **({'block': op['title']} if op['op'] == 'block' else {})})
    model = Turns([('block', {'id': 'refunds', 'type': 'flow', 'title': 'Refund process'})],
                  [('item', {'id': 's1', 'block': 'refunds', 'text': 'Customer asks'}),
                   ('item', {'id': 's2', 'block': 'refunds', 'text': 'Support checks the order'})])
    result = board_brain.run_command(room, model, state, 'Hermes, draw a flow chart for refunds.', cmd='c1', any_text=True)
    (first, _), (second, board) = model.asked
    assert first == 'Hermes, draw a flow chart for refunds.'
    assert second == ('draw a flow chart for refunds. (the flow “Refund process” (id refunds) is up but empty: add what goes '
                      'in it now. Change nothing else.)')
    assert board['blocks'] == [{'items': [], 'id': 'refunds', 'type': 'flow', 'title': 'Refund process'}]
    assert [m['op']['op'] for m in room.msgs if m['t'] == 'op'] == ['block', 'item', 'item', 'title']
    assert result['done'] == ['block', 'item', 'item'] and result['title'] == 'Refund process'
    # Filled in the first time, or a block nobody asked to see ("add a risks list"), is asked for once only.
    for said, turns in (('Hermes, draw a flow chart for refunds.', [[('block', {'id': 'r', 'type': 'flow', 'title': 'R'}),
                                                                     ('item', {'id': 's1', 'block': 'r', 'text': 'Ask'})]]),
                        ('Hermes, add a risks list.', [[('block', {'id': 'risks', 'type': 'list', 'title': 'Risks'})]])):
        model = Turns(*turns)
        board_brain.run_command(PictureRoom(), model, state, said, cmd='c2', any_text=True)
        assert len(model.asked) == 1


def test_a_block_said_to_be_wrong_is_asked_for_again_when_the_model_makes_no_edit():
    timeline = {'id': 'conflict', 'type': 'timeline', 'title': 'Key events',
                'items': [{'id': 'e1', 'text': 'UN partition plan', 'when': '1946'}]}
    room = PictureRoom(blocks=[timeline])
    model = Turns([], [('item', {'id': 'e1', 'block': 'conflict', 'text': 'UN partition plan', 'when': '1947'})])
    result = board_brain.run_command(room, model, room.state(), 'Hermes, try again.', cmd='c1', any_text=True,
                                     last={'board': 1, 'blocks': ['conflict'], 'text': 'show a timeline of the conflict.'})
    assert model.asked[1][0] == ('try again. (the change before this one was "show a timeline of the conflict.", which drew '
                                 'conflict) (the timeline “Key events” (id conflict) came out wrong: fix it now with block '
                                 'and item calls on its ids. Change nothing else.)')
    assert [m['op']['op'] for m in room.msgs if m['t'] == 'op'] == ['item'] and result['done'] == ['item']
    # With no word of the last change (a Hermes that started over), it is the last block on the board.
    model = Turns([], [])
    with pytest.raises(ValueError, match='Say it again'):
        board_brain.run_command(PictureRoom(blocks=[timeline]), model, room.state(), 'Hermes, try again.', cmd='c2',
                                any_text=True)
    assert 'the timeline “Key events” (id conflict) came out wrong' in model.asked[1][0]


def test_a_correction_the_model_makes_itself_redraws_on_the_same_block(monkeypatch):
    monkeypatch.setattr(board_brain.threading, 'Thread',
                        lambda target, args, kwargs, daemon: type('T', (), {'start': lambda self: None})())
    room = PictureRoom(blocks=[{'id': 'circle', 'type': 'sketch', 'title': 'Circle', 'brief': 'A circle', 'svg': SVG, 'items': []}])
    model = Says(('sketch', {'id': 'circle', 'brief': 'A true circle, round'}))
    result = board_brain.run_command(room, model, room.state(), "Hermes, that's not a circle.", cmd='c1', any_text=True,
                                     last={'board': 1, 'blocks': ['circle'], 'text': 'draw a circle.'})
    assert model.asked == ["""that's not a circle. (the change before this one was "draw a circle.", which drew circle)"""]
    ops = [m['op'] for m in room.msgs if m['t'] == 'op']
    assert len(ops) == 1 and ops[0]['id'] == 'circle' and 'type' not in ops[0] and ops[0]['drawing']
    assert result['blocks'] == ['circle']


def test_the_first_part_of_a_picture_shows_as_soon_as_there_is_something_to_see():
    room = PictureRoom()
    job = {'id': 'circle', 'n': 1, 'nonce': 'd1', 'title': 'Circle', 'brief': 'x', 'previous': None}
    # The clock never moves on: before, nothing showed until the whole picture, 1.2 s in at the earliest.
    assert board_brain.draw_sketch(room, Painter(SVG), job, clock=lambda: 0.0) == 'drawn'
    ops = [m['op'] for m in room.msgs if m['t'] == 'op']
    assert len(ops) == 2 and not ops[0].get('done') and ops[0]['svg'].startswith('<svg') and ops[1]['done']
