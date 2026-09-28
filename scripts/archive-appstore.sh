#!/bin/bash
#
# Build Nyerat as a signed Release archive and upload it to App Store Connect.
#
# This UPLOADS the build: scripts/ExportOptions-AppStore.plist sets
# "destination" to "upload", so the export step sends the package to App Store
# Connect rather than leaving it on disk. Authentication comes from the Apple
# account signed in to Xcode.
#
# A build number that is already on App Store Connect will be refused, so bump
# CURRENT_PROJECT_VERSION before every run.
#
# To get a package on disk instead, set "destination" to "export" in that plist;
# the .pkg then lands in build/appstore-export/ for Transporter or Organizer.
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
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic

echo "==> Uploading to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates

echo
echo "Done. Archive: $ARCHIVE_PATH"
echo
echo "The build has been uploaded to App Store Connect and is processing."
echo "Once processing finishes, attach it to a version there and submit for review."
