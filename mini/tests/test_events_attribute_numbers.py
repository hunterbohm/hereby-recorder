import pytest

from conftest import event, part, row
from lml_attribute import attribute
from lml_common import dt
from lml_events import BOUNDARY, current, owned, window_start
from lml_numbers import annotate, numbers, same_unit


@pytest.mark.parametrize('other_start', ['2026-10-13T09:30:00-05:00', '2026-10-13T09:00:00-05:00'])
def test_overlap_before_ranking(other_start):
    events = [event('first', '2026-10-13T09:00:00-05:00', '2026-10-13T10:00:00-05:00'),
              event('second', other_start, '2026-10-13T10:30:00-05:00')]
    result = current(dt('2026-10-13T09:45:00-05:00'), events)
    assert result.status == 'ambiguous'
    assert {e['key'] for e in result.events} == {'first', 'second'}


def test_adjacent_and_ranking():
    first = event('first', '2026-10-13T09:00:00-05:00', '2026-10-13T10:00:00-05:00')
    second = event('second')
    assert current(dt(second['start']), [first, second]).event == second
    assert window_start(second, [first, second]) == dt(second['start'])
    assert current(dt(second['start']), [second, second]).status == 'selected'
    distant = dict(event('distant', '2026-10-13T10:04:00-05:00'), has_conference=True)
    assert current(dt('2026-10-13T09:59:00-05:00'), [second, distant]).event == distant
    assert current(dt('2026-10-14T12:00:00-05:00'), [second]).status == 'none'


@pytest.mark.parametrize('partial', [False, True])
def test_part_ownership_before_after_finalization(partial):
    earlier = event('earlier', '2026-10-13T09:00:00-05:00', '2026-10-13T10:00:00-05:00')
    later = event('later')
    parts = [part('Goodbye.', '2026-10-13T09:59:58-05:00', later['start']),
             part('Budget is 42,500.', later['start'], '2026-10-13T10:00:12-05:00')]
    attributed = attribute([row(parts=parts, partial=partial)], {})
    assert [p['text'] for p in owned(attributed, later, [earlier, later])] == ['Budget is 42,500.']
    assert [p['text'] for p in owned(attributed, earlier, [earlier, later])] == ['Goodbye.']


def test_unsplit_boundary_in_both_events():
    earlier = event('earlier', '2026-10-13T09:00:00-05:00', '2026-10-13T10:00:00-05:00')
    later = event('later')
    parts = attribute([row(parts=[part('Goodbye. Budget is 42,500.', '2026-10-13T09:59:58-05:00', '2026-10-13T10:00:12-05:00')])], {})
    for target in [earlier, later]:
        result = owned(parts, target, [earlier, later])
        assert result[0]['boundary']
        assert result[0]['text'].startswith(BOUNDARY)


@pytest.mark.parametrize('reverse', [False, True])
@pytest.mark.parametrize('split_channel', ['me', 'them'])
def test_bleed_independent_of_arrival_order_and_segmentation(reverse, split_channel):
    a, b, c = ['2026-10-13T10:00:0' + str(i) + '-05:00' for i in (2, 4, 6)]
    whole = part('I will send the pricing sheet Friday', a, c, 1)
    halves = [part('I will send', a, b, 1), part('the pricing sheet Friday', b, c, 1)]
    local = [row(ch='me', parts=[p]) for p in (halves if split_channel == 'me' else [whole])]
    remote = [row(ch='them', parts=[p]) for p in (halves if split_channel == 'them' else [whole])]
    rows = remote + local if reverse else local + remote
    assert {p['ch'] for p in attribute(rows, {'them': [[a, c]]})} == {'them'}
    assert [p['ch'] for p in attribute(local, {'them': [[a, c]]})] == ['me?'] * len(local)


def overlapping_tracks():
    a, c = '2026-10-13T10:00:02-05:00', '2026-10-13T10:00:06-05:00'
    said = 'I will send the pricing sheet Friday'
    return [row(ch='me', parts=[part(said, a, c, 1)]), row(ch='them', parts=[part(said, a, c, 1)]),
            row(ch='me', seq=2, parts=[part('Sure', a, c, 1, words=None)])], {'them': [[a, c]]}


