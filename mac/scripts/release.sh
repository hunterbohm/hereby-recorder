#!/bin/bash
# Builds the tagged HEAD as a signed, notarized release and publishes it. Usage: release.sh [--no-upload] [--public]
# Run it on a Mac with the Developer ID certificate in its keychain, under `infisical run --` (see mac/RELEASING.md):
#   HEREBY_SIGN_IDENTITY   the certificate's name, "Developer ID Application: <company> (<team id>)"
#   HEREBY_TEAM_ID         the ten-character team id; updates must be signed by it
#   HEREBY_UPDATE_KEY      the Ed25519 update key from `lml-release keygen`; every update zip is signed with it
#   HEREBY_UPDATE_REPO     owner/name of the public repo whose releases the app downloads updates from
#   Notarization, one of:  HEREBY_NOTARY_PROFILE (a `notarytool store-credentials` keychain profile), or
#                          HEREBY_NOTARY_KEY (the App Store Connect API key's .p8 text), HEREBY_NOTARY_KEY_ID, HEREBY_NOTARY_ISSUER
#   HEREBY_RELEASE_REPO    optional: owner/name to upload to first; defaults to this clone's GitHub repo
# It writes LiveMeetingListener-<tag>.zip and appcast.json to HEREBY_RELEASE_OUT (default mac/.build/release-out/<tag>),
# then uploads both to the HEREBY_RELEASE_REPO release of the tag. --no-upload stops before uploading. --public also
# uploads them to HEREBY_UPDATE_REPO's release of the same tag and marks it latest, which is when installed apps see it;
# that tag must already exist there, on the scanned public snapshot of this commit.
set -euo pipefail
umask 022
upload=1
public=0
for argument in "$@"; do
    case "$argument" in
        --no-upload) upload=0 ;;
        --public) public=1 ;;
        *) printf 'usage: release.sh [--no-upload] [--public]\n' >&2; exit 2 ;;
    esac
done
[[ $upload == 0 && $public == 1 ]] && { printf -- '--public needs the upload; drop --no-upload.\n' >&2; exit 2; }
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id=sh.hereby.recorder

