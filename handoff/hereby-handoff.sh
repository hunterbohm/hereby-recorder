#!/bin/sh
# Usage: hereby-handoff.sh SESSION_DIR
# Prints the finished session's transcript path on stdout for the user's agent, once. Needs no Hermes and no network.
set -eu
umask 077

if [ "$#" -ne 1 ]; then
    echo "usage: $0 SESSION_DIR" >&2
    exit 2
fi
if [ ! -d "$1" ]; then
    echo "hereby-handoff: $1 is not a folder." >&2
    exit 1
fi
session=$(cd "$1" && pwd -P)
transcript=$session/transcript.jsonl
meta=$session/meta.json
marker=$session/handoff.json

state=$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$meta" 2>/dev/null | head -n 1)
case $state in
    closed | failed | crashed) ;;
    *)
        echo "hereby-handoff: $session has not ended." >&2
        exit 3 ;;
esac
if [ ! -f "$transcript" ]; then
    echo "hereby-handoff: $session has no transcript." >&2
    exit 1
fi

bytes=$(wc -c < "$transcript" | tr -d ' ')
if [ -f "$marker" ] && grep -q "\"transcript_bytes\": $bytes[,}]" "$marker"; then
    echo "hereby-handoff: $session was already handed off." >&2
    exit 0
fi
if [ "$bytes" -eq 0 ]; then
    echo "hereby-handoff: $session has an empty transcript, so nothing was handed off." >&2
    exit 0
fi

printf '{"at": "%s", "state": "%s", "transcript_bytes": %s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$state" "$bytes" > "$marker.tmp"
mv "$marker.tmp" "$marker"
printf '%s\n' "$transcript"
