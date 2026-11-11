#!/bin/bash
# Native checks without XCTest or the system clipboard. Watchers use only
# generated files in private test folders.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tendedero-selection.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
CHECK_APP="$CHECK_DIR/SelectionChecks.app"
mkdir -p "$CHECK_APP/Contents/MacOS" "$CHECK_APP/Contents/Resources" "$CHECK_DIR/files"
cp -R Sources/Tendedero/Resources/en.lproj "$CHECK_APP/Contents/Resources/"
cat > "$CHECK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.tendedero.selection-checks</string>
<key>CFBundleExecutable</key><string>SelectionChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
SOURCES=()
for name in Line LineView LinePanel PeggedView GrabArea Share Markup Trim QuickLook Localization ScreenshotWatcher SearchIndex NoteSheet Held Markdown; do
    SOURCES+=("Sources/Tendedero/$name.swift")
done
swiftc -module-name Tendedero -target "$(uname -m)-apple-macosx14.0" -parse-as-library "${SOURCES[@]}" scripts/test-selection.swift \
    -o "$CHECK_APP/Contents/MacOS/SelectionChecks"
"$CHECK_APP/Contents/MacOS/SelectionChecks" "$CHECK_DIR/files"
