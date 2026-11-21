#!/bin/bash
# Builds a release .app bundle and a zip for GitHub Releases.
#
# Usage: scripts/package-app.sh [version]        (default: version from About.swift)
# Output: dist/<App>.app, dist/<App>-<version>-macOS-arm64.zip, and its .sha256
#
# Signing: ad-hoc by default. Set SIGN_IDENTITY="Developer ID Application: …" to sign for
# distribution (then notarize with `xcrun notarytool`); see docs/wiki/Releasing.md.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="$(sed -n 's/.*static let name = "\(.*\)".*/\1/p' Sources/Foyer/About.swift | head -1)"
VERSION="${1:-$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Foyer/About.swift | head -1)}"
VERSION="${VERSION#v}"
BUNDLE_ID="${BUNDLE_ID:-io.github.iamsj7.foyer}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "▶ $APP_NAME $VERSION"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

DIST="dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Foyer" "$APP/Contents/MacOS/$APP_NAME"
# App icon: Resources/Foyer.icon (Icon Composer) compiles to Assets.car (Liquid Glass, macOS 26+)
# plus Foyer.icns (macOS 14–15). actool's icon export needs an absolute path to the .icon.
ICON_OUT="$(mktemp -d)"
xcrun actool "$PWD/Resources/Foyer.icon" --compile "$ICON_OUT" --platform macosx \
  --minimum-deployment-target 14.0 --app-icon Foyer \
  --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/Foyer.icns" "$APP/Contents/Resources/"
rm -rf "$ICON_OUT"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
[ -f THIRD_PARTY_NOTICES.md ] && cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>Foyer</string>
  <key>CFBundleIconName</key><string>Foyer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>Licensed under GPL-3.0-or-later</string>
</dict>
</plist>
PLIST

echo "▶ Signing ($SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

ZIP="$DIST/$APP_NAME-$VERSION-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "✅ $ZIP"