if ! version="$(git -C "$package_dir" describe --tags --exact-match HEAD 2>/dev/null)" || [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'A release needs HEAD on a release tag like v2.14.0.\n' >&2
    exit 1
fi
if [[ -n "$(git -C "$package_dir" status --porcelain --untracked-files=no)" ]]; then
    printf 'Not releasing: the clone has uncommitted changes, so the build would not match %s.\n' "$version" >&2
    exit 1
fi
missing=()
for name in HEREBY_SIGN_IDENTITY HEREBY_TEAM_ID HEREBY_UPDATE_KEY HEREBY_UPDATE_REPO; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
done
if [[ -z "${HEREBY_NOTARY_PROFILE:-}" ]]; then
    for name in HEREBY_NOTARY_KEY HEREBY_NOTARY_KEY_ID HEREBY_NOTARY_ISSUER; do
        [[ -n "${!name:-}" ]] || missing+=("$name (or HEREBY_NOTARY_PROFILE)")
    done
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'Not releasing: missing %s. Run it under `infisical run --`; see mac/RELEASING.md.\n' "${missing[*]}" >&2
    exit 1
fi
if [[ ! "$HEREBY_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then printf 'HEREBY_TEAM_ID is not a team id.\n' >&2; exit 1; fi
if [[ "$HEREBY_SIGN_IDENTITY" != "Developer ID Application: "*"($HEREBY_TEAM_ID)" ]]; then
    printf 'HEREBY_SIGN_IDENTITY must be a Developer ID Application certificate of team %s.\n' "$HEREBY_TEAM_ID" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -qF "\"$HEREBY_SIGN_IDENTITY\""; then
    printf 'No valid "%s" in the keychain. See mac/RELEASING.md.\n' "$HEREBY_SIGN_IDENTITY" >&2
    exit 1
fi
if [[ ! "$HEREBY_UPDATE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then printf 'HEREBY_UPDATE_REPO is not owner/name.\n' >&2; exit 1; fi

out="${HEREBY_RELEASE_OUT:-$package_dir/.build/release-out/$version}"
rm -rf "$out"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/LiveMeetingListener.app"
zip="$out/LiveMeetingListener-$version.zip"
feed_url="https://github.com/$HEREBY_UPDATE_REPO/releases/latest/download/appcast.json"
download_url="https://github.com/$HEREBY_UPDATE_REPO/releases/download/$version/LiveMeetingListener-$version.zip"

"$package_dir/scripts/assemble-app.sh" "$app" "$version"
binary_dir="$(swift build --package-path "$package_dir" -c release --show-bin-path)"
release_tool="$binary_dir/lml-release"

# A downloaded app has no clone, so it carries what install.sh and the updater need.
mkdir -p "$app/Contents/Helpers" "$app/Contents/Resources/scripts" "$app/Contents/Resources/LaunchAgent"
cp "$binary_dir/lml-mic" "$app/Contents/Helpers/lml-mic"
cp "$package_dir/scripts/install.sh" "$package_dir/scripts/install-app.sh" "$app/Contents/Resources/scripts/"
cp "$package_dir"/LaunchAgent/*.plist "$app/Contents/Resources/LaunchAgent/"
chmod -R u+rwX,go+rX "$app"
info="$app/Contents/Info.plist"
plutil -replace HerebyUpdateFeed -string "$feed_url" "$info"
plutil -replace HerebyUpdatePublicKey -string "$("$release_tool" public-key)" "$info"
plutil -replace HerebyTeamID -string "$HEREBY_TEAM_ID" "$info"

# Inside out: the helper first, then the bundle, which seals it. One identity and one bundle id for every release keep
# the microphone and screen grants across updates.
sign() { codesign --force --timestamp --options runtime --sign "$HEREBY_SIGN_IDENTITY" "$@"; }
sign --identifier "$bundle_id.mic" "$app/Contents/Helpers/lml-mic"
sign --identifier "$bundle_id" --entitlements "$package_dir/LiveMeetingListener.entitlements" "$app"
requirement="anchor apple generic and identifier \"$bundle_id\" and certificate leaf[subject.OU] = \"$HEREBY_TEAM_ID\""
codesign --verify --deep --strict -R "=$requirement" "$app"

ditto -c -k --keepParent "$app" "$work/notarize.zip"
notary=()
if [[ -n "${HEREBY_NOTARY_PROFILE:-}" ]]; then
    notary=(--keychain-profile "$HEREBY_NOTARY_PROFILE")
else
    # %b: secret stores that keep one-line values hold the .p8's line breaks as literal \n.
    (umask 077; printf '%b\n' "$HEREBY_NOTARY_KEY" > "$work/notary.p8")
    notary=(--key "$work/notary.p8" --key-id "$HEREBY_NOTARY_KEY_ID" --issuer "$HEREBY_NOTARY_ISSUER")
fi
printf 'Notarizing %s; Apple usually answers in a few minutes.\n' "$version"
xcrun notarytool submit "$work/notarize.zip" "${notary[@]}" --wait --output-format json > "$work/notary.json" || true
status="$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
    submission="$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)"
    printf 'Notarization ended as "%s".\n' "${status:-unknown}" >&2
    [[ -n "$submission" ]] && xcrun notarytool log "$submission" "${notary[@]}" >&2 || true
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute "$app"

ditto -c -k --keepParent "$app" "$zip"
"$release_tool" feed --version "$version" --url "$download_url" --archive "$zip" \
    --minimum-system "$(plutil -extract LSMinimumSystemVersion raw -o - "$info")" > "$out/appcast.json"
"$release_tool" verify --feed "$out/appcast.json" --archive "$zip" --public-key "$(plutil -extract HerebyUpdatePublicKey raw -o - "$info")"
printf 'Built %s and %s\n' "$zip" "$out/appcast.json"
[[ $upload == 1 ]] || exit 0

notes="Signed and notarized build of $version. Download LiveMeetingListener-$version.zip, unzip it, and move the app to ~/Applications."
publish() {
    local repo="$1"; shift
    if gh release view "$version" --repo "$repo" >/dev/null 2>&1; then
        gh release upload "$version" "$zip" "$out/appcast.json" --repo "$repo" --clobber
    else
        gh release create "$version" "$zip" "$out/appcast.json" --repo "$repo" --verify-tag --title "$version" --notes "$notes" "$@"
    fi
}
release_repo="${HEREBY_RELEASE_REPO:-$(cd "$package_dir" && gh repo view --json nameWithOwner --jq .nameWithOwner)}"
publish "$release_repo"
printf 'Uploaded to the %s release of %s\n' "$version" "$release_repo"
if [[ $public == 1 ]]; then
    publish "$HEREBY_UPDATE_REPO" --latest
    gh release edit "$version" --repo "$HEREBY_UPDATE_REPO" --latest >/dev/null
    printf 'Published to %s; installed apps offer %s within a day.\n' "$HEREBY_UPDATE_REPO" "$version"
fi
