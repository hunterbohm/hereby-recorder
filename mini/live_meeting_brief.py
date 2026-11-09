#!/usr/bin/env python3
import csv
import functools
import hashlib
import importlib.util
import json
import re
import sys
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path

from lml_common import (atomic_write, config, dt, locked, now_local,
                        read_json, read_jsonl, root_path, safe_key)
from lml_events import is_meeting, window_start
from lml_hermes import forget, run_command
from lml_notes import front_matter, links, section
from lml_records import Record
import lml_settings

MAX_BYTES = 12000
NEXT_LOOKAHEAD_DAYS = 7
VOCABULARY_LIMIT = 100
CALL_HOST = re.compile(r'(?:^|\.)(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com)$', re.I)


def collectors(collector):
    if collector is None:
        raise lml_settings.SettingsError(lml_settings.path(), 'calendar_collector', 'must be set to read the calendar')
    # The collector imports modules that sit beside it.
    if str(collector.parent) not in sys.path:
        sys.path.insert(0, str(collector.parent))
    spec = importlib.util.spec_from_file_location('_lml_prep', collector)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _read(path, limit=None):
    try:
        text = Path(path).read_text(encoding='utf-8')
        return text[:limit] if limit else text
    except OSError:
        return ''


@dataclass(frozen=True)
class Note:
    path: Path
    meta: dict
    body: str
    folded: str = ''


@dataclass(frozen=True)
class Vault:
    root: Path = Path()
    people: tuple = ()
    meetings: tuple = ()
    projects: tuple = ()


def load_vault(vault, project_map=None):
    contacts = Path(vault) / '06 - Contacts'
    people, meetings = [], []
    for path in sorted(contacts.rglob('*.md')):
        text = _read(path)
        meta, body = front_matter(text)
        if 'Meetings' in path.relative_to(contacts).parts:
            meetings.append(Note(path, meta, body))
        elif 'person' in meta.get('types', []):
            people.append(Note(path, meta, body, text.casefold()))
    try:
        with Path(project_map).open(encoding='utf-8') as stream:
            projects = tuple(csv.DictReader(stream, delimiter='\t'))
    except (OSError, TypeError):
        projects = ()
    return Vault(Path(vault), tuple(people), tuple(meetings), projects)


def attendee_people(event, vault):
    emails = {a.get('email', '').casefold() for a in event['attendees'] if a.get('email')}
    return [p for p in vault.people if any(email in p.folded for email in emails)]


def prior_meetings(event, vault, people):
    names = set()
    for person in people:
        names.add(person.path.stem.casefold())
        names.update(links(person.meta.get('aliases', [])))
    prior = [m for m in vault.meetings if
             (links(m.meta.get('people', [])) & names
              or re.sub(r'^\d{4}-\d{2}-\d{2}\s*[- ]*', '', m.path.stem).casefold() == event['title'].casefold())
             and (not m.meta.get('event_id') or m.meta['event_id'] != event.get('raw', {}).get('id'))
             and str(m.meta.get('date', ''))[:10] < dt(event['start']).date().isoformat()
             and re.fullmatch(r'\d{4}-\d{2}-\d{2}', str(m.meta.get('date', ''))[:10])]
    prior.sort(key=lambda m: (str(m.meta['date']), m.path.name), reverse=True)
    return prior[:3]


def project_refs(meetings):
    refs = []
    for meeting in meetings:
        for key in ('project', 'org'):
            value = meeting.meta.get(key, '')
            refs.extend(value if isinstance(value, list) else [value] if value else [])
    return refs


def project_rows(refs, vault):
    for ref in sorted(set(refs)):
        name = ref.strip('[]').split('|')[0]
        for row in vault.projects:
            if name.casefold() in {row.get('vault_note', '').removesuffix('.md').split('/')[-1].casefold(),
                                   row.get('client', '').casefold()}:
                yield row


def vault_context(event, vault):
    people = attendee_people(event, vault)
    prior = prior_meetings(event, vault, people)
    record_items = []
    for meeting in prior:
        date = str(meeting.meta['date'])[:10]
        summary = section(meeting.body, ['Summary', 'Decisions'])
        if summary:
            record_items.append(Record(str(meeting.path), date, meeting.path.stem + '\n' + summary))
        actions = section(meeting.body, ['Action items', 'Next steps'])
        for line in actions.splitlines():
            if not line.strip() or re.search(r'^\s*-\s*\[[xX]\]', line):
                continue
            due = re.search(r'\b\d{4}-\d{2}-\d{2}\b', line)
            record_items.append(Record(str(meeting.path), date, line, 'action_item', due.group() if due else ''))
    projects = []
    for row in project_rows(project_refs(prior), vault):
        note = vault.root / row['vault_note']
        if not note.suffix:
            note = note.with_suffix('.md')
        projects.append(str(note) + '\n' + _read(note, 1500))
        target = Path(row.get('target', '')).expanduser()
        status = target / 'status.md' if target.is_dir() else target
        if str(target) != '.':
            projects.append(str(status) + '\n' + _read(status, 1500))
    people_text = [f"{p.path.stem}, org: {p.meta.get('org', '')}, role: {p.meta.get('role', '')}\n{p.body[:600]}"
                   for p in people]
    return people_text, projects, record_items


