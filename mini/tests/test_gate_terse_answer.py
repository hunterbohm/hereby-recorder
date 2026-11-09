import pytest

from conftest import part
from lml_records import Record
from live_meeting_nudge import gate

PRIOR = 'Retainer discount is fifteen percent for a twelve month commitment.'


def p(text, start, end, ch='me', seq=24, partial=False):
    return dict(part(text, f'2026-10-13T10:14:{start:02d}-05:00', f'2026-10-13T10:14:{end:02d}-05:00'),
                ch=ch, seq=seq, partial=partial, boundary=False)


def question(start=40):
    return p('The retainer was 15% off if we commit for 12 months, right?', start, start + 4, ch='them', seq=25)


def answer(middle_partial=False):
    return [p('10%', 45, 46), p('for 12', 46, 47, partial=middle_partial), p('months.', 47, 48)]


def candidate():
    return dict(nudge=True, kind='wrong_number', current_quote='10% for 12 months.', current_seq=24,
                record_quote=PRIOR, record_source='last.md', record_date='2026-09-30', subject='Retainer discount',
                text='On Sep 30 the retainer discount was 15% for 12 months, not 10%.')


@pytest.mark.parametrize('parts,reason', [
    (answer() + [question()], ''),
    (answer(middle_partial=True) + [question()], 'current_quote'),
    (answer() + [question(start=10)], 'subject'),
    (answer(), 'subject'),
])
def test_terse_answer_to_a_question_is_grounded_by_the_question(now, parts, reason):
    record = Record('last.md', '2026-09-30', PRIOR)
    assert gate(candidate(), parts, {24, 25}, [record], now.date()) == reason
