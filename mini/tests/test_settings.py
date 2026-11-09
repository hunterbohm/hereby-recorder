import tomllib
from pathlib import Path

import pytest

import any_answer
import live_answer
import live_meeting_nudge
import lml_hermes
import lml_settings
from lml_settings import MEETING_APPS, Settings, SettingsError, load
from live_meeting_brief import Vault, others, people

REPO = Path(__file__).resolve().parents[2]


def write(tmp_path, text):
    file = tmp_path / 'recorder.toml'
    file.write_text(text)
    return file


def test_a_missing_file_gives_the_defaults(tmp_path):
    settings = load(tmp_path / 'absent.toml')
    assert settings == Settings()
    assert settings.ssh_host is None and settings.emails == frozenset() and settings.meeting_apps == MEETING_APPS
    assert (settings.user_name, settings.retention_days, settings.mic_order) == ('the user', 14, ())
    assert settings.done_command == lml_settings.DONE_COMMAND


def test_the_file_lives_under_xdg_config_home_or_dot_config(tmp_path):
    assert lml_settings.path({'XDG_CONFIG_HOME': str(tmp_path)}) == tmp_path / 'hereby/recorder.toml'
    assert lml_settings.path({}) == Path.home() / '.config/hereby/recorder.toml'


def test_load_reads_every_setting(tmp_path):
    settings = load(write(tmp_path, '''
ssh_host = "studio"
storage_root = "~/state"
user_name = "Sam"
emails = ["Sam@Example.com"]
domains = ["Example.com"]
vault = "~/Notes"
meeting_apps = ["us.zoom"]
mic_order = ["Shure", "AirPods"]
retention_days = 30
done_command = "run-it now"
calendar_collector = "~/tools/collect.py"
project_map = "~/Notes/projects.tsv"
'''))
    assert (settings.ssh_host, settings.user_name, settings.retention_days) == ('studio', 'Sam', 30)
    assert settings.storage_root == Path.home() / 'state' and settings.vault == Path.home() / 'Notes'
    assert settings.emails == {'sam@example.com'} and settings.domains == {'example.com'}
    assert settings.meeting_apps == ('us.zoom',) and settings.mic_order == ('Shure', 'AirPods')
    assert settings.done_command == 'run-it now'
    assert settings.calendar_collector == Path.home() / 'tools/collect.py'
    assert settings.project_map == Path.home() / 'Notes/projects.tsv'


@pytest.mark.parametrize('text, field', [
    ('retention_days = 0', 'retention_days'),
    ('retention_days = -3', 'retention_days'),
    ('retention_days = "two"', 'retention_days'),
    ('retention_days = true', 'retention_days'),
    ('retention_days = 1.5', 'retention_days'),
    ('ssh_host = "-oProxyCommand=x"', 'ssh_host'),
    ('ssh_host = "two words"', 'ssh_host'),
    ('storage_root = "relative/path"', 'storage_root'),
    ('storage_root = "~/a$b"', 'storage_root'),
    ('emails = "sam@example.com"', 'emails'),
    ('mic_order = [1, 2]', 'mic_order'),
    ('meeting_apps = ["us.zoom", ""]', 'meeting_apps'),
    ('user_name = ""', 'user_name'),
    ('colour = "blue"', 'colour'),
])
def test_a_bad_value_names_its_field_and_file(tmp_path, text, field):
    file = write(tmp_path, text)
    with pytest.raises(SettingsError) as error:
        load(file)
    assert field in str(error.value) and str(file) in str(error.value)


def test_a_file_that_is_not_toml_names_the_file(tmp_path):
    file = write(tmp_path, 'ssh_host = ')
    with pytest.raises(SettingsError, match='is not valid TOML'):
        load(file)


def test_the_example_file_parses_and_sets_every_setting():
    values = tomllib.loads((REPO / 'recorder.example.toml').read_text())
    assert set(values) == set(lml_settings.FIELDS)
    assert load(REPO / 'recorder.example.toml').ssh_host == values['ssh_host']


def test_the_user_name_reaches_every_prompt(tmp_path, monkeypatch):
    monkeypatch.setenv('XDG_CONFIG_HOME', str(tmp_path))
    (tmp_path / 'hereby').mkdir()
    (tmp_path / 'hereby/recorder.toml').write_text('user_name = "Sam"\n')
    prompts = [lml_hermes.header(), any_answer.header(), live_answer.instructions(), live_meeting_nudge.instructions()]
    assert all('Sam' in prompt and '{user}' not in prompt for prompt in prompts)


def test_without_a_name_the_prompts_say_the_user():
    assert 'the user' in lml_hermes.header() and "the user's commitment" in live_answer.instructions()


def attendee(email, **fields):
    return {'name': email.split('@')[0], 'email': email, **fields}


def test_others_leaves_out_only_the_listed_emails_and_the_calendars_own_entry():
    invitees = [attendee('kim@x.test'), attendee('sam@a.test'), attendee('sam@b.test'), attendee('me@c.test', self=True),
                attendee('room@resource.calendar.google.com'), attendee('pat@x.test', response='declined')]
    assert others(invitees, frozenset({'sam@a.test', 'sam@b.test'})) == 1
    assert others(invitees, frozenset({'sam@a.test'})) == 2
    assert others(invitees) == 3


def test_others_matches_emails_without_regard_to_case():
    assert others([attendee('Sam@A.test')], frozenset({'sam@a.test'})) == 0


def test_people_leaves_out_the_users_emails_and_domains():
    event = {'attendees': [attendee('kim@x.test'), attendee('sam@a.test'), attendee('colleague@own.test'), attendee('me@c.test', self=True)]}
    assert people(event, Vault(), frozenset({'sam@a.test'}), frozenset({'own.test'})) == ['kim']


def test_storage_root_is_where_the_mini_keeps_sessions(tmp_path, monkeypatch):
    import lml_common
    monkeypatch.delenv('LML_ROOT')
    monkeypatch.setenv('XDG_CONFIG_HOME', str(tmp_path))
    (tmp_path / 'hereby').mkdir()
    (tmp_path / 'hereby/recorder.toml').write_text('storage_root = "/srv/meetings"\n')
    assert lml_common.root_path() == Path('/srv/meetings')
    assert not lml_common.test_root('/srv/meetings') and lml_common.test_root('/srv/meetings-test')


def test_an_unreadable_file_names_itself(tmp_path):
    with pytest.raises(SettingsError, match='cannot be read'):
        load(tmp_path)


def test_the_commands_report_a_bad_settings_file_instead_of_a_traceback(tmp_path, monkeypatch, capsys):
    import live_meeting_nudge
    monkeypatch.setenv('XDG_CONFIG_HOME', str(tmp_path))
    monkeypatch.delenv('LML_ROOT')
    (tmp_path / 'hereby').mkdir()
    (tmp_path / 'hereby/recorder.toml').write_text('retention_days = 0\n')
    monkeypatch.setattr('sys.argv', ['live_meeting_nudge'])
    assert live_meeting_nudge.main() == 1
    assert 'retention_days' in capsys.readouterr().err


def test_screen_context_must_be_true_or_false(tmp_path):
    assert load(write(tmp_path, 'screen_context = false')) is not None
    with pytest.raises(SettingsError, match='must be true or false'):
        load(write(tmp_path, 'screen_context = "no"'))