def _terms(value):
    for item in value if isinstance(value, list) else [value]:
        item = str(item or '')
        links = [link.split('|')[0].split('#')[0].split('/')[-1] for link in re.findall(r'\[\[([^\]]+)\]\]', item)]
        # front_matter reads an unquoted [[Link]] as the list ['[Link]'].
        yield from (name.strip(' "\'[]') for name in links or [item])


def vocabulary(event, vault):
    people = attendee_people(event, vault)
    own = [m for m in vault.meetings if event.get('event_id') and m.meta.get('event_id') == event['event_id']]
    refs = project_refs(own + prior_meetings(event, vault, people))
    candidates = [*(a.get('name', '') for a in event['attendees'] if a.get('name') != a.get('email', '').split('@')[0]),
                  *(p.path.stem for p in people),
                  *(p.meta.get('org', '') for p in people),
                  *refs,
                  *(term for row in project_rows(refs, vault)
                    for term in (row.get('client', ''), Path(row.get('vault_note', '')).stem))]
    seen, terms = set(), []
    for value in candidates:
        for term in _terms(value):
            if term and '@' not in term and term.casefold() not in seen:
                seen.add(term.casefold())
                terms.append(term)
    return terms[:VOCABULARY_LIMIT]


def is_user(attendee, emails, domains):
    email = attendee.get('email', '').casefold()
    return bool(attendee.get('self')) or email in emails or email.rsplit('@', 1)[-1] in domains


def people(event, vault, emails=frozenset(), domains=frozenset()):
    """Attendees besides the user, in calendar order: the contact note's name when one carries their email, else the calendar's."""
    names = []
    for attendee in event['attendees']:
        if is_user(attendee, emails, domains):
            continue
        email = attendee.get('email', '').casefold()
        person = next((p for p in vault.people if email and email in p.folded), None)
        names.append(person.path.stem if person else attendee.get('name') or email.split('@')[0])
    return names


def meeting_url(raw):
    hangout = str(raw.get('hangoutLink') or '')
    if hangout.startswith(('https://', 'http://')):
        return hangout
    conference = raw.get('conferenceData')
    for entry in (conference.get('entryPoints') or []) if isinstance(conference, dict) else []:
        uri = str(entry.get('uri') or '') if isinstance(entry, dict) else ''
        if uri.startswith(('https://', 'http://')) and entry.get('entryPointType') == 'video':
            return uri
    for url in re.finditer(r'https?://([^/?#:\s<>"]+)[^\s<>"]*', str(raw.get('location') or '')):
        if CALL_HOST.search(url.group(1)):
            return url.group()
    return None


def shared_brief(event, *, directory=None):
    directory = directory or config().get('shared_briefs_dir')
    if not directory:
        return ''
    return _read(Path(directory).expanduser() / (safe_key(event['key']) + '.md'))


@dataclass
class Sources:
    events: object
    attendees: object
    key: object
    parse_dt: object
    terms: object
    gmail: object
    vault: object = functools.partial(load_vault, lml_settings.Settings().vault)
    shared: object = shared_brief
    emails: frozenset = frozenset()
    domains: frozenset = frozenset()

    @classmethod
    def production(cls, settings):
        module = collectors(settings.calendar_collector)

        def events(lookahead_min):
            # The collector reads its account list from a module global; Gmail context keeps the collector's own accounts.
            if not settings.calendars:
                return module.collect_events(lookahead_min)
            saved, module.ACCOUNTS = module.ACCOUNTS, list(settings.calendars)
            try:
                return module.collect_events(lookahead_min)
            finally:
                module.ACCOUNTS = saved
        return cls(events, module.normalize_attendees, module.event_key,
                   module.parse_event_dt, module.extract_terms, module.collect_gmail_context,
                   vault=functools.partial(load_vault, settings.vault, settings.project_map),
                   emails=settings.emails | set(settings.calendars), domains=settings.domains)


def storage_key(key, has_id):
    if has_id:
        try:
            return safe_key(key)
        except ValueError:
            pass
    return hashlib.sha256(str(key).encode()).hexdigest()


def others(attendees, emails=frozenset()):
    """Invitees other than the user, rooms, and anyone who declined: the voices the other side of the call should have.

    `emails` are the user's own addresses, for when they are invited under another account.
    """
    def counts(person):
        email = str(person.get('email') or '').casefold()
        return not (person.get('self') or email in emails or email.endswith('resource.calendar.google.com')
                    or str(person.get('response') or '').lower() == 'declined')
    return sum(1 for person in attendees if counts(person))


