#!/bin/bash
# Build "caffeinate & disablesleep.app" — universal binary, bundled, Developer ID signed.
# Usage: scripts/build.sh          (build + sign the app bundle)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/build"
APP="$BUILD/caffeinate & disablesleep.app"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Demiao Chen (496QXLCUW8)}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=("$REPO"/Sources/*.swift "$REPO"/Sources/Views/*.swift)
FRAMEWORKS=(-framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement)

echo "▸ Compiling (arm64 + x86_64)"
mkdir -p "$BUILD"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library \
    -sdk "$SDK" \
    -target "$arch-apple-macos14.0" \
    "${FRAMEWORKS[@]}" \
    "${SOURCES[@]}" \
    -o "$BUILD/dscaf-$arch"
done
lipo -create "$BUILD/dscaf-arm64" "$BUILD/dscaf-x86_64" -output "$BUILD/dscaf-universal"

echo "▸ Bundling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/dscaf-universal" "$APP/Contents/MacOS/caffeinate-disablesleep"
cp "$REPO/Config/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$REPO/Branding/AppIcon.icns" ]] && cp "$REPO/Branding/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
echo "✓ $APP"
