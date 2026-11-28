#!/bin/bash
# Builds the app at the tagged HEAD from source, signs it with the local certificate, installs it, and restarts the
# recorder. Usage: build-app.sh [--force] [--new-bundle-id]
# install-app.sh does the installing and owns the refusals (a call in progress, a changed bundle id, both launchd
# labels loaded); they run once before the build, so nothing is built for an install that would refuse, and again after.
# Signed, notarized releases come from release.sh instead; this path needs no Apple developer account.
set -euo pipefail
umask 077
flags=()
for argument in "$@"; do
    case "$argument" in
        --force|--new-bundle-id) flags+=("$argument") ;;
        *) printf 'usage: build-app.sh [--force] [--new-bundle-id]\n' >&2; exit 2 ;;
    esac
done
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${LML_APP_DESTINATION:-$HOME/Applications/LiveMeetingListener.app}"
if ! version="$(git -C "$package_dir" describe --tags --exact-match HEAD 2>/dev/null)"; then
    printf 'The app requires a tagged commit.\n' >&2
    exit 1
fi
# Bash 3.2 calls an empty array unbound under set -u, hence the ${flags[@]+...} form.
"$package_dir/scripts/install-app.sh" --check-only ${flags[@]+"${flags[@]}"} "$package_dir/Info.plist"

mkdir -p "$(dirname "$app_dir")"
staging="$(mktemp -d "$(dirname "$app_dir")/.lml-assemble.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
"$package_dir/scripts/assemble-app.sh" "$staging/new.app" "$version"
# The app checks this clone's remote for newer release tags and updates it from the panel's Update link.
plutil -replace HerebyCheckout -string "$(cd "$package_dir/.." && pwd)" "$staging/new.app/Contents/Info.plist"
"$package_dir/scripts/sign.sh" "$staging/new.app" sh.hereby.recorder
"$package_dir/scripts/install-app.sh" ${flags[@]+"${flags[@]}"} "$staging/new.app"
