import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
NAMES = ['hun' + 'ter', 'sky' + 'ro', 'nec' + 'tive', 'pri' + 'mo', 'max ' + 'alderman', 'north' + 'wind', 'anas' + 'tasia', 'ard' + 'ant',
         'dar' + 'yl', 'cor' + 'vid']
DENY = re.compile('|'.join(NAMES), re.IGNORECASE)
HOLDER = {'LICENSE': 'Copyright (c) 2026 Hun' + 'ter Bohm'}


def candidates(root):
    listed = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root,
                            capture_output=True, check=True).stdout.decode().split('\0')
    return [name for name in listed if name and (root / name).is_file()]


def offenders(root, names):
    found = []
    for name in names:
        if DENY.search(name):
            found.append(f'{name}: the file name')
        try:
            text = (root / name).read_text()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if DENY.search(line) and line.strip() != HOLDER.get(name):
                found.append(f'{name}:{number}: {line.strip()[:80]}')
    return found


def test_no_tracked_file_names_a_person_or_client():
    assert offenders(REPO, candidates(REPO)) == []


def test_the_scan_fails_on_each_name(tmp_path):
    subprocess.run(['git', 'init', '-q'], cwd=tmp_path, check=True)
    for index, name in enumerate(NAMES):
        (tmp_path / f'note{index}.txt').write_text(f'a line that names {name.title()}\nand a clean line\n')
    (tmp_path / 'clean.txt').write_text('nothing personal here\n')
    found = offenders(tmp_path, candidates(tmp_path))
    assert len(found) == len(NAMES) and all(entry.startswith('note') for entry in found)


def test_the_scan_catches_a_name_in_a_file_name(tmp_path):
    subprocess.run(['git', 'init', '-q'], cwd=tmp_path, check=True)
    (tmp_path / f'{NAMES[0]}.plist').write_text('clean\n')
    assert offenders(tmp_path, candidates(tmp_path)) == [f'{NAMES[0]}.plist: the file name']


def test_only_the_license_holder_line_is_allowed(tmp_path):
    subprocess.run(['git', 'init', '-q'], cwd=tmp_path, check=True)
    (tmp_path / 'LICENSE').write_text(HOLDER['LICENSE'] + '\n')
    (tmp_path / 'README.md').write_text(HOLDER['LICENSE'] + '\n')
    assert offenders(tmp_path, candidates(tmp_path)) == ['README.md:1: ' + HOLDER['LICENSE']]


def test_every_launch_agent_uses_the_recorder_prefix():
    plists = sorted(REPO.glob('*/LaunchAgent/*.plist'))
    assert len(plists) == 4
    for plist in plists:
        assert plist.name.startswith('sh.hereby.recorder'), plist
        assert f'<string>{plist.stem}</string>' in plist.read_text(), plist
