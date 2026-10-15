#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/ImageLine.app"
test -d "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DESTINATION="${1:-build}"
mkdir -p "$DESTINATION"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DESTINATION/ImageLine-$VERSION.zip"
echo "Packaged $DESTINATION/ImageLine-$VERSION.zip"
