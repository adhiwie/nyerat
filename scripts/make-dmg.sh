#!/bin/bash
#
# Build Nyerat as a signed Release .app and package it into a distributable DMG.
#
# Requirements:
#   brew install create-dmg
#   A "Developer ID Application" certificate in your login keychain
#
# Optional notarization (recommended for public downloads) needs a stored
# credential profile. Create it once with:
#
#   xcrun notarytool store-credentials nyerat-notary \
#       --apple-id "you@example.com" \
#       --team-id 9Q7MFGM9Y2 \
#       --password "app-specific-password"
#
# Then run:  NOTARY_PROFILE=nyerat-notary ./scripts/make-dmg.sh
#
set -euo pipefail

SCHEME="Nyerat"
APP_NAME="Nyerat"
PROJECT="Nyerat.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_DIR="$BUILD_DIR/dmg"

cd "$(dirname "$0")/.."

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')
VERSION=${VERSION:-dev}
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Cleaning"
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_DIR"

echo "==> Archiving ($SCHEME, Release)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Automatic

echo "==> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist

cp -R "$EXPORT_DIR/$APP_NAME.app" "$DMG_DIR/"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing the .app"
  ditto -c -k --keepParent "$DMG_DIR/$APP_NAME.app" "$BUILD_DIR/$APP_NAME.zip"
  xcrun notarytool submit "$BUILD_DIR/$APP_NAME.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_DIR/$APP_NAME.app"
fi

echo "==> Building DMG"
create-dmg \
  --volname "$APP_NAME $VERSION" \
  --window-pos 200 120 \
  --window-size 640 400 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 160 190 \
  --app-drop-link 480 190 \
  --hide-extension "$APP_NAME.app" \
  --no-internet-enable \
  "$DMG_PATH" \
  "$DMG_DIR"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing + stapling the DMG"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo
echo "Done: $DMG_PATH"
