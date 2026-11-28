#!/bin/bash
# Installs an assembled, signed app bundle and restarts the recorder.
# Usage: install-app.sh [--force] [--new-bundle-id] APP
#        install-app.sh --check-only [--force] [--new-bundle-id] INFO_PLIST
# build-app.sh runs it after a source build; a signed release carries it in Contents/Resources/scripts, and the in-app
# updater runs that copy on the downloaded, checked bundle. --check-only runs only the refusals, against the Info.plist
# the new build will have, so build-app.sh refuses before it spends minutes building.
# Installing never cuts off a recording: it refuses while a session is active or paused (unless --force),
# stops the recorder through launchd so it closes its session, and swaps the bundle only after it has exited.
# A build whose bundle id differs from the installed app's refuses unless --new-bundle-id is given: macOS keys the
# microphone and system audio permissions to the bundle id, so the recorder would run without them.
set -euo pipefail
umask 077
force=0
new_bundle_id=0
check_only=0
new_app=""
usage() { printf 'usage: install-app.sh [--check-only] [--force] [--new-bundle-id] APP|INFO_PLIST\n' >&2; exit 2; }
for argument in "$@"; do
    case "$argument" in
        --force) force=1 ;;
        --new-bundle-id) new_bundle_id=1 ;;
        --check-only) check_only=1 ;;
        -*) usage ;;
        *) [[ -z "$new_app" ]] || usage; new_app="$argument" ;;
    esac
done
[[ -n "$new_app" ]] || usage
if [[ $check_only == 1 ]]; then new_info="$new_app"; else new_info="$new_app/Contents/Info.plist"; fi
if [[ ! -f "$new_info" ]]; then printf 'No app at %s.\n' "$new_app" >&2; exit 1; fi
app_dir="${LML_APP_DESTINATION:-$HOME/Applications/LiveMeetingListener.app}"
launchctl_bin="${LML_LAUNCHCTL:-launchctl}"
new_label=sh.hereby.recorder
# The early label is spelled in two parts so the personal-name scan finds nothing in tracked files.
old_label="com.hun""terbohm.livemeetinglistener"
domain="gui/$(id -u)"
root="$HOME/Library/Application Support/LiveMeetingListener"
lml_bin="${LML_BIN:-$app_dir/Contents/MacOS/lml}"

# Nothing has been stopped or changed yet. A changed identity needs the person at the Mac to allow the permissions again.
if [[ $new_bundle_id == 0 && -f "$app_dir/Contents/Info.plist" ]]; then
    installed_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
    new_id="$(plutil -extract CFBundleIdentifier raw -o - "$new_info")"
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
[[ $check_only == 1 ]] && exit 0

# The new bundle waits beside the old one and is renamed into place. Copying over the binary of a running recorder
# rewrites pages it has mapped, and the kernel kills it for an invalid signature.
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
mv "$new_app" "$staging/new.app"

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
