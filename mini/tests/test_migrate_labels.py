import os
import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / 'mac' / 'scripts' / 'migrate-labels.sh'
LEGACY = 'com.hun' + 'terbohm'
OLD = [f'{LEGACY}.livemeetinglistener', f'{LEGACY}.lml-mic', f'{LEGACY}.lml-import.phone', f'{LEGACY}.lml-import.inbox']
NEW = ['sh.hereby.recorder', 'sh.hereby.recorder.mic', 'sh.hereby.recorder.import.phone', 'sh.hereby.recorder.import.inbox']

STUB = f'''#!{sys.executable}
import os, plistlib, signal, sys
from pathlib import Path
state = Path(os.environ['STUB_STATE'])
with open(state / 'calls', 'a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
verb = sys.argv[1]
name = sys.argv[2].split('/')[-1] if verb in ('print', 'bootout') else None
if verb == 'print':
    path = state / name
    if not path.exists():
        sys.exit(113)
    text = path.read_text()
    flap = os.environ.get('STUB_FLAP')
    if flap and flap in name and 'pid = ' in text:
        counter = state / (name + '.prints')
        count = int(counter.read_text()) + 1 if counter.exists() else 0
        counter.write_text(str(count))
        text = text.replace('pid = 4242', 'pid = ' + str(4242 + count))
    print(text)
    sys.exit(0)
if verb == 'bootout':
    (state / name).unlink()
    if os.environ.get('STUB_INTERRUPT_AFTER_BOOTOUT') == name:
        os.kill(os.getppid(), signal.SIGTERM)
elif verb == 'bootstrap':
    value = plistlib.loads(Path(sys.argv[3]).read_bytes())
    label = value['Label']
    if os.environ.get('STUB_FAIL_BOOTSTRAP') and label.startswith('sh.hereby'):
        sys.exit(5)
    keep = value.get('KeepAlive')
    if label.endswith('.mic') and os.environ.get('STUB_MIC_EXIT'):
        text = 'state = not running\\n\\tlast exit code = ' + os.environ['STUB_MIC_EXIT'] + '\\n'
    elif os.environ.get('STUB_NEVER_START') and label.startswith('sh.hereby') and os.environ['STUB_NEVER_START'] in label:
        text = 'state = not running\\n\\tlast exit code = 78: EX_CONFIG\\n'
    elif keep:
        text = 'state = running\\n\\tpid = 4242\\n'
    else:
        text = 'state = not running\\n\\tlast exit code = (never exited)\\n'
    (state / label).write_text(text)
    hook = os.environ.get('STUB_CAPTURE_ON_BOOTSTRAP')
    if hook and hook.split('=', 1)[0] in label:
        Path(hook.split('=', 1)[1]).parent.mkdir(parents=True, exist_ok=True)
        Path(hook.split('=', 1)[1]).write_text('')
'''


LML = '''#!/bin/sh
echo "lml $*" >> "$STUB_STATE/calls"
case "$1" in
    status) echo "sid idle" ;;
    capabilities)
        [ -n "$STUB_CAPTURE_STARTS" ] && mkdir -p "$(dirname "$STUB_CAPTURE_STARTS")" && : > "$STUB_CAPTURE_STARTS"
        echo "control-actions start stop pause resume forget mark ping" ;;
    ping)
        [ -n "$STUB_PING_FAIL" ] && exit 1
        if [ -n "$STUB_PING_PID" ]; then echo "pong $STUB_PING_PID"; exit 0; fi
        pid=$(sed -n 's/.*pid = \\([0-9]*\\).*/\\1/p' "$STUB_STATE/sh.hereby.recorder" | head -1)
        [ -n "$pid" ] || exit 1
        echo "pong $pid" ;;
    *) exit 2 ;;
esac
'''


@pytest.fixture
def home(tmp_path):
    agents = tmp_path / 'home' / 'Library' / 'LaunchAgents'
    agents.mkdir(parents=True)
    state = tmp_path / 'state'
    state.mkdir()
    stub = tmp_path / 'launchctl'
    stub.write_text(STUB)
    stub.chmod(0o755)
    lml = tmp_path / 'lml-stub'
    lml.write_text(LML)
    lml.chmod(0o755)
    return tmp_path


