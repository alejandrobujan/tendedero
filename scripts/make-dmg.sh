#!/bin/bash
# Builds Tendedero.app and packs it into a disk image for releases.
# Usage: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Tendedero.app/Contents/Info.plist)"
DMG="build/Tendedero-$VERSION.dmg"
NAME="Tendedero"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R build/Tendedero.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-dmg-background.swift "$WORK/bg1x.png" 1
swift scripts/make-dmg-background.swift "$WORK/bg2x.png" 2
# One TIFF holding both resolutions, so the window is sharp on Retina.
tiffutil -cathidpicheck "$WORK/bg1x.png" "$WORK/bg2x.png" -out "$STAGE/.background/background.tiff" >/dev/null

RW="$WORK/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -size 60m "$RW"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"

# Tiling window managers resize the window, and Finder would save that size
# into the image. Pause AeroSpace while laying it out, if it is running.
if command -v aerospace >/dev/null && pgrep -qx AeroSpace; then
  aerospace enable off
  trap 'aerospace enable on' EXIT
fi

# Lay out the window. Needs permission to control Finder; without it the
# image still works, just with Finder's default layout.
osascript <<OSA || echo "Finder layout skipped"
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 528}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Tendedero.app" of container window to {160, 178}
    set position of item "Applications" of container window to {440, 178}
    -- Size last: Finder can resize the window while it applies the options.
    set the bounds of container window to {200, 120, 800, 528}
    update without registering applications
    delay 1
    set the bounds of container window to {200, 120, 800, 528}
    delay 1
    close
  end tell
end tell
OSA

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach -quiet "$MOUNT"
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$WORK"
echo "Built $DMG"

# Sign the disk image, send it to Apple for notarization and staple the
# ticket, so it opens without warnings even offline. Needs a Developer ID and
# notary credentials stored with:
#   xcrun notarytool store-credentials tendedero-notary --apple-id ... --team-id ...
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
PROFILE="${NOTARY_PROFILE:-tendedero-notary}"
if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Notarizing, this usually takes a few minutes..."
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  else
    echo "No notary credentials in profile $PROFILE: the image is signed but not notarized."
  fi
fi

# Keep the Homebrew cask in step: new version and the checksum of this image.
# Set TAP_DIR to the tap checkout; nothing is committed or pushed here, so the
# cask never points at a release that is not on GitHub yet.
TAP_DIR="${TAP_DIR:-$HOME/homebrew-tap}"
CASK="$TAP_DIR/Casks/tendedero.rb"
if [ -f "$CASK" ]; then
  SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  echo "Updated $CASK to $VERSION ($SHA)"
  echo "After publishing the release: commit and push the tap."
else
  echo "No Homebrew cask at $CASK, skipped."
fi
