#!/bin/sh
# Hermes cron script (no-agent): the output is texted to the user, so it must stay empty unless something needs them.
# A crash goes to a file, not to the user, because this runs every minute.
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
export PATH
state="${MEETING_BOT_ROOT:-$HOME/.local/state/meeting-bot}"
mkdir -p "$state" && chmod 700 "$state"
"$HOME/.local/bin/meeting-bot" tick 2>"$state/tick.err" || true