def install(home, labels, loaded=()):
    agents = home / 'home' / 'Library' / 'LaunchAgents'
    for label in labels:
        value = {'Label': label, 'ProgramArguments': ['/bin/true']}
        if 'import' in label:
            value['StartInterval'] = 900
        elif label.endswith(('.mic', '-mic')):
            value['KeepAlive'] = {'SuccessfulExit': False}
        else:
            value['KeepAlive'] = True
        (agents / f'{label}.plist').write_bytes(plistlib.dumps(value))
    for label in loaded:
        (home / 'state' / label).write_text('state = not running\n' if 'import' in label else 'state = running\n\tpid = 1\n')


def migrate(home, *arguments, **extra):
    environment = {**os.environ, 'HOME': str(home / 'home'), 'LML_LAUNCHCTL': str(home / 'launchctl'), 'STUB_STATE': str(home / 'state'),
                   'LML_BIN': str(home / 'lml-stub'), 'LML_MIGRATE_WAIT': '1', 'LML_MIGRATE_SETTLE': '0', **extra}
    return subprocess.run(['bash', str(SCRIPT), *arguments], capture_output=True, text=True, env=environment)


def agents(home):
    return sorted(path.stem for path in (home / 'home' / 'Library' / 'LaunchAgents').glob('*.plist'))


def loaded(home):
    return sorted(path.name for path in (home / 'state').iterdir() if path.name != 'calls' and not path.name.endswith('.prints'))


def test_a_dry_run_changes_nothing(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, '--dry-run')
    assert result.returncode == 0 and 'dry run' in result.stdout
    assert 'would move 4 agent(s). Nothing was changed.' in result.stdout and 'Moved' not in result.stdout
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)
    assert not any(line.startswith(('bootout', 'bootstrap')) for line in (home / 'state' / 'calls').read_text().splitlines())


def test_loaded_agents_move_to_the_new_labels(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home)
    assert result.returncode == 0, result.stderr
    assert agents(home) == sorted(NEW) and loaded(home) == sorted(NEW)
    for label in NEW:
        value = plistlib.loads((home / 'home' / 'Library' / 'LaunchAgents' / f'{label}.plist').read_bytes())
        assert value['Label'] == label and ('import' in label or value['KeepAlive'] in (True, {'SuccessfulExit': False}))
        assert (home / 'home' / 'Library' / 'LaunchAgents' / f'{label}.plist').stat().st_mode & 0o777 == 0o600


def test_an_agent_that_was_not_loaded_stays_unloaded(home):
    install(home, OLD, loaded=OLD[:1])
    assert migrate(home).returncode == 0
    assert agents(home) == sorted(NEW) and loaded(home) == [NEW[0]]


def test_a_second_run_changes_nothing(home):
    install(home, OLD, loaded=OLD)
    migrate(home)
    calls = (home / 'state' / 'calls').read_text()
    result = migrate(home)
    assert result.returncode == 0 and 'already migrated' in result.stdout and 'Nothing to migrate' in result.stdout
    assert agents(home) == sorted(NEW) and loaded(home) == sorted(NEW)
    assert (home / 'state' / 'calls').read_text().replace(calls, '').count('boot') == 0


def test_a_machine_with_no_old_agents_is_left_alone(home):
    result = migrate(home)
    assert result.returncode == 0 and 'Nothing to migrate' in result.stdout and agents(home) == []


def test_a_failed_load_puts_the_old_agent_back(home):
    install(home, OLD[:1], loaded=OLD[:1])
    result = migrate(home, STUB_FAIL_BOOTSTRAP='1')
    assert result.returncode == 1 and 'Could not load sh.hereby.recorder' in result.stderr and 'Putting' in result.stderr
    assert agents(home) == [OLD[0]] and loaded(home) == [OLD[0]]


def test_it_refuses_while_a_recording_is_active(home):
    install(home, OLD, loaded=OLD)
    lml = home / 'lml'
    lml.write_text(f'#!/bin/sh\n[ "$1" = status ] && echo "lml status" >> "$STUB_STATE/calls" && echo "sid active 00:03:10" && exit 0\nexec {home / "lml-stub"} "$@"\n')
    lml.chmod(0o755)
    result = migrate(home, LML_BIN=str(lml))
    assert result.returncode == 3 and 'a session is active' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)
    assert migrate(home, '--force', LML_BIN=str(lml)).returncode == 0
    assert agents(home) == sorted(NEW)


