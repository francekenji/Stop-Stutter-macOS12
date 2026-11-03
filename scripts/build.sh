#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
identity="${SIGNING_IDENTITY:--}"
app="$PWD/build/Stop Stutter.app"
# macOS 12 backport: deployment target 12.0 (set in Package.swift). Needs Xcode 14.2 or newer.
# SwiftPM's Swift Build engine can otherwise stamp the minimum OS as the linked SDK.
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
build_args=(-c "$configuration")
# Swift Build in Xcode 27 passes these directly to ld. Xcode 26's universal
# frontend passes them to clang instead, and already stamps the correct SDK.
if [[ "${sdk_version%%.*}" -ge 27 ]]; then
    build_args+=(-Xlinker -platform_version -Xlinker macos -Xlinker 12.0 -Xlinker "$sdk_version")
fi
if [[ "${UNIVERSAL:-0}" == 1 ]]; then build_args+=(--arch arm64 --arch x86_64); fi

swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
# Start from an empty bundle so files from an earlier build, such as a stapled ticket, never carry over.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/StopStutter" "$app/Contents/MacOS/StopStutter"
cp "$bin_dir/StopStutterHelper" "$app/Contents/MacOS/StopStutterHelper"
cp Resources/Info.plist "$app/Contents/Info.plist"
# macOS 12 has no SMAppService: the app installs this launchd plist and the helper itself, with one admin prompt.
cp Resources/io.github.burakgon.StopStutter.Helper.plist "$app/Contents/Resources/"
ditto Resources/ClientIcons "$app/Contents/Resources/ClientIcons"
swift scripts/make-icon.swift "$app/Contents/Resources"

sign_options=(--force --sign "$identity" --options runtime)
# Apple's timestamp service is for Developer ID builds; a local or Apple Development identity signs without it.
case "$identity" in
    -) ;;
    "Developer ID"*) sign_options+=(--timestamp) ;;
    *) sign_options+=(--timestamp=none) ;;
esac
codesign "${sign_options[@]}" --identifier io.github.burakgon.StopStutter.Helper "$app/Contents/MacOS/StopStutterHelper"
codesign "${sign_options[@]}" --identifier io.github.burakgon.StopStutter "$app"
codesign --verify --deep --strict --verbose=2 "$app"
printf '\nBuilt: %s\n' "$app"
if [[ "$identity" == "-" ]]; then
    printf 'Ad-hoc preview build: privileged helper access is intentionally unavailable.\n'
    printf 'Sign with a real or self-signed identity to use Boost: see MACOS12.md.\n'
fi
