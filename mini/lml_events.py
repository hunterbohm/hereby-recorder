from dataclasses import dataclass
from datetime import timedelta

from lml_common import dt

BOUNDARY = '(spans the meeting boundary)'


@dataclass(frozen=True)
class Selection:
    status: str
    events: tuple = ()

    @property
    def event(self):
        return self.events[0] if self.status == 'selected' else None


def current(now, events):
    distinct = {event['key']: event for event in events}
    candidates = [event for event in distinct.values()
                  if dt(event['start']) - timedelta(minutes=5) <= now <= dt(event['end']) + timedelta(minutes=10)]
    active = [event for event in candidates if dt(event['start']) <= now < dt(event['end'])]
    if len(active) > 1:
        return Selection('ambiguous', tuple(sorted(active, key=lambda e: e['key'])))
    if active:
        return Selection('selected', (active[0],))
    if not candidates:
        return Selection('none')
    event = min(candidates, key=lambda e: (not e.get('has_conference', False),
                                         abs((dt(e['start']) - now).total_seconds()), e['key']))
    return Selection('selected', (event,))


def is_meeting(event):
    return event.get('attendee_count', 0) >= 2 or bool(event.get('has_conference'))


def window_start(event, events):
    start = dt(event['start'])
    ends = [dt(e['end']) for e in events if e['key'] != event['key'] and
            start - timedelta(minutes=2) < dt(e['end']) <= start]
    if event.get('window_start'):
        saved = dt(event['window_start'])
        if start - timedelta(minutes=2) <= saved <= start:
            ends.append(saved)
    return max([start - timedelta(minutes=2), *ends])


def owned(parts, event, events):
    start, end = window_start(event, events), dt(event['end'])
    boundaries = {window_start(e, events) for e in events}
    result = []
    for part in parts:
        t0, t1 = dt(part['t0']), dt(part['t1'])
        if t1 <= start or t0 >= end:
            continue
        boundary = t0 < end < t1 or any(t0 < b < t1 for b in boundaries)
        result.append(dict(part, boundary=boundary,
                           text=(BOUNDARY + ' ' if boundary else '') + part['text']))
    return result