def test_an_interruption_between_unload_and_load_puts_every_old_agent_back(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_INTERRUPT_AFTER_BOOTOUT=OLD[1])
    assert result.returncode == 143, result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)
    assert all(not (home / 'home' / 'Library' / 'LaunchAgents' / f'{label}.plist').exists() for label in NEW)


def test_a_new_agent_that_registers_but_never_starts_is_rolled_back_and_named(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_NEVER_START='.mic')
    assert result.returncode == 1 and 'sh.hereby.recorder.mic loaded but did not start' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_an_on_demand_agent_that_cannot_launch_is_rolled_back_too(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_NEVER_START='import.inbox')
    assert result.returncode == 1 and 'sh.hereby.recorder.import.inbox loaded but did not start' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_old_plists_stay_until_every_new_agent_is_confirmed(home):
    install(home, OLD, loaded=OLD)
    wrapper = home / 'watch-launchctl'
    wrapper.write_text(f"#!/bin/sh\nls {home / 'home' / 'Library' / 'LaunchAgents'} | tr '\\n' ' ' >> {home / 'state' / 'plists'}\n"
                       f"echo >> {home / 'state' / 'plists'}\nexec {home / 'launchctl'} \"$@\"\n")
    wrapper.chmod(0o755)
    result = migrate(home, LML_LAUNCHCTL=str(wrapper))
    assert result.returncode == 0, result.stderr
    snapshots = [line.split() for line in (home / 'state' / 'plists').read_text().splitlines()]
    during = [names for names in snapshots if any(name.startswith('sh.hereby') for name in names)]
    assert during and all(all(f'{label}.plist' in names for label in OLD) for names in during)
    assert agents(home) == sorted(NEW)


def test_the_recorder_must_answer_over_its_control_socket_before_the_old_plist_goes(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_PING_FAIL='1')
    assert result.returncode == 1 and 'sh.hereby.recorder loaded but did not start' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_an_answer_from_another_process_does_not_confirm_the_new_recorder(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_PING_PID='9999')
    assert result.returncode == 1 and 'sh.hereby.recorder loaded but did not start' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_a_process_that_changes_pid_during_the_settle_window_is_rolled_back(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_FLAP='.mic', LML_MIGRATE_SETTLE='1')
    assert result.returncode == 1 and 'sh.hereby.recorder.mic loaded but did not start' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_the_mic_helper_that_exits_cleanly_on_purpose_counts_as_started(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_MIC_EXIT='0')
    assert result.returncode == 0, result.stderr
    assert agents(home) == sorted(NEW) and loaded(home) == sorted(NEW)


@pytest.mark.parametrize('code', ['1', '78', '126', '127'])
def test_the_mic_helper_that_fails_does_not_count_as_started(home, code):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_MIC_EXIT=code)
    assert result.returncode == 1 and 'sh.hereby.recorder.mic loaded but did not start' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_an_old_agent_still_loaded_beside_its_new_one_is_unloaded_before_its_plist_goes(home):
    install(home, OLD, loaded=OLD)
    install(home, NEW[1:2], loaded=NEW[1:2])
    result = migrate(home)
    assert result.returncode == 0, result.stderr
    assert agents(home) == sorted(NEW) and loaded(home) == sorted(NEW)
    calls = (home / 'state' / 'calls').read_text()
    assert f'bootout gui/{os.getuid()}/{OLD[1]}' in calls


def test_a_new_agent_that_fails_beside_a_loaded_old_one_leaves_the_old_one_running(home):
    install(home, OLD[1:2], loaded=OLD[1:2])
    install(home, NEW[1:2], loaded=NEW[1:2])
    (home / 'state' / NEW[1]).write_text('state = not running\n\tlast exit code = 78\n')
    result = migrate(home)
    assert result.returncode == 1 and 'sh.hereby.recorder.mic loaded but did not start' in result.stderr
    assert agents(home) == [OLD[1], NEW[1]] and OLD[1] in loaded(home)


def test_a_loaded_old_agent_with_no_plist_stays_when_the_new_one_is_not_running(home):
    (home / 'state' / OLD[2]).write_text('state = not running\n')
    result = migrate(home)
    assert result.returncode == 1 and OLD[2] in loaded(home)
    assert not any(line.startswith(('bootout', 'bootstrap')) for line in lml_and_launchctl_calls(home))


