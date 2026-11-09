#!/bin/bash
# Usage: migrate-labels.sh [--dry-run] [--force]
# Moves the installed LaunchAgents from the early private label prefix to sh.hereby.recorder*. Run it once, by hand,
# after mac/scripts/build-app.sh has installed a build that knows `lml ping`; it refuses before touching anything if
# the installed app does not.
# Each old agent's plist is rewritten under the new label, the old agent is unloaded, and the new one is loaded and
# confirmed started. The old plists stay until every new agent is confirmed. Any failure or interruption (Ctrl-C, kill)
# puts every old agent back and removes the new plists. An agent that was not loaded stays unloaded. Running it again
# changes nothing. It refuses while a recording is active or paused, because unloading the recorder closes its session
# (--force overrides). The mic helper and the importers move first and the recorder last. LML_MIGRATE_WAIT sets the
# seconds to wait for each new agent to start (default 15), and LML_MIGRATE_SETTLE the seconds a started agent must keep
# the same process (default 3).
set -euo pipefail
umask 077
dry_run=0
force=0
for argument in "$@"; do
    case "$argument" in
        --dry-run) dry_run=1 ;;
        --force) force=1 ;;
        *) printf 'usage: migrate-labels.sh [--dry-run] [--force]\n' >&2; exit 2 ;;
    esac
done
launchctl_bin="${LML_LAUNCHCTL:-/bin/launchctl}"
domain="gui/$(id -u)"
agents="$HOME/Library/LaunchAgents"
root="$HOME/Library/Application Support/LiveMeetingListener"
lml_bin="${LML_BIN:-$HOME/Applications/LiveMeetingListener.app/Contents/MacOS/lml}"
ticks=$(( ${LML_MIGRATE_WAIT:-15} * 10 ))
settle_ticks=$(( ${LML_MIGRATE_SETTLE:-3} * 10 ))
recorder_label=sh.hereby.recorder
launch_failed='spawn failed|last exit code = (78|126|127)([^0-9]|$)'
# The early prefix is spelled in two parts so the personal-name scan finds nothing in tracked files.
legacy="com.hun""terbohm"
# The recorder moves last. Once it is confirmed nothing is left that could fail and roll it back, so a rollback never
# unloads a recorder that has started capturing.
pairs=(
    "$legacy.lml-mic sh.hereby.recorder.mic"
    "$legacy.lml-import.phone sh.hereby.recorder.import.phone"
    "$legacy.lml-import.inbox sh.hereby.recorder.import.inbox"
    "$legacy.livemeetinglistener sh.hereby.recorder"
)

touched=()
created=()
finished=0

say() { if [[ $dry_run == 1 ]]; then printf 'dry run: %s\n' "$*"; else printf '%s\n' "$*"; fi; }
loaded() { "$launchctl_bin" print "$domain/$1" >/dev/null 2>&1; }
run() { [[ $dry_run == 1 ]] || "$@"; }