@pytest.mark.parametrize('source', ['phone', 'file'])
def test_two_track_imports_keep_real_overlap_as_spoken(source):
    rows, speech = overlapping_tracks()
    assert [(p['ch'], p['text']) for p in attribute(rows, speech, source)] == [
        ('me', 'I will send the pricing sheet Friday'), ('me', 'Sure'), ('them', 'I will send the pricing sheet Friday')]
    assert [p['ch'] for p in attribute(rows, speech, 'listener')] == ['me?', 'them']
    assert attribute(rows, speech) == attribute(rows, speech, 'listener')


@pytest.mark.parametrize('source', ['listener', 'phone', 'file'])
def test_call_channel_is_kept_as_call(source):
    mixed = row(ch='call', parts=[part('The deposit is 25 percent', xo=1, words=None)])
    remote = row(ch='them', parts=[part('The deposit is 25 percent')])
    assert [p['ch'] for p in attribute([mixed, remote], {'them': [[mixed['ts0'], mixed['ts1']]]}, source)] == ['call', 'them']


def test_crosstalk_and_mixed_row():
    bleed = part('I will send the pricing sheet', xo=1)
    reply = part('Thank you. I will check tomorrow.', '2026-10-13T10:14:05-05:00', '2026-10-13T10:14:09-05:00', 0)
    rows = [row(ch='me', parts=[bleed, reply]), row(ch='them', parts=[bleed])]
    result = attribute(rows, {'them': [[bleed['t0'], bleed['t1']]]})
    assert [p['text'] for p in result if p['ch'] == 'me'] == [reply['text']]
    cross = row(ch='me', parts=[part('The delivery should happen next Monday', xo=1)])
    assert any(p['ch'] == 'me' for p in attribute([cross, rows[1]], {'them': [[bleed['t0'], bleed['t1']]]}))


def test_incomplete_remote_partial_is_uncertain():
    mic = row(parts=[part('I will send the pricing sheet by Friday', xo=1)])
    remote = row(ch='them', partial=True, parts=[part('I will send', end='2026-10-13T10:14:02-05:00')])
    result = attribute([remote, mic], {'them': [[mic['ts0'], mic['ts1']]]})
    assert [p['ch'] for p in result if p['ch'] != 'them'] == ['me?']


def test_complete_remote_partial_can_remove_bleed():
    mic = row(parts=[part('I will send the pricing sheet by Friday', xo=1)])
    remote = row(ch='them', partial=True, parts=[part(mic['text'], end='2026-10-13T10:14:08-05:00')])
    assert {p['ch'] for p in attribute([mic, remote], {'them': [[mic['ts0'], mic['ts1']]]})} == {'them'}


def test_energy_coverage_uses_union_not_double_count():
    mic = row(parts=[part('I will send the pricing sheet by Friday', xo=1)])
    short = row(ch='them', parts=[part(mic['text'], end='2026-10-13T10:14:02-05:00')])
    assert any(p['ch'] == 'me?' for p in attribute([mic, short, short, short], {'them': [[mic['ts0'], mic['ts1']]]}))


@pytest.mark.parametrize('raw', ['425', '25', '42-5', '42 5', '42.5'])
def test_number_annotation_and_partial(raw):
    text = raw + ' for phase one'
    rendered = annotate(text, [('Budget is $42,500', 'brief, 2026-09-30')], partial=raw == '25')
    assert 'as transcribed' in rendered
    assert '$42,500 (brief, 2026-09-30)' in rendered
    if raw == '25':
        assert '25⟨unconfirmed⟩' in rendered


@pytest.mark.parametrize('raw', ['42-5', '42 5', '42.5'])
def test_bare_shorthand_without_reference(raw):
    assert 'possibly shorthand' in annotate(raw + ' for phase one', [])


def test_unrelated_numbers_and_power_of_ten():
    assert annotate('700 for phase one', [('Budget is $42,500', 'brief')]) == '700 for phase one'
    assert 'may be spoken shorthand' in annotate('4.25 for phase one', [('budget 42500', 'brief')])
    assert annotate('remote $25', [], partial=True, compare=False) == 'remote $25⟨unconfirmed⟩'
    assert numbers('$42,500')[0].value == 42500
    assert numbers('42.5k')[0].value == 42500
    assert not same_unit(numbers('budget $50')[0], numbers('50%')[0])


