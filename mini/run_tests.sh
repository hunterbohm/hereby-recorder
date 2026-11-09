#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
[ "$#" -eq 0 ] && set -- mini/tests
limit=
for tool in timeout gtimeout; do
    if command -v "$tool" >/dev/null 2>&1; then limit="$tool 180"; break; fi
done
# shellcheck disable=SC2086
exec $limit uv run -q --no-project --python 3.12 --with pytest pytest -q -p no:cacheprovider "$@"
