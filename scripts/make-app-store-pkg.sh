#!/bin/bash
# Builds the sandboxed Mac App Store variant and packages it for upload.
# Needs, from developer.apple.com:
#   - an "Apple Distribution" (or "3rd Party Mac Developer Application") certificate
#   - a "3rd Party Mac Developer Installer" (Mac Installer Distribution) certificate
#   - a Mac App Store provisioning profile for app.tendedero.Tendedero, passed as PROFILE
# Usage: PROFILE=path/to/profile.provisionprofile scripts/make-app-store-pkg.sh
# Upload the resulting build/Tendedero.pkg with Transporter.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:?Set PROFILE to the Mac App Store provisioning profile}"
APP="build/Tendedero.app"
PKG="build/Tendedero.pkg"

APP_IDENTITY="${APP_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Distribution|3rd Party Mac Developer Application/{print $2; exit}')}"
PKG_IDENTITY="${PKG_IDENTITY:-$(security find-identity -v | awk -F'"' '/3rd Party Mac Developer Installer|Mac Installer Distribution/{print $2; exit}')}"
[ -n "$APP_IDENTITY" ] || { echo "No Apple Distribution certificate in the keychain" >&2; exit 1; }
[ -n "$PKG_IDENTITY" ] || { echo "No Mac Installer Distribution certificate in the keychain" >&2; exit 1; }

# The team comes from the profile, so the entitlements always match it.
PLIST="$(mktemp)"
security cms -D -i "$PROFILE" > "$PLIST"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PLIST")"
rm -f "$PLIST"
ENTITLEMENTS="$(mktemp)"
sed "s/TEAM_ID/$TEAM_ID/g" scripts/app-store/Tendedero.entitlements > "$ENTITLEMENTS"

APP_STORE=1 scripts/build-app.sh release
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# A profile downloaded with a browser carries com.apple.quarantine, and the
# App Store rejects any file in the app with it (error 91109).
xattr -cr "$APP"

codesign --force --sign "$APP_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
rm -f "$ENTITLEMENTS"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_IDENTITY" "$PKG"
echo "Built $PKG: upload it with Transporter"
