import os
import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
# release.sh stamps the app with plutil and zips it with ditto, which only macOS has.
pytestmark = pytest.mark.skipif(sys.platform != 'darwin', reason='needs macOS plutil and ditto')
IDENTITY = 'Developer ID Application: Example Co (ABCDE12345)'

# Every Apple and GitHub tool is a stub that logs its arguments; the notary stub answers Accepted unless told not to.
LOGGING_STUB = '''#!/bin/sh
echo "$(basename "$0") $*" >> "$STUB_STATE/calls"
'''
STUBS = {
    'swift': LOGGING_STUB + '''case "$*" in
    *--show-bin-path*) echo "$STUB_BIN" ;;
    *) mkdir -p "$STUB_BIN"
       for name in lml lml-mic; do printf '#!/bin/sh\\necho %s\\n' "$name" > "$STUB_BIN/$name"; chmod +x "$STUB_BIN/$name"; done
       cp "$STUB_STATE/lml-release" "$STUB_BIN/lml-release" ;;
esac
''',
    'security': LOGGING_STUB + '''echo '  1) 0123456789ABCDEF "Developer ID Application: Example Co (ABCDE12345)"'
''',
    'codesign': LOGGING_STUB,
    'spctl': LOGGING_STUB,
    'xcrun': LOGGING_STUB + '''if [ "$1" = notarytool ] && [ "$2" = submit ]; then
    printf '{"id":"sub-1","status":"%s"}\\n' "${STUB_NOTARY:-Accepted}"
fi
''',
    'gh': LOGGING_STUB + '''case "$1 $2" in
    "release view") exit 1 ;;
    "repo view") echo example/private ;;
esac
''',
}
RELEASE_TOOL = LOGGING_STUB + '''case "$1" in
    public-key) echo PUBLICKEY= ;;
    feed) echo '{"version":"v2.14.0"}' ;;
    verify) echo ok ;;
esac
'''
SECRETS = {'HEREBY_SIGN_IDENTITY': IDENTITY, 'HEREBY_TEAM_ID': 'ABCDE12345', 'HEREBY_UPDATE_KEY': 'not-printed',
           'HEREBY_UPDATE_REPO': 'example/recorder', 'HEREBY_NOTARY_PROFILE': 'hereby-notary'}


@pytest.fixture
def box(tmp_path):
    package = tmp_path / 'pkg'
    (package / 'mac' / 'scripts').mkdir(parents=True)
    for script in ('release.sh', 'assemble-app.sh', 'install-app.sh', 'install.sh'):
        shutil.copy(REPO / 'mac' / 'scripts' / script, package / 'mac' / 'scripts' / script)
    for name in ('Info.plist', 'AppIcon.icns', 'LiveMeetingListener.entitlements'):
        shutil.copy(REPO / 'mac' / name, package / 'mac' / name)
    shutil.copytree(REPO / 'mac' / 'LaunchAgent', package / 'mac' / 'LaunchAgent')
    shutil.copytree(REPO / 'mac' / 'en.lproj', package / 'mac' / 'en.lproj')
    (package / 'handoff').mkdir()
    (package / 'handoff' / 'hereby-handoff.sh').write_text('#!/bin/sh\n')
    (package / 'mini').mkdir()
    for name in ('live-meeting-ask', 'live-meeting-quick', 'live_quick.py'):
        (package / 'mini' / name).write_text('#!/bin/sh\n')
    git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.test']
    subprocess.run(['git', 'init', '-q'], cwd=package, check=True)
    subprocess.run(['git', 'add', '-A'], cwd=package, check=True)
    subprocess.run([*git, 'commit', '-q', '-m', 'x'], cwd=package, check=True)
    subprocess.run([*git, 'tag', 'v2.14.0'], cwd=package, check=True)
    (tmp_path / 'bin').mkdir()
    for name, text in STUBS.items():
        (tmp_path / 'bin' / name).write_text(text)
        (tmp_path / 'bin' / name).chmod(0o755)
    (tmp_path / 'state').mkdir()
    (tmp_path / 'state' / 'lml-release').write_text(RELEASE_TOOL)
    (tmp_path / 'state' / 'lml-release').chmod(0o755)
    return tmp_path


def release(box, *flags, **overrides):
    environment = {key: value for key, value in os.environ.items() if not key.startswith('HEREBY_')}
    environment.update({'PATH': f"{box / 'bin'}:{os.environ['PATH']}", 'STUB_STATE': str(box / 'state'),
                        'STUB_BIN': str(box / 'swiftbin'), 'HEREBY_RELEASE_OUT': str(box / 'out'), **SECRETS})
    for key, value in overrides.items():
        if value is None:
            environment.pop(key, None)
        else:
            environment[key] = value
    return subprocess.run(['bash', str(box / 'pkg' / 'mac' / 'scripts' / 'release.sh'), *flags],
                          capture_output=True, text=True, env=environment)


