#!/bin/bash
# Builds the app at the tagged HEAD, installs it, and restarts the recorder. Usage: build-app.sh [--force] [--new-bundle-id]
# Installing never cuts off a recording: it refuses while a session is active or paused (unless --force),
# stops the recorder through launchd so it closes its session, and swaps the bundle only after it has exited.
# A build whose bundle id differs from the installed app's refuses unless --new-bundle-id is given: macOS keys the
# microphone and system audio permissions to the bundle id, so the recorder would run without them.
set -euo pipefail
umask 077
force=0
new_bundle_id=0
for argument in "$@"; do
    case "$argument" in
        --force) force=1 ;;
        --new-bundle-id) new_bundle_id=1 ;;
        *) printf 'usage: build-app.sh [--force] [--new-bundle-id]\n' >&2; exit 2 ;;
    esac
done
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${LML_APP_DESTINATION:-$HOME/Applications/LiveMeetingListener.app}"
launchctl_bin="${LML_LAUNCHCTL:-launchctl}"
new_label=sh.hereby.recorder
# The early label is spelled in two parts so the personal-name scan finds nothing in tracked files.
old_label="com.hun""terbohm.livemeetinglistener"
domain="gui/$(id -u)"
root="$HOME/Library/Application Support/LiveMeetingListener"
lml_bin="${LML_BIN:-$app_dir/Contents/MacOS/lml}"
if ! version="$(git -C "$package_dir" describe --tags --exact-match HEAD 2>/dev/null)"; then
    printf 'The app requires a tagged commit.\n' >&2
    exit 1
fi

# Nothing has been stopped or changed yet. A changed identity needs the person at the Mac to allow the permissions again.
if [[ $new_bundle_id == 0 && -f "$app_dir/Contents/Info.plist" ]]; then
    installed_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
    new_id="$(plutil -extract CFBundleIdentifier raw -o - "$package_dir/Info.plist")"
    if [[ "$installed_id" != "$new_id" ]]; then
        printf 'Not installing: this build changes the app identity from "%s" to "%s".\n' "${installed_id:-unknown}" "$new_id" >&2
        printf 'macOS will ask again for microphone and system audio access, and the recorder runs without them until you allow them.\n' >&2
        printf 'Run it again with --new-bundle-id when you are at the Mac, allow the permissions, then run mac/scripts/migrate-labels.sh.\nNothing was stopped or changed.\n' >&2
        exit 1
    fi
fi

field_of() { "$launchctl_bin" print "$domain/$1" 2>/dev/null | sed -n "s/^[[:space:]]*$2 = //p" | head -1; }
job_field() { field_of "$label" "$1"; }

# Only a job that runs this bundle needs stopping; a build to another destination leaves the recorder alone. Before
# mac/scripts/migrate-labels.sh has run, the recorder is the early label, so whichever of the two labels is loaded and
# runs this bundle is the managed job. With both loaded there is no single job to stop, so the build refuses.
label="$new_label"
managed=0
runs_this_bundle() { [[ "$(field_of "$1" program)" == "$app_dir/Contents/MacOS/lml" ]]; }
if runs_this_bundle "$new_label" && runs_this_bundle "$old_label"; then
    printf 'Not installing: both %s and %s are loaded and run this app.\nRun mac/scripts/migrate-labels.sh to finish moving to the new label, then build again.\n' "$new_label" "$old_label" >&2
    exit 1
elif runs_this_bundle "$new_label"; then
    managed=1
elif runs_this_bundle "$old_label"; then
    label="$old_label"
    managed=1
fi
plist="$HOME/Library/LaunchAgents/$label.plist"

busy_reason() {
    [[ $managed == 1 && -n "$(job_field pid)" ]] || return 0
    [[ -x "$lml_bin" ]] || return 0
    local line state
    if ! line="$("$lml_bin" status 2>/dev/null)"; then printf 'lml status failed'; return 0; fi
    state="$(awk '{print $2}' <<<"$line")"
    case "$state" in
        active|stale) printf 'a session is %s (%s)' "$state" "$line"; return 0 ;;
    esac
    [[ -e "$root/pause.json" ]] && printf 'recording is paused for the current meeting (%s)' "$root/pause.json"
    return 0
}
refuse_if_busy() {
    local reason; reason="$(busy_reason)"
    [[ -z "$reason" || $force == 1 ]] && return 0
    printf 'Not installing: %s.\nStopping the recorder now would cut that recording. Wait for the meeting to end, or rerun with --force.\n' "$reason" >&2
    exit 3
}
refuse_if_busy

swift build --package-path "$package_dir" -c release
binary_dir="$(swift build --package-path "$package_dir" -c release --show-bin-path)"

# The new bundle is built beside the old one and renamed into place. Copying over the binary of a
# running recorder rewrites pages it has mapped, and the kernel kills it for an invalid signature.
mkdir -p "$(dirname "$app_dir")"
staging="$(mktemp -d "$(dirname "$app_dir")/.lml-build.XXXXXX")"
stopped=0
restart() {
    [[ $stopped == 1 ]] || return 0
    stopped=0
    "$launchctl_bin" bootstrap "$domain" "$plist"
    "$launchctl_bin" kickstart "$domain/$label" 2>/dev/null || true
}
# A failure between stop and restart must not leave the recorder down.
finish() { rm -rf "$staging"; restart || printf 'Recorder not restarted. Run: launchctl bootstrap %s "%s"\n' "$domain" "$plist" >&2; }
trap finish EXIT
mkdir -p "$staging/new.app/Contents/MacOS"
cp "$binary_dir/lml" "$staging/new.app/Contents/MacOS/lml"
cp "$package_dir/Info.plist" "$staging/new.app/Contents/Info.plist"
mkdir -p "$staging/new.app/Contents/Resources"
cp "$package_dir/../handoff/hereby-handoff.sh" "$staging/new.app/Contents/Resources/hereby-handoff.sh"
cp "$package_dir/AppIcon.icns" "$staging/new.app/Contents/Resources/AppIcon.icns"   # drawn by scripts/make-icon.swift
plutil -replace CFBundleShortVersionString -string "$version" "$staging/new.app/Contents/Info.plist"
"$package_dir/scripts/sign.sh" "$staging/new.app" sh.hereby.recorder

# The build took minutes; a call may have started since the first check.
refuse_if_busy
if [[ $managed == 1 ]]; then
    old_pid="$(job_field pid)"
    if [[ -n "$old_pid" ]]; then
        # bootout sends SIGTERM and waits for the exit, so the recorder closes its session first. Unlike
        # kill, it also stops launchd's KeepAlive from relaunching the old binary mid-swap.
        started=$SECONDS
        stopped=1
        "$launchctl_bin" bootout "$domain/$label"
        for _ in $(seq 1 600); do kill -0 "$old_pid" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$old_pid" 2>/dev/null; then printf 'Recorder pid %s did not exit; bundle not replaced.\n' "$old_pid" >&2; exit 1; fi
        printf 'recorder exited after %ss\n' "$((SECONDS - started))"
    fi
fi
[[ -e "$app_dir" ]] && mv "$app_dir" "$staging/old.app"
mv "$staging/new.app" "$app_dir"
if [[ $managed == 1 ]]; then
    restart
    for _ in $(seq 1 100); do [[ -n "$(job_field pid)" ]] && break; sleep 0.1; done
    [[ -n "$(job_field pid)" ]] || { printf 'Recorder did not start.\n' >&2; exit 1; }
    printf 'recorder running as pid %s\n' "$(job_field pid)"
fi
printf '%s\n' "$app_dir"
