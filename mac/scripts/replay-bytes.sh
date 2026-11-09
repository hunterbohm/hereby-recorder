#!/bin/bash
# Usage: replay-bytes.sh SESSION_DIR [LEGACY_COMMIT]
# Replays a recorded session through the legacy rsync outbox (LEGACY_COMMIT, default d8345e5)
# and the current outbox against stub minis, and prints bytes written per call on each machine.
set -euo pipefail
session="$(cd "$1" && pwd)"
legacy_commit="${2:-d8345e5}"
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(git -C "$package_dir" rev-parse --show-toplevel)"
work="$(mktemp -d "${TMPDIR:-/tmp}/lml-replay.XXXXXX")"
trap 'rm -rf "$work"' EXIT
git -C "$repo_dir" archive "$legacy_commit" mac | tar -x -C "$work"
cp "$package_dir/Tests/LMLCoreTests/ReplaySimulation.swift" "$package_dir/scripts/replay/LegacyOutboxReplay.swift" "$work/mac/Tests/LMLCoreTests/"
LML_REPLAY_SESSION="$session" swift test --package-path "$work/mac" --filter LegacyOutboxReplay 2>&1 | grep '^REPLAY'
LML_REPLAY_SESSION="$session" swift test --package-path "$package_dir" --filter OutboxReplay 2>&1 | grep '^REPLAY'