@pytest.mark.parametrize('partial', [False, True])
@pytest.mark.parametrize('fresh', [False, True])
def test_calendar_boundary_fallback_without_word_ranges(partial, fresh):
    earlier = event('earlier', '2026-10-13T09:00:00-05:00', '2026-10-13T10:00:00-05:00')
    later = event('later', window_start='1999-01-01T00:00:00Z')
    crossing = part('Goodbye. Budget is 42,500.', '2026-10-13T09:59:58-05:00',
                    '2026-10-13T10:00:12-05:00', words=None)
    parts = attribute([row(parts=[crossing], partial=partial, schedule_fresh=fresh)], {})
    for target in (earlier, later):
        result = owned(parts, target, [earlier, later])
        assert len(result) == 1 and result[0]['boundary']
        assert result[0]['text'] == BOUNDARY + ' ' + crossing['text']


def test_boundary_from_next_calendar_event_inside_previous_event():
    earlier = event('earlier', '2026-10-13T09:00:00-05:00', '2026-10-13T10:30:00-05:00')
    later = event('later')
    crossing = part('Budget is 42,500.', '2026-10-13T09:57:58-05:00',
                    '2026-10-13T09:58:12-05:00', words=None)
    parts = attribute([row(parts=[crossing], partial=True)], {})
    for target in (earlier, later):
        assert owned(parts, target, [earlier, later])[0]['boundary']


@pytest.mark.parametrize('remote_words', [None, [[0, 1]]])
def test_remote_result_range_cannot_supply_word_coverage(remote_words):
    mic = row(parts=[part('I will send the pricing sheet by Friday', xo=1)])
    remote = row(ch='them', partial=True, parts=[part('I will send', words=remote_words)])
    result = attribute([remote, mic], {'them': [[mic['ts0'], mic['ts1']]]})
    assert [p['ch'] for p in result if p['ch'] != 'them'] == ['me?']


@pytest.mark.parametrize('xo', [0.01, 0.49, 0.5, 1])
def test_mic_without_word_ranges_is_uncertain_during_any_overlap(xo):
    mic = row(parts=[part('My own reply', xo=xo, words=None)], partial=True)
    remote = row(ch='them', parts=[part('Different remote text')])
    result = attribute([mic, remote], {'them': [[mic['ts0'], mic['ts1']]]})
    assert [p['ch'] for p in result if p['ch'] != 'them'] == ['me?']


def test_mic_without_words_and_no_overlap_is_me():
    assert attribute([row(parts=[part('My reply', words=None)])], {})[0]['ch'] == 'me'


def test_word_ranges_are_relative_to_each_part_and_energy_is_the_denominator():
    mic = row(parts=[part('I will send the pricing sheet', xo=1)])
    remote = row(ch='them', parts=[part(mic['text'], '2026-10-13T10:13:59-05:00',
                                     '2026-10-13T10:14:10-05:00', words=[[2, 3], [4, 5]])])
    energy = {'them': [['2026-10-13T10:14:01-05:00', '2026-10-13T10:14:02-05:00'],
                       ['2026-10-13T10:14:03-05:00', '2026-10-13T10:14:04-05:00']]}
    assert {p['ch'] for p in attribute([mic, remote], energy)} == {'them'}


@pytest.mark.parametrize('duration,expected', [(4.49, 'me?'), (4.5, None)])
def test_word_energy_coverage_threshold(duration, expected):
    mic = row(parts=[part('I will send the pricing sheet', xo=1)])
    remote = row(ch='them', parts=[part(mic['text'], words=[[0, duration]])])
    locals = [p['ch'] for p in attribute([mic, remote], {'them': [[mic['ts0'], mic['ts1']]]})
              if p['ch'] != 'them']
    assert locals == ([] if expected is None else [expected])


@pytest.mark.parametrize('remote_words', [None, [[0, 1]]])
def test_truncated_remote_partial_with_long_range_remains_uncertain(remote_words):
    mic = row(parts=[part('I will send the pricing sheet by Friday', xo=1)])
    remote = row(ch='them', partial=True, parts=[part('I will send',
                 end='2026-10-13T10:14:08-05:00', words=remote_words)])
    result = attribute([mic, remote], {'them': [[mic['ts0'], mic['ts1']]]})
    assert [p['ch'] for p in result if p['ch'] != 'them'] == ['me?']
