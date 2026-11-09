import json

import pytest

from conftest import make_session, part, row
from live_answer import context
from live_meeting_nudge import tick
from lml_common import read_json, read_jsonl, select_session


def test_unterminated_final_line_is_ignored_even_when_it_parses(tmp_path):
    path = tmp_path / 'transcript.jsonl'
    path.write_bytes(b'{"seq": 1}\n{"seq": 2}')
    assert read_jsonl(path) == [{'seq': 1}]
    path.write_bytes(b'{"seq": 1}\n{"seq": 2}\n')
    assert read_jsonl(path) == [{'seq': 1}, {'seq': 2}]


def test_tail_cut_inside_a_multibyte_character(tmp_path):
    path = tmp_path / 'transcript.jsonl'
    path.write_bytes(b'{"text": "caf\xc3\xa9"}\n{"text": "caf\xc3')
    assert read_jsonl(path) == [{'text': 'café'}]


def test_in_person_phone_session_with_marks_is_read(root, now, hermes):
    rows = [row('We said the deposit is 25 percent.', seq=1, ch='room')]
    path = make_session(root, now, rows=rows, kind='in_person', source='phone')
    (path / 'marks.jsonl').write_text(json.dumps({'at': now.isoformat(), 'note': None}) + '\n'
                                      + json.dumps({'at': now.isoformat(), 'note': 'half'}))
    with (path / 'transcript.jsonl').open('a') as stream:
        stream.write(json.dumps(row('partial line', seq=2, ch='room')))
    session = select_session(root, now)
    assert session.sid == path.name
    assert [r['seq'] for r in session.transcript()] == [1]
    assert 'room: We said the deposit is 25' in context(root, session, now, 'What deposit?')
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes) == ''
    assert not hermes.calls


class Screen:
    def __init__(self):
        self.packets = []

    def __call__(self, prompt):
        self.packets.append(json.loads(prompt[prompt.index('{"records"'):]))
        return {'nudge': False}


@pytest.mark.parametrize('source,label', [('phone', 'me'), ('file', 'me'), ('listener', 'me?'), (None, 'me?'), ('radio', 'me?')])
def test_bleed_marking_follows_the_session_source(root, now, hermes, source, label):
    spoken = row(parts=[part('The budget is $70,000.', xo=1, words=None)])
    meta = {'source': source} if source else {}
    make_session(root, now, rows=[spoken], speech={'them': [[spoken['ts0'], spoken['ts1']]]}, **meta)
    assert f'[10:14:00] {label}: The budget is $70,000.' in context(root, select_session(root, now), now, 'Budget?')
    screen = Screen()
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=screen) == ''
    assert [[h['ch'] for h in p['hits']] for p in screen.packets] == ([['me']] if label == 'me' else [])
    assert not hermes.calls


def mixed_call(root, now, first='call'):
    rows = [row('Phase one is $42,500.', seq=1, ch=first),
            row(seq=2, ch='call', parts=[part('425 for phase one', '2026-10-13T10:14:06-05:00', '2026-10-13T10:14:09-05:00')])]
    make_session(root, now, rows=rows, source='file')
    return context(root, select_session(root, now), now, 'What amount?')


def test_mixed_call_audio_is_neither_sam_nor_the_other_side(root, now, hermes):
    assert 'call: 425 [as transcribed; may be spoken shorthand for $42,500 (them, 2026-10-13)] for phase one' in mixed_call(
        root, now, first='them')
    packet = mixed_call(root, now)
    assert '[10:14:00] call: Phase one is $42,500.' in packet and '[10:14:06] call: 425 for phase one\n' in packet + '\n'
    assert '(them, ' not in packet
    screen = Screen()
    assert tick(root=root, now=now, runner=hermes, hermes_runner=hermes, screen=screen) == ''
    assert screen.packets == [] and not hermes.calls
    assert read_json(root / 'nudges/20261013-100000-abcd.state.json')['cursor'] == 2
