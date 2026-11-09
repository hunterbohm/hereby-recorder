import re
from bisect import bisect_left, bisect_right
from datetime import timedelta

from lml_common import dt


def _merged(intervals):
    result = []
    for start, end in sorted(intervals):
        if end <= start:
            continue
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(end, result[-1][1]))
        else:
            result.append((start, end))
    return result


def _seconds(intervals):
    return sum((end - start).total_seconds() for start, end in _merged(intervals))


def _tokens(text):
    return set(re.findall(r'\w+', text.casefold()))


ECHO_TOLERANCE = 1.0
ECHO_SHARE = 0.8


def _spoken(row):
    """(token, time) for each word of a row, or None when any part lacks word timing."""
    result = []
    for part in row['parts']:
        timings, texts = part.get('words'), part['text'].split()
        if timings is None or len(texts) != len(timings):
            return None
        for text, (start, _) in zip(texts, timings):
            token = ''.join(c for c in text.casefold() if c.isalnum())
            if token:
                result.append((token, dt(part['t0']).timestamp() + start))
    return result


def _is_echo(row, theirs):
    """A mic row whose words each match a call word spoken within a second is the speakers' sound, not the user.
    `theirs` is the call's (time, token) words sorted by time. Mirrors EchoGate in the Mac recorder, which cannot
    see a call row that finalizes after the mic row."""
    mine = _spoken(row)
    if not mine:
        return False
    times = [a for a, _ in theirs]
    low, high = bisect_left(times, min(a for _, a in mine) - ECHO_TOLERANCE), bisect_right(times, max(a for _, a in mine) + ECHO_TOLERANCE)
    nearby = theirs[low:high]
    matched = 0
    for token, at in mine:
        near = [i for i, (a, t) in enumerate(nearby) if t == token and abs(a - at) <= ECHO_TOLERANCE]
        if near:
            nearby.pop(min(near, key=lambda i: abs(nearby[i][0] - at)))
            matched += 1
    return matched / len(mine) >= ECHO_SHARE


def attribute(rows, speech, source='listener'):
    """Label each part by speaker. Only the listener's mic hears the other side through the speakers, so only
    a listener session checks its mic parts for bleed (me?) and echo."""
    bleed = source == 'listener'
    remote = [r for r in rows if r['ch'] == 'them']
    if bleed:
        theirs = sorted((a, t) for r in remote for t, a in _spoken(r) or [])
        rows = [r for r in rows if r['ch'] != 'me' or not _is_echo(r, theirs)]
    energy = [(dt(a), dt(b)) for a, b in speech.get('them', [])]
    remote_parts = [p for r in remote for p in r['parts'] if p.get('words') is not None]
    word_ranges = [(dt(p['t0']) + timedelta(seconds=a), dt(p['t0']) + timedelta(seconds=b))
                   for p in remote_parts for a, b in p['words']]
    result = []
    for row in rows:
        for part in row['parts']:
            label = row['ch']
            if bleed and label == 'me' and part.get('words') is None and part['xo'] > 0:
                label = 'me?'
            elif bleed and label == 'me' and part['xo'] >= 0.5:
                start, end = dt(part['t0']) - timedelta(seconds=2), dt(part['t1']) + timedelta(seconds=2)
                frames = [(max(a, start), min(b, end)) for a, b in energy if a < end and b > start]
                covered = [(max(a, c), min(b, d))
                           for a, b in frames for c, d in word_ranges if c < b and d > a]
                duration = _seconds(frames)
                coverage = _seconds(covered) / duration if duration else 0
                if coverage < 0.9:
                    label = 'me?'
                else:
                    words = _tokens(part['text'])
                    theirs = set().union(*(_tokens(p['text']) for p in remote_parts
                                           if dt(p['t0']) < end and dt(p['t1']) > start))
                    if words and len(words & theirs) / len(words) >= 0.6:
                        continue
            result.append(dict(part, ch=label, seq=row.get('seq'), partial=row.get('partial', False)))
    return sorted(result, key=lambda p: (dt(p['t0']), p['ch']))
