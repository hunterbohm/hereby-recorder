from pathlib import Path

from live_answer import context
from lml_attribute import attribute
from lml_common import atomic_write, dt, read_json, select_session


def test_mbp_snapshot_word_offsets_null_partial_and_fractional_utc(root, now):
    path = root / 'sessions/20261013-100000-abcd'
    meta = read_json(path / 'meta.json')
    meta.update(started_at='2026-10-13T15:00:00.125Z', heartbeat_at='2026-10-13T15:14:59.875Z')
    atomic_write(path / 'meta.json', meta)
    fixtures = Path(__file__).parent / 'fixtures'
    atomic_write(path / 'live.json', (fixtures / 'mbp_live.json').read_text())
    atomic_write(path / 'transcript.jsonl', (fixtures / 'mbp_transcript.jsonl').read_text())
    session = select_session(root, now)
    assert session.sid == '20261013-100000-abcd'
    assert session.is_live(now)
    assert session.live['finals'] == []
    rows = session.rows(now)
    assert len(rows) == 4
    assert [r['partial'] for r in rows] == [False, False, False, True]
    assert rows[0]['parts'][0]['words'][-1] == [1.5, 3.0]
    assert rows[-1]['ch'] == 'me' and rows[-1]['parts'][0]['words'] is None
    assert dt(rows[0]['parts'][0]['t0']).microsecond == 125000
    parts = attribute(rows, session.live['speech'])
    assert [(p['ch'], p['text']) for p in parts] == [
        ('me', 'Old discussion.'),
        ('them', 'The budget is $70,000.'),
        ('me', 'I will send the pricing sheet.'),
        ('me?', 'The deposit is 25.'),
    ]
    assert parts[-1]['partial'] and parts[-1]['words'] is None
    packet = context(root, session, now, 'What did we agree?')
    assert '[15:14:00] them: The budget is $70,000.' in packet
    assert '[15:14:04] me: I will send the pricing sheet.' in packet
    assert '[15:14:07] me?: The deposit is 25⟨unconfirmed⟩.' in packet
    assert '(still being transcribed)' in packet
    assert packet.count('The budget is $70,000.') == 1
    assert 'Old discussion.' not in packet
