#!/bin/bash
set -euo pipefail
umask 077
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
support="$HOME/Library/Application Support/LiveMeetingListener"
inbox="${LML_IMPORT_INBOX:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Meeting Inbox}"
since="${LML_IMPORT_SINCE:-$(date +%F)}"
export TMPDIR="$package_dir/.tmp" CLANG_MODULE_CACHE_PATH="$package_dir/.cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$package_dir/.cache/swift"
mkdir -p "$TMPDIR"
swift build -c release --disable-sandbox --package-path "$package_dir" --cache-path "$package_dir/.cache" --config-path "$package_dir/.config" --security-path "$package_dir/.security"
mkdir -p "$support/bin" "$support/imports" "$HOME/Library/Logs/LiveMeetingListener" "$HOME/Library/LaunchAgents" "$inbox"
chmod 700 "$support" "$support/bin" "$support/imports" "$HOME/Library/Logs/LiveMeetingListener"
# Signed with the recorder's certificate so the Full Disk Access grant survives a rebuild, and
# renamed into place so a running import keeps its own binary.
staged="$(mktemp "$support/bin/.lml-import.XXXXXX")"
trap 'rm -f "$staged"' EXIT
cp "$package_dir/.build/release/lml-import" "$staged"
chmod 700 "$staged"
"$package_dir/../mac/scripts/sign.sh" "$staged" sh.hereby.recorder.import
mv "$staged" "$support/bin/lml-import"
for label in sh.hereby.recorder.import.phone sh.hereby.recorder.import.inbox; do
    python3 - "$package_dir/LaunchAgent/$label.plist" "$HOME/Library/LaunchAgents/$label.plist" "$HOME" "$since" "$inbox" <<'PY'
import os, plistlib, sys
source, target, home, since, inbox = sys.argv[1:]
def fill(text): return text.replace('__HOME__', home).replace('__SINCE__', since).replace('__INBOX__', inbox)
with open(source, 'rb') as handle:
    value = plistlib.load(handle)
value['ProgramArguments'] = [fill(item) for item in value['ProgramArguments']]
value['WatchPaths'] = [fill(item) for item in value['WatchPaths']]
for key in ('StandardOutPath', 'StandardErrorPath'):
    value[key] = fill(value[key])
with open(target, 'wb') as handle:
    plistlib.dump(value, handle)
os.chmod(target, 0o600)
PY
    printf 'launchctl bootstrap gui/$(id -u) "%s"\n' "$HOME/Library/LaunchAgents/$label.plist"
done
