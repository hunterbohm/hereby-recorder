#!/bin/bash
# Writes the recorder's two LaunchAgents and installs the mic helper, then prints the command that starts the recorder.
# It runs from a clone (mac/scripts/install.sh, which builds the mic helper) or from inside a downloaded release
# (LiveMeetingListener.app/Contents/Resources/scripts/install.sh, which carries a signed mic helper).
set -euo pipefail
umask 077
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
label=sh.hereby.recorder
plist="$HOME/Library/LaunchAgents/$label.plist"
app="$HOME/Applications/LiveMeetingListener.app/Contents/MacOS/lml"
if [[ ! -x "$app" ]]; then
    printf 'Put LiveMeetingListener.app in %s/Applications first: download a release, or build it with mac/scripts/build-app.sh.\n' "$HOME" >&2
    exit 1
fi
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/LiveMeetingListener" "$HOME/Library/Application Support/LiveMeetingListener/sessions" "$HOME/Library/Application Support/LiveMeetingListener-test/sessions"
chmod 700 "$HOME/Library/Logs/LiveMeetingListener" "$HOME/Library/Application Support/LiveMeetingListener" "$HOME/Library/Application Support/LiveMeetingListener/sessions" "$HOME/Library/Application Support/LiveMeetingListener-test" "$HOME/Library/Application Support/LiveMeetingListener-test/sessions"
# plutil ships with macOS, so a downloaded install needs no developer tools. Replacing in bash keeps any character in
# $HOME literal.
cp "$package_dir/LaunchAgent/$label.plist" "$plist"
chmod 600 "$plist"
for key in StandardOutPath StandardErrorPath; do
    value="$(plutil -extract "$key" raw -o - "$plist")"
    plutil -replace "$key" -string "${value//__HOME__/$HOME}" "$plist"
done
# -replace on an array index inserts, so the program path is removed and inserted.
program="$(plutil -extract ProgramArguments.0 raw -o - "$plist")"
plutil -remove ProgramArguments.0 "$plist"
plutil -insert ProgramArguments.0 -string "${program//__HOME__/$HOME}" "$plist"
mic_label=sh.hereby.recorder.mic
mic_plist="$HOME/Library/LaunchAgents/$mic_label.plist"
mkdir -p "$HOME/Library/Application Support/LiveMeetingListener/bin"
if [[ -x "$package_dir/../Helpers/lml-mic" ]]; then
    install -m 700 "$package_dir/../Helpers/lml-mic" "$HOME/Library/Application Support/LiveMeetingListener/bin/lml-mic"
else
    swift build -c release --package-path "$package_dir" --product lml-mic
    install -m 700 "$package_dir/.build/release/lml-mic" "$HOME/Library/Application Support/LiveMeetingListener/bin/lml-mic"
fi
sed "s|__HOME__|$HOME|g" "$package_dir/LaunchAgent/$mic_label.plist" > "$mic_plist"
chmod 600 "$mic_plist"
launchctl bootout "gui/$(id -u)/$mic_label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$mic_plist"
tmutil addexclusion "$HOME/Library/Application Support/LiveMeetingListener" "$HOME/Library/Application Support/LiveMeetingListener-test"
printf 'launchctl bootstrap gui/$(id -u) "%s"\n' "$plist"
