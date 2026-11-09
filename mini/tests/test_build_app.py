import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
# build-app.sh reads and writes the app's Info.plist with plutil, which only macOS has.
pytestmark = pytest.mark.skipif(sys.platform != 'darwin', reason='needs macOS plutil')
LEGACY_LABEL = 'com.hun' + 'terbohm.livemeetinglistener'
NEW_LABEL = 'sh.hereby.recorder'

LAUNCHCTL = f'''#!{sys.executable}
import os, plistlib, sys
from pathlib import Path
state = Path(os.environ['STUB_STATE'])
with open(state / 'calls', 'a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
verb = sys.argv[1]
if verb == 'print':
    path = state / sys.argv[2].split('/')[-1]
    if not path.exists():
        sys.exit(113)
    print(path.read_text())
elif verb == 'bootout':
    (state / sys.argv[2].split('/')[-1]).unlink()
elif verb == 'bootstrap':
    value = plistlib.loads(Path(sys.argv[3]).read_bytes())
    (state / value['Label']).write_text('program = ' + value['ProgramArguments'][0] + '\\n\\tpid = 999998\\n')
'''

SWIFT = '''#!/bin/sh
echo "swift $*" >> "$STUB_STATE/calls"
case "$*" in
    *--show-bin-path*) echo "$STUB_BIN" ;;
    *) mkdir -p "$STUB_BIN"; printf '#!/bin/sh\\necho new build\\n' > "$STUB_BIN/lml"; chmod +x "$STUB_BIN/lml" ;;
esac
'''


@pytest.fixture
def box(tmp_path):
    package = tmp_path / 'pkg'
    (package / 'mac' / 'scripts').mkdir(parents=True)
    (package / 'handoff').mkdir()
    shutil.copy(REPO / 'mac' / 'scripts' / 'build-app.sh', package / 'mac' / 'scripts' / 'build-app.sh')
    shutil.copy(REPO / 'mac' / 'Info.plist', package / 'mac' / 'Info.plist')
    shutil.copy(REPO / 'mac' / 'AppIcon.icns', package / 'mac' / 'AppIcon.icns')
    (package / 'mac' / 'scripts' / 'sign.sh').write_text('#!/bin/sh\nexit 0\n')
    (package / 'handoff' / 'hereby-handoff.sh').write_text('#!/bin/sh\nexit 0\n')
    for script in (package / 'mac' / 'scripts').iterdir():
        script.chmod(0o755)
    git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.test']
    subprocess.run(['git', 'init', '-q'], cwd=package, check=True)
    subprocess.run(['git', 'add', '-A'], cwd=package, check=True)
    subprocess.run([*git, 'commit', '-q', '-m', 'x'], cwd=package, check=True)
    subprocess.run([*git, 'tag', 'v0.0.1'], cwd=package, check=True)
    (tmp_path / 'bin').mkdir()
    for name, text in (('swift', SWIFT), ('launchctl', LAUNCHCTL)):
        (tmp_path / 'bin' / name).write_text(text)
        (tmp_path / 'bin' / name).chmod(0o755)
    (tmp_path / 'state').mkdir()
    (tmp_path / 'home' / 'Library' / 'LaunchAgents').mkdir(parents=True)
    app = tmp_path / 'Apps' / 'LiveMeetingListener.app'
    (app / 'Contents' / 'MacOS').mkdir(parents=True)
    return tmp_path


def lml(box, status='sid idle'):
    path = box / 'Apps' / 'LiveMeetingListener.app' / 'Contents' / 'MacOS' / 'lml'
    path.write_text(f'#!/bin/sh\n[ "$1" = status ] && echo "{status}" && exit 0\necho old build\n')
    path.chmod(0o755)
    return path


def load(box, label):
    app = box / 'Apps' / 'LiveMeetingListener.app'
    (box / 'home' / 'Library' / 'LaunchAgents' / f'{label}.plist').write_bytes(
        plistlib.dumps({'Label': label, 'ProgramArguments': [str(app / 'Contents' / 'MacOS' / 'lml'), 'run']}))
    (box / 'state' / label).write_text(f'program = {app}/Contents/MacOS/lml\n\tpid = 999999\n')


def build(box, *flags):
    environment = {**os.environ, 'HOME': str(box / 'home'), 'PATH': f"{box / 'bin'}:{os.environ['PATH']}",
                   'LML_LAUNCHCTL': str(box / 'bin' / 'launchctl'), 'LML_APP_DESTINATION': str(box / 'Apps' / 'LiveMeetingListener.app'),
                   'STUB_STATE': str(box / 'state'), 'STUB_BIN': str(box / 'swiftbin')}
    return subprocess.run(['bash', str(box / 'pkg' / 'mac' / 'scripts' / 'build-app.sh'), *flags], capture_output=True, text=True, env=environment)


def calls(box):
    path = box / 'state' / 'calls'
    return path.read_text().splitlines() if path.exists() else []


