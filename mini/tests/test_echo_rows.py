import pytest

from conftest import part, row
from lml_attribute import attribute

START, END = '2026-10-13T10:00:02-05:00', '2026-10-13T10:00:06-05:00'


def said(ch, text, start=START, end=END, **kwargs):
    return row(ch=ch, parts=[part(text, start, end)], **kwargs)


def texts(parts):
    return [(p['ch'], p['text']) for p in parts]


@pytest.mark.parametrize('call_first', [True, False])
def test_mic_row_repeating_the_call_is_dropped_whichever_finalized_first(call_first):
    call, mic = said('them', 'I will send the pricing sheet Friday', seq=1), said('me', 'I will send the pricing sheet Friday', seq=2)
    rows = [call, mic] if call_first else [mic, call]
    assert texts(attribute(rows, {})) == [('them', 'I will send the pricing sheet Friday')]


def test_mic_row_with_different_words_while_the_call_talks_is_kept():
    rows = [said('them', 'the renewal moves to Friday'), said('me', 'wait can we push that to Monday')]
    assert {p['ch'] for p in attribute(rows, {})} == {'me', 'them'}


def test_same_word_spoken_at_a_different_moment_is_kept():
    later = ('2026-10-13T10:00:10-05:00', '2026-10-13T10:00:11-05:00')
    rows = [said('them', 'yeah'), said('me', 'yeah', *later)]
    assert texts(attribute(rows, {})) == [('them', 'yeah'), ('me', 'yeah')]


def test_mic_row_that_is_partly_echo_stays_whole():
    mic = said('me', 'so the renewal moves to Friday okay but I need the draft first')
    assert [p['text'] for p in attribute([said('them', 'so the renewal moves to Friday'), mic], {}) if p['ch'] == 'me'] == [mic['text']]


def test_only_a_listener_session_looks_for_echo():
    rows = [said('them', 'I will send the pricing sheet Friday'), said('me', 'I will send the pricing sheet Friday')]
    assert {p['ch'] for p in attribute(rows, {}, 'phone')} == {'me', 'them'}


def test_mic_partial_repeating_the_call_partial_is_dropped():
    rows = [dict(said('them', 'we can start the migration next week'), partial=True), dict(said('me', 'we can start the migration'), partial=True)]
    assert texts(attribute(rows, {})) == [('them', 'we can start the migration next week')]