def test_a_dry_run_reports_the_both_loaded_case_and_changes_nothing(home):
    install(home, OLD[1:2], loaded=OLD[1:2])
    install(home, NEW[1:2], loaded=NEW[1:2])
    result = migrate(home, '--dry-run')
    assert result.returncode == 0 and 'new agent also loaded' in result.stdout
    assert agents(home) == [OLD[1], NEW[1]] and loaded(home) == sorted([OLD[1], NEW[1]])


def test_a_rerun_after_an_interrupted_cleanup_finishes_it(home):
    install(home, NEW, loaded=NEW)
    install(home, OLD[:2])
    result = migrate(home)
    assert result.returncode == 0, result.stderr
    assert agents(home) == sorted(NEW) and loaded(home) == sorted(NEW)


def test_it_refuses_before_touching_anything_when_the_installed_app_is_too_old_to_ping(home):
    install(home, OLD, loaded=OLD)
    old_build = home / 'lml-old'
    old_build.write_text('#!/bin/sh\necho "lml $*" >> "$STUB_STATE/calls"\n[ "$1" = status ] && echo "sid idle" && exit 0\n'
                         '[ "$1" = ping ] && echo "REACHED-THE-OLD-RECORDER" >> "$STUB_STATE/calls"\nexit 2\n')
    old_build.chmod(0o755)
    result = migrate(home, LML_BIN=str(old_build))
    assert result.returncode == 1 and 'build-app.sh first' in result.stderr and 'Nothing was changed' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)
    calls = (home / 'state' / 'calls').read_text().splitlines()
    assert not any(line.startswith(('bootout', 'bootstrap')) for line in calls)
    assert 'lml capabilities' in calls and not any('ping' in line or 'REACHED' in line for line in calls)


def test_it_refuses_when_the_installed_app_is_missing(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, LML_BIN=str(home / 'no-such-app'))
    assert result.returncode == 1 and 'missing or too old' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_a_build_that_knows_ping_passes_the_check_even_while_the_old_recorder_cannot_answer(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home)
    assert result.returncode == 0, result.stderr


def test_nothing_to_migrate_needs_no_installed_app(home):
    result = migrate(home, LML_BIN=str(home / 'no-such-app'))
    assert result.returncode == 0 and 'Nothing to migrate' in result.stdout


def lml_and_launchctl_calls(home):
    calls = home / 'state' / 'calls'
    return calls.read_text().splitlines() if calls.exists() else []


def test_a_dry_run_never_sends_anything_to_a_running_recorder(home):
    install(home, OLD, loaded=OLD)
    assert migrate(home, '--dry-run').returncode == 0
    assert not any(line.startswith('lml ping') for line in lml_and_launchctl_calls(home))


def test_the_busy_check_comes_first_and_nothing_else_runs_on_the_recorder(home):
    install(home, OLD, loaded=OLD)
    lml = home / 'lml-busy'
    lml.write_text('#!/bin/sh\necho "lml $*" >> "$STUB_STATE/calls"\n[ "$1" = status ] && echo "sid active 00:03:10" && exit 0\n'
                   '[ "$1" = ping ] && echo "REACHED-THE-OLD-RECORDER" >> "$STUB_STATE/calls"\nexit 2\n')
    lml.chmod(0o755)
    for flags in ([], ['--dry-run']):
        result = migrate(home, *flags, LML_BIN=str(lml))
        assert result.returncode == 3 and 'a session is active' in result.stderr
    calls = lml_and_launchctl_calls(home)
    assert [line for line in calls if line.startswith('lml')] == ['lml status', 'lml status']
    assert not any(line.startswith(('bootout', 'bootstrap')) for line in calls)


def test_ping_goes_only_to_the_new_label_after_it_loads(home):
    install(home, OLD, loaded=OLD)
    assert migrate(home).returncode == 0
    calls = lml_and_launchctl_calls(home)
    first_ping = next(index for index, line in enumerate(calls) if line.startswith('lml ping'))
    bootstrapped = next(index for index, line in enumerate(calls) if line.startswith('bootstrap') and 'sh.hereby.recorder.plist' in line)
    booted_out = next(index for index, line in enumerate(calls) if line.startswith('bootout') and OLD[0] in line)
    assert booted_out < bootstrapped < first_ping
    assert calls.index('lml capabilities') < booted_out


def audio_dir(home):
    return home / 'home' / 'Library' / 'Application Support' / 'LiveMeetingListener' / 'audio'


def no_unload(home):
    return not any(line.startswith(('bootout', 'bootstrap')) for line in lml_and_launchctl_calls(home))


