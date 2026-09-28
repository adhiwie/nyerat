#!/bin/bash
#
# Build Nyerat as a signed Release archive and export it for App Store Connect.
#
# This produces a .pkg under build/appstore-export/ but does NOT upload it —
# open the resulting archive in Xcode Organizer (Window > Organizer) and use
# "Distribute App" > App Store Connect, or upload the .pkg with Transporter.
#
set -euo pipefail

SCHEME="Nyerat"
APP_NAME="Nyerat"
PROJECT="Nyerat.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/appstore-export"

cd "$(dirname "$0")/.."

echo "==> Archiving ($SCHEME, Release)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  CODE_SIGN_STYLE=Automatic

echo "==> Exporting for App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates

echo
echo "Done: $ARCHIVE_PATH"
echo "Exported package: $EXPORT_DIR/$APP_NAME.pkg"
echo
echo "To submit: open $ARCHIVE_PATH in Xcode Organizer and choose"
echo "Distribute App > App Store Connect > Upload, or upload the .pkg with Transporter."
