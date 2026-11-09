#!/usr/bin/env python3
import argparse
import sys
from datetime import timedelta
from pathlib import Path

from lml_common import atomic_write, dt, load_sessions, locked, now_local, read_json, root_path

LEAD = timedelta(minutes=10)
GRACE = timedelta(minutes=3)
STALE = timedelta(minutes=3)
KEEP = timedelta(days=2)
ACCESS = (('mic_ok', 'microphone'), ('audio_ok', 'system audio'))


def _when(value):
    try:
        return dt(value)
    except (TypeError, ValueError):
        return None


def problem(heartbeat, now):
    received = _when(heartbeat.get('received_at')) if isinstance(heartbeat, dict) else None
    if received is None:
        return 'the recorder on the MacBook has not checked in'
    if now - received > STALE:
        return f'the recorder on the MacBook last checked in {int((now - received).total_seconds() // 60)} minutes ago'
    missing = [name for key, name in ACCESS if heartbeat.get(key) is not True]
    return f"the recorder has no {' or '.join(missing)} access" if missing else ''


def due(schedule, now):
    events = schedule.get('events') if isinstance(schedule, dict) else None
    soon = []
    for event in events if isinstance(events, list) else []:
        try:
            start, key = dt(event['start']), str(event['key'])
        except (KeyError, TypeError, ValueError):
            continue
        if (event.get('meeting_url') or event.get('has_conference')) and timedelta(0) < start - now <= LEAD:
            soon.append((start, key, event))
    return sorted(soon, key=lambda item: item[:2])


def underway(schedule, now):
    """Calls that started at least GRACE ago and have not ended, keyed apart from the before-call alert."""
    events = schedule.get('events') if isinstance(schedule, dict) else None
    result = []
    for event in events if isinstance(events, list) else []:
        try:
            start, end, key = dt(event['start']), dt(event['end']), str(event['key'])
        except (KeyError, TypeError, ValueError):
            continue
        if (event.get('meeting_url') or event.get('has_conference')) and start + GRACE <= now < end:
            result.append((start, 'live:' + key, event))
    return sorted(result, key=lambda item: item[:2])


def recording(root, now):
    return any(s.is_live(now) and not s.meta.get('test') for s in load_sessions(root, now))


def capture_issue(heartbeat, now):
    """The alert key and text when the recorder is recording but reports no mic or system audio, else None.
    The Mac reports a mic that will not start or hears only zeros as mic_ok false."""
    if not isinstance(heartbeat, dict) or heartbeat.get('state') != 'recording' or not heartbeat.get('sid'):
        return None
    received = _when(heartbeat.get('received_at'))
    if received is None or now - received > STALE:
        return None
    missing = [name for key, name in ACCESS if heartbeat.get(key) is False]
    if not missing:
        return None
    return ('capture:' + str(heartbeat['sid']),
            f"The recorder is recording but is getting no {' or '.join(missing)} audio. "
            "Check the input device in Sound settings, or press Stop and then Start in the recorder's menu bar.")


def alerted(root, now):
    state = read_json(Path(root) / 'health.json', {})
    sent = state.get('alerted') if isinstance(state, dict) else None
    if not isinstance(sent, dict):
        return {}
    return {key: at for key, at in sent.items() if (when := _when(at)) and now - when < KEEP}


def alerts(soon, issue, sent, now):
    return [(key, f"Recorder problem before {event.get('title') or 'your meeting'} at "
                  f"{start.astimezone(now.tzinfo).strftime('%I:%M %p').lstrip('0')}: {issue}.")
            for start, key, event in soon if key not in sent]


def live_alerts(calls, issue, sent, now):
    return [(key, f"The recorder is not recording {event.get('title') or 'your call'} "
                  f"(started {start.astimezone(now.tzinfo).strftime('%I:%M %p').lstrip('0')}): {issue}. "
                  "If you are on the call, press Start in the recorder's menu bar.")
            for start, key, event in calls if key not in sent]


def check(root, now, *, dry_run=False):
    """The text to send, else ''. Once per meeting each: a call starts within 10 minutes and the recorder is not
    ready, a call has been underway 3 minutes with no live recording, or a recording gets no mic or system audio."""
    root = Path(root)
    schedule = read_json(root / 'schedule.json', {})
    soon, calls = due(schedule, now), underway(schedule, now)
    beat = read_json(root / 'heartbeat.json')
    issue = problem(beat, now) if soon else ''
    live_issue = (problem(beat, now) or 'no session is running') if calls and not recording(root, now) else ''
    capture = capture_issue(beat, now)
    def pending(sent):
        return ((alerts(soon, issue, sent, now) if issue else []) + (live_alerts(calls, live_issue, sent, now) if live_issue else [])
                + ([capture] if capture and capture[0] not in sent else []))
    if not issue and not live_issue and not capture:
        return ''
    if dry_run:
        text = '\n'.join(line for _, line in pending(alerted(root, now)))
        if text:
            print('[ALERT WOULD SEND] ' + text, file=sys.stderr, flush=True)
        return ''
    with locked(root / '.health.lock'):
        sent = alerted(root, now)
        new = pending(sent)
        if new:
            atomic_write(root / 'health.json', {'alerted': {**sent, **{key: now.isoformat() for key, _ in new}}})
    return '\n'.join(line for _, line in new)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--print', action='store_true', dest='print_only')
    args = parser.parse_args()
    try:
        text = check(root_path(), now_local(), dry_run=args.print_only)
    except Exception:
        print('Recorder health check failed.', file=sys.stderr)
        return 0
    if text:
        print(text, flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
