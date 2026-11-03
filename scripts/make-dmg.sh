#!/bin/bash
# Packs build/Stop Stutter.app into a drag-to-Applications disk image.
# Run scripts/build.sh first (with the same SIGNING_IDENTITY).
set -euo pipefail
cd "$(dirname "$0")/.."

app="$PWD/build/Stop Stutter.app"
[[ -d "$app" ]] || { printf 'Run scripts/build.sh first.\n' >&2; exit 1; }
identity="${SIGNING_IDENTITY:--}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$PWD/dist/StopStutter-$version-macOS12.dmg"

mkdir -p dist
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Stop Stutter.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "Stop Stutter" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"

# Only a Developer ID identity can sign and notarize a disk image.
if [[ "$identity" == "Developer ID"* ]]; then
    codesign --force --sign "$identity" --timestamp "$dmg"
    if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
        xcrun notarytool submit "$dmg" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
        xcrun stapler staple "$dmg"
    fi
fi

(cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
printf '\nDisk image: %s\n' "$dmg"