def normalize_events(raw_events, sources):
    events = {}
    for raw in raw_events:
        start = sources.parse_dt(raw.get('startLocal') or raw.get('start'))
        end = sources.parse_dt(raw.get('endLocal') or raw.get('end'))
        if not start or not end or end <= start or raw.get('status') == 'cancelled':
            continue
        attendees = sources.attendees(raw)
        identity = raw.get('iCalUID') or raw.get('id') or raw.get('summary', '')
        dedupe = (identity, start.isoformat())
        events.setdefault(dedupe, {'key': storage_key(sources.key(raw, start), bool(raw.get('id') or raw.get('iCalUID'))),
                                  'start': start.isoformat(), 'end': end.isoformat(),
                                  'has_conference': bool(raw.get('hangoutLink') or raw.get('conferenceData')),
                                  'attendee_count': len(attendees), 'others': others(attendees, sources.emails), 'attendees': attendees,
                                  'title': raw.get('summary') or raw.get('title', ''),
                                  'meeting_url': meeting_url(raw), 'event_id': raw.get('id') or None, 'raw': raw})
    return list(events.values())


def _email_date(value):
    try:
        if str(value).isdigit():
            timestamp = int(value)
            return now_local().fromtimestamp(timestamp / (1000 if timestamp > 10**11 else 1), tz=now_local().tzinfo).date()
        return dt(value).date()
    except (ValueError, TypeError, OverflowError):
        try:
            return dt(str(value)[:10] + 'T00:00:00+00:00').date()
        except ValueError:
            return None


def build_brief(event, sources, now, context):
    people, projects, prior = context
    event_text = f"# {event['title']}\n{event['start']} to {event['end']}\n" + '\n'.join(
        a.get('name', '') + ' <' + a.get('email', '') + '>' for a in event['attendees'])
    blocks = [event_text, *people, *projects, *(r.render() for r in prior)]
    shared = sources.shared(event)
    if shared:
        blocks.append(shared)
        meta, body = front_matter(shared)
        date = str(meta.get('date', ''))[:10]
        commitments = section(body, ['Commitments', 'Your open commitments'])
        if commitments and re.fullmatch(r'\d{4}-\d{2}-\d{2}', date):
            blocks.append(Record('shared:commitments', date, commitments, 'commitment').render())
    email_blocks = []
    threads = sources.gmail(sources.terms(event['raw'], event['attendees']), event['attendees'])
    for thread in threads:
        date = _email_date(thread.get('date', ''))
        if not date or not 0 <= (now.date() - date).days <= 14:
            continue
        email_blocks.append(Record('email:' + str(thread.get('account', '')) + ':' + str(thread.get('id', len(email_blocks))),
                                   date.isoformat(), thread.get('subject', '') + '\n' + thread.get('snippet', ''), 'email').render())
        if len(email_blocks) == 8:
            break
    while email_blocks and len('\n\n'.join(blocks + email_blocks).encode('utf-8')) > MAX_BYTES:
        email_blocks.pop()
    while len(blocks) > 1 and len('\n\n'.join(blocks + email_blocks).encode('utf-8')) > MAX_BYTES:
        blocks.pop()
    text = '\n\n'.join(blocks + email_blocks)
    return text.encode('utf-8')[:MAX_BYTES].decode('utf-8', errors='ignore')


def recorder_settings():
    return {'retention_days': lml_settings.load().retention_days}


def maintenance(root, now, *, settings=None, runner=run_command):
    root = Path(root)
    settings = settings or recorder_settings()
    cutoff = now - timedelta(days=settings['retention_days'])
    state = read_json(root / 'maintenance.json', {})
    forgotten_sids = {item['sid'] for item in read_jsonl(root / 'forgotten.jsonl') if item.get('sid')}
    pending = {p.stem for p in (root / 'deletions').glob('*.json')}
    for sid in sorted(forgotten_sids | pending):
        if ((root / 'sessions' / safe_key(sid)).exists() or
                (root / 'hermes_map' / (sid + '.jsonl')).exists() or sid in pending):
            remaining, waiting = forget(root, sid, runner=runner)
            if remaining or waiting:
                raise RuntimeError('Meeting deletion incomplete')
    if state.get('date') == now.date().isoformat():
        return
    for path in (root / 'sessions').glob('*'):
        meta = read_json(path / 'meta.json', {})
        try:
            old = dt(meta.get('ended_at') or meta['started_at']) < cutoff
        except (KeyError, ValueError):
            old = path.stat().st_mtime < cutoff.timestamp()
        if old:
            remaining, waiting = forget(root, path.name, runner=runner)
            if remaining or waiting:
                raise RuntimeError('Meeting deletion incomplete')
    for mapping in (root / 'hermes_map').glob('*.jsonl'):
        if (root / 'sessions' / mapping.stem).exists():
            continue
        latest = max((dt(item['at']).timestamp() for item in read_jsonl(mapping) if item.get('at')),
                     default=mapping.stat().st_mtime)
        if latest < cutoff.timestamp():
            remaining, waiting = forget(root, mapping.stem, runner=runner)
            if remaining or waiting:
                raise RuntimeError('Meeting deletion incomplete')
    for directory in ('briefs', 'nudges', 'queries'):
        for path in (root / directory).glob('*'):
            if path.is_file() and path.stat().st_mtime < cutoff.timestamp():
                path.unlink()
    with locked(root / '.forgotten.lock'):
        tombstones = [item for item in read_jsonl(root / 'forgotten.jsonl') if dt(item['at']) >= cutoff]
        atomic_write(root / 'forgotten.jsonl', ''.join(json.dumps(item) + '\n' for item in tombstones))
    atomic_write(root / 'maintenance.json', {'date': now.date().isoformat()})


