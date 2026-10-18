#!/bin/bash
# Builds Tendedero.app into ./build without needing Xcode.
# Usage: scripts/build-app.sh [debug|release] [--native]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Tendedero.app"
VERSION="1.6.0"
case "$CONFIG" in debug|release) ;; *) echo "Expected debug or release" >&2; exit 1 ;; esac
case "${2:-}" in ""|--native) ;; *) echo "Expected --native" >&2; exit 1 ;; esac

# Builds one architecture and prints the binary's path.
# The Command Line Tools for macOS 27 ship an SDK whose SwiftUI needs a macro
# plugin they do not include. If the default SDK fails, fall back to the
# newest macOS 26 SDK installed alongside it.
build_arch() {
  local triple="$1-apple-macosx14.0"
  if [ -z "${SDKROOT:-}" ] && ! swift build --build-system native -c "$CONFIG" --triple "$triple" >&2; then
    FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    if [ -z "$FALLBACK" ]; then exit 1; fi
    echo "Retrying with $FALLBACK" >&2
    export SDKROOT="$FALLBACK"
  fi
  if [ -n "${SDKROOT:-}" ]; then swift build --build-system native -c "$CONFIG" --triple "$triple" >&2; fi
  local binary="$(swift build --build-system native -c "$CONFIG" --triple "$triple" --show-bin-path)/Tendedero"
  if ! file -b "$binary" | grep -q 'Mach-O' ||
     ! lipo -verify_arch "$1" "$binary" ||
     ! otool -arch "$1" -hv "$binary" | grep -q 'EXECUTE'; then
    echo "The $1 build did not produce a macOS executable: $binary" >&2
    exit 1
  fi
  cp "$binary" "$OUT/Tendedero-$1"
}

# A universal binary, so it runs on Apple silicon and on Intel Macs, from
# macOS 14 Sonoma onwards.
OUT="$(mktemp -d)"
WORK=""
trap 'rm -rf "$OUT"; if [ -n "$WORK" ]; then rm -rf "$WORK"; fi' EXIT
if [ "${2:-}" = --native ]; then
  # Detect the actual hardware even when Terminal is running under Rosetta.
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then ARCH=arm64; else ARCH="$(uname -m)"; fi
  case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported Mac architecture: $ARCH" >&2; exit 1 ;; esac
  build_arch "$ARCH"
  cp "$OUT/Tendedero-$ARCH" "$OUT/Tendedero"
else
  build_arch arm64
  build_arch x86_64
  lipo -create "$OUT/Tendedero-arm64" "$OUT/Tendedero-x86_64" -output "$OUT/Tendedero"
fi
BIN="$OUT/Tendedero"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tendedero"
chmod 755 "$APP/Contents/MacOS/Tendedero"

# Icon
WORK="$(mktemp -d)"
swift scripts/make-icon.swift "$WORK/icon.png"
ICONSET="$WORK/Tendedero.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Tendedero.icns"
rm -rf "$WORK"

# Translations: one folder per language, listed in Info.plist so macOS knows
# which languages the app speaks.
LANGUAGES=""
for dir in Sources/Tendedero/Resources/*.lproj; do
  cp -R "$dir" "$APP/Contents/Resources/"
  LANGUAGES="$LANGUAGES<string>$(basename "$dir" .lproj)</string>"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tendedero</string>
  <key>CFBundleDisplayName</key><string>Tendedero</string>
  <key>CFBundleIdentifier</key><string>app.tendedero.Tendedero</string>
  <key>CFBundleExecutable</key><string>Tendedero</string>
  <key>CFBundleIconFile</key><string>Tendedero</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>7</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LANGUAGES}</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Tendedero watches the folder where macOS saves your screenshots so it can hang them on the line.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Tendedero watches the folder you chose so it can hang new images on the line.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Tendedero watches the folder you chose so it can hang new images on the line.</string>
</dict>
</plist>
PLIST

# SIGN_IDENTITY=- (or an explicitly empty value) requests ad hoc signing for
# local testing. Automatic Developer ID selection uses the certificate hash,
# because more than one certificate can have the same display name.
if [ "${SIGN_IDENTITY+x}" = x ]; then
  IDENTITY="$SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/{print $2; exit}' || true)"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "Signed with $IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "Signed ad hoc for local use"
fi
echo "Built $APP"
