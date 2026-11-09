"""The recorder's settings from recorder.toml: who the user is and where meetings go.

The Mac reads the same file with mac/Sources/LMLCore/Settings.swift, and both accept the same keys.
"""
import os
import shlex
import tomllib
from dataclasses import dataclass
from pathlib import Path

MEETING_APPS = ('us.zoom', 'com.google.Chrome', 'net.imput.helium', 'company.thebrowser', 'app.zen-browser',
                'com.apple.Safari', 'com.microsoft.teams', 'com.tinyspeck.slackmacgap', 'com.apple.FaceTime',
                'com.hnc.Discord', 'com.webex')
MIC_APPS = ('com.granola.app.helper',)
HANDOFF = Path(__file__).resolve().parent.parent / 'handoff' / 'hereby-handoff.sh'
# A `{session}` word in a done command becomes the session's folder.
DONE_COMMAND = f'{shlex.quote(str(HANDOFF))} {{session}}'


class SettingsError(Exception):
    def __init__(self, file, field, problem):
        super().__init__(f'{file}: {field} {problem}')


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _host(value):
    return isinstance(value, str) and bool(value) and not value.startswith('-') and not any(c.isspace() for c in value)


def _addresses(value):
    return isinstance(value, list) and all(_text(v) and '@' in v for v in value)


def _root(value):
    return isinstance(value, str) and value.startswith(('~/', '/')) and not any(c in value for c in '"$`\\')


# Each key, its check, and what a bad value is told.
FIELDS = {
    'ssh_host': (_host, 'must be an ssh host with no spaces'),
    'storage_root': (_root, 'must be a path that starts with ~/ or /, with no quotes, $, or backslashes'),
    'user_name': (_text, 'must be a string'),
    'emails': (lambda v: isinstance(v, list) and all(map(_text, v)), 'must be a list of strings'),
    'calendars': (_addresses, 'must be a list of email addresses'),
    'domains': (lambda v: isinstance(v, list) and all(map(_text, v)), 'must be a list of strings'),
    'vault': (_text, 'must be a string'),
    'meeting_apps': (lambda v: isinstance(v, list) and all(map(_text, v)), 'must be a list of strings'),
    'mic_apps': (lambda v: isinstance(v, list) and all(map(_text, v)), 'must be a list of strings'),
    'mic_order': (lambda v: isinstance(v, list) and all(map(_text, v)), 'must be a list of strings'),
    'retention_days': (lambda v: type(v) is int and v >= 1, 'must be a whole number of days, 1 or more'),
    'done_command': (_text, 'must be a string'),
    'calendar_collector': (_text, 'must be a string'),
    'project_map': (_text, 'must be a string'),
    # The Mac's overlay settings; the mini only checks they are text.
    'overlay_toggle_key': (_text, 'must be a string'),
    'overlay_say_key': (_text, 'must be a string'),
    'overlay_command': (_text, 'must be a string'),
    # The Mac's choice to send the screen with live questions.
    'screen_context': (lambda value: isinstance(value, bool), 'must be true or false'),
}


@dataclass(frozen=True)
class Settings:
    ssh_host: str | None = None
    storage_root: Path = Path.home() / '.local/state/live-meeting'
    user_name: str = 'the user'
    # Casefolded, so membership checks need no folding of the stored side.
    emails: frozenset = frozenset()
    domains: frozenset = frozenset()
    # The Google accounts the schedule reads. Empty leaves the collector on its own accounts. Counted among `emails`.
    calendars: tuple = ()
    vault: Path = Path.home() / 'vault'
    meeting_apps: tuple = MEETING_APPS
    mic_apps: tuple = MIC_APPS
    mic_order: tuple = ()
    retention_days: int = 14
    done_command: str = DONE_COMMAND
    calendar_collector: Path | None = None
    project_map: Path | None = None


def path(environ=os.environ):
    """$XDG_CONFIG_HOME/hereby/recorder.toml, or ~/.config/hereby/recorder.toml without it."""
    return Path(environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'hereby' / 'recorder.toml'


def _fold(items):
    return tuple(dict.fromkeys(item.strip().casefold() for item in items))


def load(file=None):
    """The settings in `file`, or the defaults when it does not exist. Raises SettingsError naming a bad field."""
    file = Path(file or path())
    try:
        values = tomllib.loads(file.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return Settings()
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as exc:
        raise SettingsError(file, 'file', f'is not valid TOML ({exc})') from None
    except OSError as exc:
        raise SettingsError(file, 'file', f'cannot be read ({exc.strerror})') from None
    for key, value in values.items():
        check, problem = FIELDS.get(key, (None, 'is not a setting'))
        if check is None or not check(value):
            raise SettingsError(file, key, problem)
    paths = {key: Path(values[key]).expanduser()
             for key in ('storage_root', 'vault', 'calendar_collector', 'project_map') if key in values}
    lists = {key: tuple(values[key]) for key in ('meeting_apps', 'mic_apps', 'mic_order') if key in values}
    folded = {key: frozenset(item.casefold() for item in values[key]) for key in ('emails', 'domains') if key in values}
    calendars = _fold(values.get('calendars', ()))
    plain = {key: values[key] for key in ('ssh_host', 'user_name', 'retention_days', 'done_command') if key in values}
    return Settings(**plain, **paths, **lists, **folded, calendars=calendars)
