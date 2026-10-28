#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building DOT.app..."
./scripts/build-macos-app.sh

APP="build/DOT.app"
DMG_NAME="DOT"
DMG_PATH="build/DOT.dmg"
STAGING="build/dmg-staging"

echo "==> Packaging $DMG_PATH..."
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

# Copy app bundle into staging
cp -R "$APP" "$STAGING/"

# Create drag-and-drop link to Applications folder
ln -s /Applications "$STAGING/Applications"

# Create compressed read-only DMG
hdiutil create -volname "$DMG_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDBZ \
  -fs HFS+ \
  "$DMG_PATH"

rm -rf "$STAGING"

echo "==> Successfully created $DMG_PATH"
ls -lh "$DMG_PATH"
