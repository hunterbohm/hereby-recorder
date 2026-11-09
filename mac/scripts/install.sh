#!/bin/bash
set -euo pipefail
umask 077
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
label=sh.hereby.recorder
plist="$HOME/Library/LaunchAgents/$label.plist"
app="$HOME/Applications/LiveMeetingListener.app/Contents/MacOS/lml"
if [[ ! -x "$app" ]]; then
    printf 'Build the app with %s/scripts/build-app.sh first.\n' "$package_dir" >&2
    exit 1
fi
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/LiveMeetingListener" "$HOME/Library/Application Support/LiveMeetingListener/sessions" "$HOME/Library/Application Support/LiveMeetingListener-test/sessions"
chmod 700 "$HOME/Library/Logs/LiveMeetingListener" "$HOME/Library/Application Support/LiveMeetingListener" "$HOME/Library/Application Support/LiveMeetingListener/sessions" "$HOME/Library/Application Support/LiveMeetingListener-test" "$HOME/Library/Application Support/LiveMeetingListener-test/sessions"
python3 - "$package_dir/LaunchAgent/$label.plist" "$plist" "$HOME" <<'PY'
import os
import plistlib
import sys
source, target, user_home = sys.argv[1:]
with open(source, 'rb') as handle:
    value = plistlib.load(handle)
value['ProgramArguments'] = [item.replace('__HOME__', user_home) for item in value['ProgramArguments']]
for key in ('StandardOutPath', 'StandardErrorPath'):
    value[key] = value[key].replace('__HOME__', user_home)
with open(target, 'wb') as handle:
    plistlib.dump(value, handle)
os.chmod(target, 0o600)
PY
mic_label=sh.hereby.recorder.mic
mic_plist="$HOME/Library/LaunchAgents/$mic_label.plist"
mkdir -p "$HOME/Library/Application Support/LiveMeetingListener/bin"
swift build -c release --package-path "$package_dir" --product lml-mic
install -m 700 "$package_dir/.build/release/lml-mic" "$HOME/Library/Application Support/LiveMeetingListener/bin/lml-mic"
sed "s|__HOME__|$HOME|g" "$package_dir/LaunchAgent/$mic_label.plist" > "$mic_plist"
chmod 600 "$mic_plist"
launchctl bootout "gui/$(id -u)/$mic_label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$mic_plist"
tmutil addexclusion "$HOME/Library/Application Support/LiveMeetingListener" "$HOME/Library/Application Support/LiveMeetingListener-test"
printf 'launchctl bootstrap gui/$(id -u) "%s"\n' "$plist"
