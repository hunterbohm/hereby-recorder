from decimal import Decimal

import pytest

from lml_numbers import annotate, numbers, possible_shorthand


@pytest.mark.parametrize('text,expected', [
    ('Retainer discount is fifteen percent for a twelve month commitment.', [(15, 'percent'), (12, 'number')]),
    ('Sam agreed to a three week cutover', [(3, 'number')]),
    ('twenty-five thousand dollars', [(25000, 'USD')]),
    ('one more thing, one percent', [(1, 'percent')]),
])
def test_spelled_out_numbers(text, expected):
    assert [(n.value, n.unit) for n in numbers(text)] == [(Decimal(v), u) for v, u in expected]


def test_single_digits_are_not_shorthand_for_longer_numbers():
    three, two_thirty = numbers('3 weeks')[0], numbers('230 people')[0]
    assert not possible_shorthand(three, two_thirty)
    assert not possible_shorthand(numbers('December 1st')[0], numbers('twelve months')[0])
    assert possible_shorthand(numbers('425 for phase one')[0], numbers('$42,500 for phase one')[0])


def test_answer_annotation_has_no_single_digit_noise():
    text = "I'll double check, but my notes say 6 weeks, starting December 1st."
    assert 'shorthand' not in annotate(text, [('Retainer is fifteen percent for twelve months.', 'brief')])