def run(*, root=None, now=None, sources=None, settings=None, runner=run_command):
    root, now = Path(root or root_path()), now or now_local()
    settings = settings or recorder_settings()
    with locked(root / '.brief.lock'):
        maintenance(root, now, settings=settings, runner=runner)
        sources = sources or Sources.production(lml_settings.load())
        raw, health = sources.events(NEXT_LOOKAHEAD_DAYS * 24 * 60)
        if not health.get('ok'):
            raise RuntimeError('Calendar unavailable')
        events = normalize_events(raw, sources)
        cached_schedule = read_json(root / 'schedule.json', {})
        cached = cached_schedule.get('events', [])
        authoritative = health.get('status') == 'ok'
        by_key = {e['key']: e for e in cached
                  if dt(e['end']) + timedelta(minutes=10) >= now
                  and (not authoritative or dt(e['end']) <= now)}
        cached_by_key = {e['key']: e for e in cached}
        for event in events:
            previous = cached_by_key.get(event['key'], {})
            if previous.get('start') == event['start'] and dt(event['start']) <= now and previous.get('window_start'):
                event['window_start'] = previous['window_start']
        vault = functools.cache(sources.vault)
        if authoritative:
            upcoming = [e for e in events if dt(e['start']) <= now + timedelta(hours=24)]
            for event in upcoming:
                event['vocabulary'] = vocabulary(event, vault())
                event['people'] = people(event, vault(), sources.emails, sources.domains)
            by_key.update({e['key']: e for e in upcoming})
        schedule_events = list(by_key.values())
        later = None
        if authoritative and not any(is_meeting(e) and dt(e['end']) > now for e in schedule_events):
            later = min((e for e in events if is_meeting(e) and dt(e['end']) > now), key=lambda e: (dt(e['start']), e['key']), default=None)
        fields = ('key', 'start', 'end', 'has_conference', 'attendee_count')
        if authoritative:
            schedule = [{**{k: e[k] for k in fields}, 'others': e.get('others'), 'title': e.get('title'), 'meeting_url': e.get('meeting_url'),
                         'event_id': e.get('event_id'), 'vocabulary': e.get('vocabulary', []), 'people': e.get('people', []),
                         'window_start': window_start(e, schedule_events).isoformat()}
                        for e in schedule_events]
            payload = {'v': 1, 'at': now.isoformat(),
                       'retention_days': settings['retention_days'], 'events': schedule}
            if later:
                payload['next'] = {**{k: later[k] for k in (*fields, 'title', 'meeting_url', 'event_id')},
                                   'people': people(later, vault(), sources.emails, sources.domains)}
        else:
            payload = {**cached_schedule, 'events': schedule_events}
        atomic_write(root / 'schedule.json', payload)
        fingerprints = read_json(root / 'briefs' / '.fingerprints.json', {})
        for event in events:
            if not (0 <= (dt(event['start']) - now).total_seconds() <= 600) or event['attendee_count'] < 2:
                continue
            fingerprint = hashlib.sha256(json.dumps(event['raw'], sort_keys=True).encode()).hexdigest()
            path = root / 'briefs' / (event['key'] + '.md')
            if fingerprints.get(event['key']) == fingerprint and path.exists():
                continue
            atomic_write(path, build_brief(event, sources, now, vault_context(event, vault())))
            fingerprints[event['key']] = fingerprint
        atomic_write(root / 'briefs' / '.fingerprints.json', fingerprints)


def main():
    try:
        run()
    except lml_settings.SettingsError as exc:
        print(exc, file=sys.stderr)
        return 1
    except Exception:
        # Nonzero, so Hermes cron shows the job failing instead of "ok" while the schedule goes stale.
        print('Meeting brief tick failed.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
