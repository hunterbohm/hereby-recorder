#!/bin/sh
set -eu

mini=$(cd "$(dirname "$0")" && pwd -P)
job=listener-meeting-processing
prompt='A meeting ended, or the hourly check found one waiting. Run the meeting-processing skill now. The script output lists what is not filed yet: "listener" captures (check_listener.py, the primary source) and "granola" notes (check_granola.py, the fallback). Process each meeting once, oldest first, through every step of the skill. When a meeting has both a listener capture and a Granola note, file the listener capture; the other then counts as a duplicate. A meeting is finished only when its watcher'\''s --mark prints "processed": true; a refusal names the step you skipped: do that step, then mark again. After each mark, list both watchers again. You are done only when both print []. Report every --mark output verbatim. Never say a meeting is processed without the gate'\''s "processed": true.'

dry_run=0
case ${1-} in
    --dry-run) dry_run=1 ;;
    '') ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

run() {
    if [ "$dry_run" = 1 ]; then
        for arg; do printf "'%s' " "$arg"; done
        echo
    else
        "$@"
    fi
}

hermes_python() {
    (
        eval "$(grep -E '^export (HERMES_HOME|VIRTUAL_ENV|PYTHONPATH)=' "$(command -v hermes)")"
        exec "$VIRTUAL_ENV/bin/python" "$@"
    )
}

run mkdir -p "$HOME/.local/bin" "$HOME/.hermes/scripts"
for command in live-meeting-forget live-meeting-receive live-meeting-done live-meeting-sync-status live-meeting-ask live-meeting-quick meeting-bot; do
    if [ -e "$mini/$command" ]; then
        run chmod +x "$mini/$command"
    fi
    run ln -sfn "$mini/$command" "$HOME/.local/bin/$command"
done

# Hermes skills that drive these commands: live-meeting answers questions about a call, meeting-bot runs the notetaker.
run mkdir -p "$HOME/.hermes/skills"
for skill in live-meeting meeting-bot; do
    run ln -sfn "${mini%/mini}/hermes/skills/$skill" "$HOME/.hermes/skills/$skill"
done

# Hermes refuses a cron script that resolves outside ~/.hermes/scripts, so this is a copy, not a link.
# Removing first keeps cp from writing through an old symlink into command-center.
watch=$HOME/.hermes/scripts/listener-watch.sh
if [ -L "$watch" ] || ! cmp -s "$mini/hermes-listener-watch.sh" "$watch"; then
    run rm -f "$watch"
    run cp "$mini/hermes-listener-watch.sh" "$watch"
fi

# The notetaker's tick: starts a bot a minute before a call the user picked, watches it, and files the call. Its output
# is texted to the user, so it prints only when something needs them. A script failure is not texted (every minute).
tick=$HOME/.hermes/scripts/meeting-bot-tick.sh
if [ -L "$tick" ] || ! cmp -s "$mini/hermes-meeting-bot-tick.sh" "$tick"; then
    run rm -f "$tick"
    run cp "$mini/hermes-meeting-bot-tick.sh" "$tick"
fi
run chmod +x "$tick"
tick_job=meeting-bot-tick
tick_state=$(hermes_python -c "from cron.jobs import resolve_job_ref; print(\"present\" if resolve_job_ref(\"$tick_job\") else \"absent\")")
case $tick_state in
    present)
        run hermes cron edit "$tick_job" --schedule 'every 1m' --script meeting-bot-tick.sh --no-agent \
            --deliver photon --failure-deliver local ;;
    absent)
        run hermes cron create --name "$tick_job" --script meeting-bot-tick.sh --no-agent \
            --deliver photon --failure-deliver local 'every 1m' ;;
    *)
        echo "Unexpected Hermes job lookup output: $tick_state" >&2
        exit 1 ;;
esac

state=$(hermes_python -c "from cron.jobs import resolve_job_ref; print(\"present\" if resolve_job_ref(\"$job\") else \"absent\")")
case $state in
    present)
        run hermes cron edit "$job" --schedule 'every 60m' --prompt "$prompt" --skill meeting-processing \
            --script listener-watch.sh --agent --deliver local ;;
    absent)
        run hermes cron create --name "$job" --skill meeting-processing --script listener-watch.sh \
            --deliver local 'every 60m' "$prompt" ;;
    *)
        echo "Unexpected Hermes job lookup output: $state" >&2
        exit 1 ;;
esac
run hermes_python -c "import json, sys; from tools.cronjob_tools import cronjob; result = json.loads(cronjob(action=\"update\", job_id=\"$job\", enabled_toolsets=[\"terminal\", \"file\", \"skills\"])); sys.exit(0 if result.get(\"success\") else result.get(\"error\", \"update failed\"))"