def calls(box, tool=None):
    path = box / 'state' / 'calls'
    lines = path.read_text().splitlines() if path.exists() else []
    return [line for line in lines if tool is None or line.startswith(tool + ' ')]


def released_app(box):
    with zipfile.ZipFile(box / 'out' / 'LiveMeetingListener-v2.14.0.zip') as archive:
        names = archive.namelist()
        info = plistlib.loads(archive.read('LiveMeetingListener.app/Contents/Info.plist'))
    return names, info


def test_a_release_is_signed_inside_out_with_the_runtime_then_notarized_and_stapled(box):
    result = release(box, '--no-upload')
    assert result.returncode == 0, result.stderr
    signs = [line for line in calls(box, 'codesign') if '--sign' in line]
    assert len(signs) == 2
    assert signs[0].endswith('Contents/Helpers/lml-mic') and '--identifier sh.hereby.recorder.mic' in signs[0]
    assert signs[1].endswith('LiveMeetingListener.app') and '--entitlements' in signs[1] and '--identifier sh.hereby.recorder ' in signs[1]
    for line in signs:
        assert '--options runtime' in line and '--timestamp' in line and IDENTITY in line
    verify = [line for line in calls(box, 'codesign') if '--verify' in line]
    assert verify and 'certificate leaf[subject.OU] = "ABCDE12345"' in verify[0]
    xcrun = calls(box, 'xcrun')
    assert any('notarytool submit' in line and '--keychain-profile hereby-notary' in line and '--wait' in line for line in xcrun)
    assert [line.split()[2] for line in xcrun if 'stapler' in line] == ['staple', 'validate']
    assert calls(box, 'spctl')
    assert not calls(box, 'gh')
    assert 'not-printed' not in result.stdout + result.stderr


def test_the_released_app_carries_its_feed_key_team_and_installers(box):
    assert release(box, '--no-upload').returncode == 0
    names, info = released_app(box)
    assert info['HerebyUpdateFeed'] == 'https://github.com/example/recorder/releases/latest/download/appcast.json'
    assert info['HerebyUpdatePublicKey'] == 'PUBLICKEY='
    assert info['HerebyTeamID'] == 'ABCDE12345'
    assert info['CFBundleIdentifier'] == 'sh.hereby.recorder' and info['CFBundleShortVersionString'] == 'v2.14.0'
    assert 'HerebyCheckout' not in info
    for path in ('Contents/Helpers/lml-mic', 'Contents/Resources/scripts/install-app.sh', 'Contents/Resources/scripts/install.sh',
                 'Contents/Resources/LaunchAgent/sh.hereby.recorder.plist', 'Contents/MacOS/lml',
                 'Contents/Resources/en.lproj/InfoPlist.strings'):
        assert 'LiveMeetingListener.app/' + path in names
    feed = [line for line in calls(box, 'lml-release') if line.startswith('lml-release feed')]
    assert feed and '--url https://github.com/example/recorder/releases/download/v2.14.0/LiveMeetingListener-v2.14.0.zip' in feed[0]
    assert '--minimum-system 26.0' in feed[0]
    assert (box / 'out' / 'appcast.json').read_text().strip() == '{"version":"v2.14.0"}'


def test_an_upload_goes_to_this_repo_and_public_also_to_the_update_repo(box):
    result = release(box)
    assert result.returncode == 0, result.stderr
    creates = [line for line in calls(box, 'gh') if line.startswith('gh release create')]
    assert len(creates) == 1 and '--repo example/private' in creates[0] and '--verify-tag' in creates[0]
    assert 'LiveMeetingListener-v2.14.0.zip' in creates[0] and 'appcast.json' in creates[0]
    (box / 'state' / 'calls').unlink()
    result = release(box, '--public')
    assert result.returncode == 0, result.stderr
    creates = [line for line in calls(box, 'gh') if line.startswith('gh release create')]
    assert [('--repo example/recorder' in line, '--latest' in line) for line in creates] == [(False, False), (True, True)]


def test_a_notary_api_key_is_used_from_a_private_file(box):
    result = release(box, '--no-upload', HEREBY_NOTARY_PROFILE=None, HEREBY_NOTARY_KEY='-----BEGIN PRIVATE KEY-----',
                     HEREBY_NOTARY_KEY_ID='KEY123', HEREBY_NOTARY_ISSUER='issuer-1')
    assert result.returncode == 0, result.stderr
    submit = [line for line in calls(box, 'xcrun') if 'notarytool submit' in line][0]
    assert '--key-id KEY123' in submit and '--issuer issuer-1' in submit and 'notary.p8' in submit
    assert 'BEGIN PRIVATE KEY' not in submit


