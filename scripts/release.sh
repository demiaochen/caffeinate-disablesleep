#!/bin/bash
# Release pipeline: build → notarize+staple the app → styled DMG → notarize+staple
# the DMG → verify. Credentials: Developer ID cert in the login keychain and the
# a notarytool keychain profile (override identity/profile via CODESIGN_IDENTITY / NOTARY_PROFILE).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/build"
DIST="$REPO/dist"
APP="$BUILD/caffeinate & disablesleep.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO/Config/Info.plist")"
NOTARY_PROFILE="${NOTARY_PROFILE:-clipory-notary}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

"$REPO/scripts/build.sh"

echo "▸ Notarize + staple the app"
ditto -c -k --keepParent "$APP" "$BUILD/dscaf.zip"
xcrun notarytool submit "$BUILD/dscaf.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"

echo "▸ DMG background"
BG_DIR="$BUILD/dmg-bg"
mkdir -p "$BG_DIR"
"$CHROME" --headless --disable-gpu --screenshot="$BG_DIR/bg.png" \
  --window-size=640,400 --hide-scrollbars \
  "file://$REPO/Branding/dmg-background.svg" 2>/dev/null
"$CHROME" --headless --disable-gpu --screenshot="$BG_DIR/bg@2x.png" \
  --window-size=640,400 --force-device-scale-factor=2 --hide-scrollbars \
  "file://$REPO/Branding/dmg-background.svg" 2>/dev/null
tiffutil -cathidpicheck "$BG_DIR/bg.png" "$BG_DIR/bg@2x.png" -out "$BG_DIR/dmg-background.tiff"

echo "▸ Build the DMG"
mkdir -p "$DIST"
DMG="$DIST/caffeinate-disablesleep-$VERSION.dmg"
rm -f "$DMG"
VOL="caffeinate & disablesleep"
STAGE="$BUILD/dmg-stage"; RW="$BUILD/dmg-rw.dmg"
rm -rf "$STAGE" "$RW"; mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$BG_DIR/dmg-background.tiff" "$STAGE/.background/"

for d in $(hdiutil info | awk -v v="/Volumes/$VOL" '$0 ~ v {print $1}'); do
  hdiutil detach "$d" -force >/dev/null 2>&1 || true
done

dmg_mb=$(( $(du -sk "$STAGE" | cut -f1) / 1024 + 20 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size "${dmg_mb}m" -ov "$RW" -quiet
dmg_dev=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | egrep '^/dev/' | head -1 | awk '{print $1}')
sleep 1

if ! osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    delay 0.5
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 112
    set text size of vo to 13
    set background picture of vo to file ".background:dmg-background.tiff"
    set position of item "caffeinate & disablesleep.app" of container window to {170, 185}
    set position of item "Applications" of container window to {470, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "⚠ Finder layout failed (Automation permission?) — shipping unstyled DMG"
fi

sync
hdiutil detach "$dmg_dev" -quiet || hdiutil detach "$dmg_dev" -force -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$RW"

echo "▸ Notarize + staple the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "✓ $DMG"