def verbs(box, verb):
    return [line for line in calls(box) if line.startswith(verb)]


def installed(box):
    return (box / 'Apps' / 'LiveMeetingListener.app' / 'Contents' / 'MacOS' / 'lml').read_text()


def test_before_migration_the_old_label_is_stopped_swapped_and_restarted(box):
    lml(box)
    load(box, LEGACY_LABEL)
    result = build(box)
    assert result.returncode == 0, result.stderr
    assert 'new build' in installed(box)
    out = [line for line in verbs(box, 'bootout')]
    assert len(out) == 1 and out[0].endswith(LEGACY_LABEL)
    assert [line for line in verbs(box, 'bootstrap') if LEGACY_LABEL in line]
    assert not any(NEW_LABEL + '.plist' in line for line in verbs(box, 'bootstrap'))
    assert (box / 'state' / LEGACY_LABEL).exists() and not (box / 'state' / NEW_LABEL).exists()
    assert calls(box).index(out[0]) < calls(box).index(verbs(box, 'bootstrap')[0])


def test_the_old_label_build_refuses_while_a_session_is_active(box):
    lml(box, status='sid active 00:01:00')
    load(box, LEGACY_LABEL)
    result = build(box)
    assert result.returncode == 3 and 'Not installing' in result.stderr
    assert 'old build' in installed(box) and not verbs(box, 'bootout') and not verbs(box, 'bootstrap')


def test_the_new_label_build_behaves_as_before(box):
    lml(box)
    load(box, NEW_LABEL)
    result = build(box)
    assert result.returncode == 0, result.stderr
    assert 'new build' in installed(box)
    assert [line.endswith(NEW_LABEL) for line in verbs(box, 'bootout')] == [True]
    assert any(NEW_LABEL + '.plist' in line for line in verbs(box, 'bootstrap'))
    assert not any(LEGACY_LABEL in line for line in verbs(box, 'bootstrap'))


def test_the_new_label_build_refuses_while_a_session_is_active(box):
    lml(box, status='sid active 00:01:00')
    load(box, NEW_LABEL)
    assert build(box).returncode == 3
    assert 'old build' in installed(box) and not verbs(box, 'bootout')


def test_with_both_labels_loaded_the_build_refuses_and_points_at_the_migration(box):
    lml(box)
    load(box, LEGACY_LABEL)
    load(box, NEW_LABEL)
    result = build(box)
    assert result.returncode == 1 and 'migrate-labels.sh' in result.stderr
    assert 'old build' in installed(box) and not verbs(box, 'bootout') and not verbs(box, 'bootstrap')
    assert not any(line.startswith('swift') for line in calls(box))


def test_with_neither_label_loaded_the_build_installs_and_starts_nothing(box):
    lml(box)
    result = build(box)
    assert result.returncode == 0, result.stderr
    assert 'new build' in installed(box)
    assert not verbs(box, 'bootout') and not verbs(box, 'bootstrap') and not verbs(box, 'kickstart')


def installed_id(box, identifier):
    path = box / 'Apps' / 'LiveMeetingListener.app' / 'Contents' / 'Info.plist'
    path.write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))


def test_a_build_that_changes_the_bundle_id_refuses_without_the_flag_and_stops_nothing(box):
    lml(box)
    load(box, LEGACY_LABEL)
    installed_id(box, LEGACY_LABEL)
    result = build(box)
    assert result.returncode == 1 and '--new-bundle-id' in result.stderr and 'migrate-labels.sh' in result.stderr
    assert 'microphone and system audio' in result.stderr and 'Nothing was stopped or changed' in result.stderr
    assert 'old build' in installed(box) and not verbs(box, 'bootout') and not verbs(box, 'bootstrap')
    assert not any(line.startswith('swift') for line in calls(box))


def test_the_flag_lets_a_changed_bundle_id_through(box):
    lml(box)
    load(box, LEGACY_LABEL)
    installed_id(box, LEGACY_LABEL)
    result = build(box, '--new-bundle-id')
    assert result.returncode == 0, result.stderr
    assert 'new build' in installed(box) and len(verbs(box, 'bootout')) == 1


def test_the_same_bundle_id_needs_no_flag(box):
    lml(box)
    load(box, NEW_LABEL)
    installed_id(box, NEW_LABEL)
    result = build(box)
    assert result.returncode == 0, result.stderr
    assert 'new build' in installed(box)


def test_with_no_installed_app_the_build_needs_no_flag(box):
    shutil.rmtree(box / 'Apps' / 'LiveMeetingListener.app')
    result = build(box)
    assert result.returncode == 0, result.stderr
    assert (box / 'Apps' / 'LiveMeetingListener.app' / 'Contents' / 'MacOS' / 'lml').exists()
    assert not verbs(box, 'bootout') and not verbs(box, 'bootstrap')


def test_an_unknown_flag_is_a_usage_error(box):
    assert build(box, '--nope').returncode == 2