def test_a_rejected_notarization_stops_before_the_zip(box):
    result = release(box, '--no-upload', STUB_NOTARY='Invalid')
    assert result.returncode == 1 and 'Invalid' in result.stderr
    assert any('notarytool log sub-1' in line for line in calls(box, 'xcrun'))
    assert not (box / 'out' / 'LiveMeetingListener-v2.14.0.zip').exists()
    assert not any('stapler' in line for line in calls(box, 'xcrun'))


@pytest.mark.parametrize('missing', ['HEREBY_SIGN_IDENTITY', 'HEREBY_TEAM_ID', 'HEREBY_UPDATE_KEY', 'HEREBY_UPDATE_REPO', 'HEREBY_NOTARY_PROFILE'])
def test_a_missing_secret_refuses_before_building(box, missing):
    result = release(box, '--no-upload', **{missing: None})
    assert result.returncode == 1 and missing in result.stderr and 'infisical run' in result.stderr
    assert not calls(box, 'swift') and not calls(box, 'codesign')


def test_an_identity_from_another_team_or_not_in_the_keychain_refuses(box):
    result = release(box, '--no-upload', HEREBY_SIGN_IDENTITY='Developer ID Application: Other (ZZZZZ99999)')
    assert result.returncode == 1 and 'ABCDE12345' in result.stderr
    (box / 'bin' / 'security').write_text(LOGGING_STUB)
    result = release(box, '--no-upload')
    assert result.returncode == 1 and 'keychain' in result.stderr
    assert not calls(box, 'swift')


def test_a_release_needs_a_clean_release_tag(box):
    package = box / 'pkg'
    git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.test']
    (package / 'mac' / 'Info.plist').write_text((package / 'mac' / 'Info.plist').read_text() + '\n')
    result = release(box, '--no-upload')
    assert result.returncode == 1 and 'uncommitted' in result.stderr
    subprocess.run([*git, 'commit', '-qam', 'y'], cwd=package, check=True)
    subprocess.run([*git, 'tag', 'v2.15.0-rc.1'], cwd=package, check=True)
    result = release(box, '--no-upload')
    assert result.returncode == 1 and 'release tag' in result.stderr
    assert not calls(box, 'swift')


def test_public_needs_the_upload(box):
    assert release(box, '--no-upload', '--public').returncode == 2


def test_the_downloaded_app_installs_its_agents_with_macos_tools_only(tmp_path):
    home = tmp_path / 'home'
    resources = home / 'Applications' / 'LiveMeetingListener.app' / 'Contents' / 'Resources'
    (resources / 'scripts').mkdir(parents=True)
    shutil.copy(REPO / 'mac' / 'scripts' / 'install.sh', resources / 'scripts' / 'install.sh')
    shutil.copytree(REPO / 'mac' / 'LaunchAgent', resources / 'LaunchAgent')
    contents = resources.parent
    for path in (contents / 'MacOS' / 'lml', contents / 'Helpers' / 'lml-mic'):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\n')
        path.chmod(0o755)
    stubs = tmp_path / 'bin'
    stubs.mkdir()
    for name in ('launchctl', 'tmutil', 'swift', 'python3'):
        (stubs / name).write_text(f'#!/bin/sh\necho "{name} $*" >> "{tmp_path}/calls"\n')
        (stubs / name).chmod(0o755)
    environment = {**os.environ, 'HOME': str(home), 'PATH': f'{stubs}:/usr/bin:/bin:/usr/sbin:/sbin'}
    result = subprocess.run(['bash', str(resources / 'scripts' / 'install.sh')], capture_output=True, text=True, env=environment)
    assert result.returncode == 0, result.stderr
    agent = plistlib.loads((home / 'Library' / 'LaunchAgents' / 'sh.hereby.recorder.plist').read_bytes())
    assert agent['ProgramArguments'] == [f'{home}/Applications/LiveMeetingListener.app/Contents/MacOS/lml', 'run']
    assert agent['StandardOutPath'] == f'{home}/Library/Logs/LiveMeetingListener/stdout.log'
    assert agent['KeepAlive'] is True and agent['Label'] == 'sh.hereby.recorder'
    assert (home / 'Library' / 'Application Support' / 'LiveMeetingListener' / 'bin' / 'lml-mic').exists()
    used = (tmp_path / 'calls').read_text()
    assert 'swift' not in used and 'python3' not in used