def test_a_capture_that_is_still_arming_is_refused(home):
    install(home, OLD, loaded=OLD)
    audio_dir(home).mkdir(parents=True)
    (audio_dir(home) / '20261101-100000-abcd.caf').write_text('')
    for flags in ([], ['--dry-run']):
        result = migrate(home, *flags)
        assert result.returncode == 3 and 'call audio is on disk' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD) and no_unload(home)


def test_a_stale_audio_file_is_refused_too_because_it_cannot_be_told_from_a_live_one(home):
    install(home, OLD, loaded=OLD)
    audio_dir(home).mkdir(parents=True)
    stale = audio_dir(home) / '20261031-090000-abcd.caf'
    stale.write_text('')
    os.utime(stale, (1_700_000_000, 1_700_000_000))
    result = migrate(home)
    assert result.returncode == 3 and 'call audio is on disk' in result.stderr
    assert migrate(home, '--force').returncode == 0
    assert agents(home) == sorted(NEW)


def test_a_capture_that_starts_between_the_preflight_and_the_unload_is_refused(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_CAPTURE_STARTS=str(audio_dir(home) / '20261101-100500-beef.caf'))
    assert result.returncode == 3 and 'call audio is on disk' in result.stderr
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD) and no_unload(home)


def test_a_loaded_old_label_whose_plist_is_gone_changes_nothing_and_prints_the_manual_steps(home):
    install(home, NEW, loaded=NEW)
    (home / 'state' / OLD[2]).write_text('state = running\n\tpid = 77\n')
    for flags in ([], ['--dry-run']):
        result = migrate(home, *flags)
        assert result.returncode == 1 and 'will not unload it' in result.stderr
        assert f'launchctl bootout gui/{os.getuid()}/{OLD[2]}' in result.stderr and 'Nothing was changed' in result.stderr
    assert loaded(home) == sorted([*NEW, OLD[2]]) and agents(home) == sorted(NEW) and no_unload(home)


def test_the_recorder_moves_after_the_helpers_are_confirmed(home):
    install(home, OLD, loaded=OLD)
    assert migrate(home).returncode == 0
    calls = lml_and_launchctl_calls(home)
    recorder_out = next(index for index, line in enumerate(calls) if line.startswith('bootout') and line.endswith(OLD[0]))
    for helper in NEW[1:]:
        helper_up = next(index for index, line in enumerate(calls) if line.startswith('bootstrap') and f'{helper}.plist' in line)
        assert helper_up < recorder_out


def test_a_helper_failure_never_unloads_the_new_recorder(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_MIC_EXIT='78')
    assert result.returncode == 1 and 'sh.hereby.recorder.mic loaded but did not start' in result.stderr
    calls = lml_and_launchctl_calls(home)
    assert not any(line.startswith('bootout') and line.endswith(NEW[0]) for line in calls)
    assert not any(line.startswith('bootout') and line.endswith(OLD[0]) for line in calls)
    assert not any(line.startswith('bootstrap') and f'{NEW[0]}.plist' in line for line in calls)
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_a_capture_visible_after_a_helper_moves_stops_the_migration_before_the_recorder_unloads(home):
    install(home, OLD, loaded=OLD)
    result = migrate(home, STUB_CAPTURE_ON_BOOTSTRAP=f'.import.phone={audio_dir(home) / "20261101-110000-cafe.caf"}')
    assert result.returncode == 3 and 'call audio is on disk' in result.stderr
    calls = lml_and_launchctl_calls(home)
    assert not any(line.startswith('bootout') and line.endswith(OLD[0]) for line in calls)
    assert agents(home) == sorted(OLD) and loaded(home) == sorted(OLD)


def test_the_busy_check_does_not_depend_on_which_labels_are_loaded(home):
    install(home, OLD)
    audio_dir(home).mkdir(parents=True)
    (audio_dir(home) / '20261101-120000-aaaa.caf').write_text('')
    result = migrate(home)
    assert result.returncode == 3 and 'call audio is on disk' in result.stderr
    assert agents(home) == sorted(OLD)


def test_a_machine_that_is_already_migrated_is_not_refused_for_a_running_call(home):
    install(home, NEW, loaded=NEW)
    audio_dir(home).mkdir(parents=True)
    (audio_dir(home) / '20261101-120000-aaaa.caf').write_text('')
    result = migrate(home)
    assert result.returncode == 0 and 'Nothing to migrate' in result.stdout