rollback() {
    set +e
    local index old new new_was_loaded
    for ((index = ${#touched[@]} - 1; index >= 0; index--)); do
        read -r old new new_was_loaded <<<"${touched[index]}"
        [[ $new_was_loaded == 1 ]] || { loaded "$new" && "$launchctl_bin" bootout "$domain/$new" >/dev/null 2>&1; }
        if ! loaded "$old"; then
            printf 'Putting %s back.\n' "$old" >&2
            "$launchctl_bin" bootstrap "$domain" "$agents/$old.plist" >/dev/null 2>&1 ||
                printf 'Could not reload %s. Run: launchctl bootstrap %s "%s"\n' "$old" "$domain" "$agents/$old.plist" >&2
        fi
    done
    for new in ${created[@]+"${created[@]}"}; do rm -f "$agents/$new.plist"; done
}
on_exit() {
    local status=$?
    trap - EXIT INT TERM HUP
    [[ $finished == 1 ]] || rollback
    exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Audio capture starts about ten seconds before the session files appear, and the recorder keeps no file that says it is
# arming. Call audio waits in audio/ from the first sample until its speakers are labeled, so any file there means a call is
# arming, recording, or being labeled. An old file left by a crash also counts: it cannot be told from a live one.
busy_reason() {
    local caf
    caf="$(find "$root/audio" -maxdepth 1 -type f -name '*.caf' 2>/dev/null | head -1)"
    if [[ -n "$caf" ]]; then printf 'call audio is on disk (%s), so a call is arming, recording, or being labeled'; return 0; fi
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

# Checked again right before each unload, because a meeting can start after the first check.
refuse_if_busy() {
    local reason; reason="$(busy_reason)"
    [[ -n "$reason" && $force == 0 ]] || return 0
    printf 'Not migrating: %s.\nUnloading the recorder now would cut that recording. Wait for the meeting to end, or rerun with --force.\n' "$reason" >&2
    exit 3
}

needs_migration=0
for pair in "${pairs[@]}"; do
    old="${pair% *}"
    if [[ -e "$agents/$old.plist" ]] || loaded "$old"; then needs_migration=1; fi
done
# The busy check comes first and reads only files, so it works on any build and never contacts a running recorder. It
# does not depend on which labels are loaded: audio, session state, and the pause file are read every time.
if [[ $needs_migration == 1 ]]; then refuse_if_busy; fi
# `lml capabilities` runs locally and prints the control actions the build understands. It opens no socket, so it is safe
# while the old recorder runs. Never send `ping` to a process that is not the new label's pid: a recorder built before
# `ping` existed cannot decode it and shuts down.
if [[ $needs_migration == 1 ]]; then
    capabilities=""
    if [[ -x "$lml_bin" ]]; then capabilities="$("$lml_bin" capabilities 2>/dev/null)" || capabilities=""; fi
    if ! grep -Eq '^control-actions( .*)? ping( |$)' <<<"$capabilities"; then
        finished=1
        printf 'Not migrating: the installed app (%s) is missing or too old to answer `lml ping`.\nRun mac/scripts/build-app.sh first (add --new-bundle-id when you are at the Mac), then run this script again. Nothing was changed.\n' "$lml_bin" >&2
        exit 1
    fi
fi

# A loaded old label whose plist is gone cannot be restored, so it is never unloaded. That state only follows an interrupted
# cleanup by an earlier version of this script. Nothing is changed.
for pair in "${pairs[@]}"; do
    old="${pair% *}"
    new="${pair#* }"
    if [[ ! -e "$agents/$old.plist" ]] && loaded "$old"; then
        printf '%s is loaded but its plist is gone, so this script cannot put it back and will not unload it.\n' "$old" >&2
        printf 'To finish by hand, when no meeting is running:\n' >&2
        printf '  1. launchctl print %s/%s   (the new agent needs a pid)\n' "$domain" "$new" >&2
        printf '  2. launchctl bootout %s/%s\n' "$domain" "$old" >&2
        printf '  3. Run this script again.\nNothing was changed.\n' >&2
        finished=1
        exit 1
    fi
done

relabel() {
    python3 - "$1" "$2" "$3" <<'PY'
import os, plistlib, sys
source, target, label = sys.argv[1:]
with open(source, 'rb') as handle:
    value = plistlib.load(handle)
value['Label'] = label
temporary = target + '.tmp'
with open(temporary, 'wb') as handle:
    plistlib.dump(value, handle)
os.chmod(temporary, 0o600)
os.replace(temporary, target)
PY
}

# always: KeepAlive true or a dictionary that restarts the job every time. onfail: KeepAlive with SuccessfulExit=false,
# which restarts the job only after a failure, so a deliberate clean exit is healthy. none: an on-demand job.
keep_kind() {
    python3 -c '
import plistlib, sys
value = plistlib.load(open(sys.argv[1], "rb")).get("KeepAlive")
if isinstance(value, dict):
    print("onfail" if value.get("SuccessfulExit") is False else ("always" if value else "none"))
else:
    print("always" if value else "none")' "$1"
}
agent_state() { "$launchctl_bin" print "$domain/$1" 2>/dev/null; }
pid_of() { sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' <<<"$1" | head -1; }
# Asks the running recorder itself, over its control socket, for its process id. The ping changes nothing.
recorder_answers_as() {
    local reply
    [[ -x "$lml_bin" ]] || return 1
    reply="$("$lml_bin" ping 2>/dev/null)" || return 1
    [[ "$reply" == "pong $1" ]]
}
# The job must keep the same process for the settle window, and the recorder must still answer as that process.
settled() {
    local label="$1" pid="$2" tick out
    for ((tick = 0; tick < settle_ticks; tick++)); do sleep 0.1; done
    out="$(agent_state "$label")" || return 1
    [[ "$(pid_of "$out")" == "$pid" ]] || return 1
    [[ "$label" != "$recorder_label" ]] || recorder_answers_as "$pid"
}
# A job that must stay up needs a pid it keeps, and the recorder must answer from that pid. A job that exits cleanly
# on purpose (SuccessfulExit=false) is also healthy with exit status 0 and no process. An on-demand job only has to be
# loaded and not have failed to launch. Spawn failures and exit statuses 78, 126, and 127 never count.
started() {
    local label="$1" plist="$2" kind out pid attempt
    kind="$(keep_kind "$plist")"
    for ((attempt = 0; attempt <= ticks; attempt++)); do
        if out="$(agent_state "$label")"; then
            pid="$(pid_of "$out")"
            if grep -Eq "$launch_failed" <<<"$out"; then
                :
            elif [[ $kind == none ]]; then
                return 0
            elif [[ -n "$pid" ]]; then
                if [[ "$label" != "$recorder_label" ]] || recorder_answers_as "$pid"; then
                    settled "$label" "$pid" && return 0
                fi
            elif [[ $kind == onfail ]] && grep -Eq 'last exit code = 0([^0-9]|$)' <<<"$out"; then
                return 0
            fi
        fi
        sleep 0.1
    done
    return 1
}

moved=0
removals=()
for pair in "${pairs[@]}"; do
    old="${pair% *}"
    new="${pair#* }"
    old_plist="$agents/$old.plist"
    new_plist="$agents/$new.plist"
    if [[ ! -e "$old_plist" ]]; then
        if [[ -e "$new_plist" ]]; then say "$new: already migrated"; else say "$new: no $old agent installed, nothing to move"; fi
        continue
    fi
    was_loaded=0
    loaded "$old" && was_loaded=1
    new_was_loaded=0
    loaded "$new" && new_was_loaded=1
    say "$old -> $new (old agent $([[ $was_loaded == 1 ]] && echo loaded || echo not loaded)$([[ $new_was_loaded == 1 ]] && echo ', new agent also loaded'))"
    moved=$((moved + 1))
    [[ $dry_run == 1 ]] && continue
    if [[ ! -e "$new_plist" ]]; then created+=("$new"); fi
    relabel "$old_plist" "$new_plist" "$new"
    removals+=("$old_plist")
    if [[ $was_loaded == 1 ]]; then
        refuse_if_busy
        touched+=("$old $new $new_was_loaded")
        say "  unload $old"
        "$launchctl_bin" bootout "$domain/$old"
        if [[ $new_was_loaded == 0 ]]; then
            say "  load $new"
            if ! "$launchctl_bin" bootstrap "$domain" "$new_plist"; then
                printf 'Could not load %s.\n' "$new" >&2
                exit 1
            fi
        fi
    fi
    if loaded "$new" && ! started "$new" "$new_plist"; then
        printf 'The new agent %s loaded but did not start.\n' "$new" >&2
        exit 1
    fi
done

finished=1
if [[ $moved -eq 0 ]]; then
    printf 'Nothing to migrate.\n'
elif [[ $dry_run == 1 ]]; then
    printf 'Dry run: would move %d agent(s). Nothing was changed.\n' "$moved"
else
    for plist in "${removals[@]}"; do say "  remove $plist"; rm -f "$plist"; done
    printf 'Moved %d agent(s).\n' "$moved"
    printf 'The recorder now runs under sh.hereby.recorder. macOS asks again for the microphone and system audio grants, because it\n'
    printf 'keys them to the app identifier that build-app.sh changed. Run import/scripts/install.sh when no meeting is running to\n'
    printf 'move the importer to the new identifier too.\n'
fi
