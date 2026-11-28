#!/bin/bash
# Builds the release binaries and assembles an unsigned app bundle at APP. Usage: assemble-app.sh APP VERSION
# build-app.sh (source builds, local signing) and release.sh (Developer ID signing) both start from this bundle.
set -euo pipefail
umask 077
if [[ $# -ne 2 ]]; then printf 'usage: assemble-app.sh APP VERSION\n' >&2; exit 2; fi
app="$1"
version="$2"
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$package_dir" -c release
binary_dir="$(swift build --package-path "$package_dir" -c release --show-bin-path)"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/lml" "$app/Contents/MacOS/lml"
cp "$package_dir/Info.plist" "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp "$package_dir/../handoff/hereby-handoff.sh" "$app/Contents/Resources/hereby-handoff.sh"
# Ask and the live buttons run these on the Mac when there is no ssh_host.
mkdir -p "$app/Contents/Resources/mini"
cp -p "$package_dir"/../mini/*.py "$package_dir/../mini/live-meeting-ask" "$package_dir/../mini/live-meeting-quick" "$app/Contents/Resources/mini/"
cp "$package_dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"   # drawn by scripts/make-icon.swift
cp -R "$package_dir/en.lproj" "$app/Contents/Resources/en.lproj"   # the name Finder and System Settings show
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
