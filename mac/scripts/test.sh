#!/bin/bash
set -euo pipefail
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$package_dir/.tmp"
export TMPDIR="$package_dir/.tmp"
export CLANG_MODULE_CACHE_PATH="$package_dir/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$package_dir/.cache/swift"
# CI points SWIFTPM_CACHE_DIR outside its wiped checkout, so a dependency is downloaded once, not every run.
arguments=(--disable-sandbox --disable-xctest --package-path "$package_dir" --cache-path "${SWIFTPM_CACHE_DIR:-$package_dir/.cache}" --config-path "$package_dir/.config" --security-path "$package_dir/.security")
frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == /Library/Developer/CommandLineTools && -d "$frameworks/Testing.framework" ]]; then
    arguments+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks/../usr/lib")
fi
# A CI runner's login keychain is locked, and SwiftPM's credential lookup for public downloads fails on it.
[[ -n "${CI:-}" ]] && arguments+=(--disable-keychain)
swift test "${arguments[@]}" "$@"
