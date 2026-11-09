from conftest import event, make_session, part, row
from lml_common import atomic_write, dt
from lml_numbers import annotate
from lml_records import Record
from live_answer import answer
from live_meeting_nudge import gate


def test_recent_session_answers_use_its_own_event_not_the_next_one(root, hermes):
    now = dt('2026-10-13T10:06:00-05:00')
    first = event('first', '2026-10-13T09:00:00-05:00', '2026-10-13T10:00:00-05:00')
    second = event('second', '2026-10-13T10:05:00-05:00', '2026-10-13T10:35:00-05:00')
    atomic_write(root / 'schedule.json', {'events': [first, second]})
    atomic_write(root / 'briefs/first.md', '# First meeting')
    atomic_write(root / 'briefs/second.md', '# Second meeting')
    said = row(ch='them', parts=[part('We ship on the twelfth.', '2026-10-13T09:58:00-05:00', '2026-10-13T09:58:04-05:00')])
    make_session(root, now, rows=[said], state='closed', started_at='2026-10-13T09:00:00-05:00',
                 ended_at='2026-10-13T10:00:00-05:00')
    answer('When do they ship?', root=root, now=now, runner=hermes)
    prompt = hermes.prompts[0]
    assert 'We ship on the twelfth.' in prompt
    assert 'Event first' in prompt and 'Event second' not in prompt


def test_unchanged_phase_number_does_not_hide_a_budget_mismatch(now):
    current, prior = 'The budget is $15,000 for phase 1', 'The budget is $10,000 for phase 1'
    parts = [dict(part(current), ch='me', seq=1, partial=False, boundary=False)]
    value = dict(nudge=True, kind='wrong_number', current_quote=current, current_seq=1, record_quote=prior,
                 record_source='last.md', record_date='2026-09-30', subject='budget',
                 text='The prior budget was $10,000.')
    assert gate(value, parts, {1}, [Record('last.md', '2026-09-30', prior)], now.date()) == ''


def test_answer_annotation_skips_self_and_unchanged_numbers():
    text = 'Phase 1 is $15,000.'
    references = [(text, 'them, 2026-10-13'), ('Phase 1 is $10,000.', 'brief, 2026-09-30')]
    assert 'shorthand' not in annotate(text, references)
    assert 'shorthand for $42,500' in annotate('Phase 1 is 425.', [('Phase 1 is $42,500.', 'brief, 2026-09-30')])
