#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="Relay"
VERSION="0.2.0"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_STAGE="$ROOT_DIR/build/dmg"
DMG_PATH="$DIST_DIR/$APP_NAME-v$VERSION.dmg"
ZIP_PATH="$DIST_DIR/$APP_NAME-v$VERSION.zip"

if [[ "${1:-}" != "--skip-build" ]]; then
    "$ROOT_DIR/scripts/build.sh"
fi

rm -rf "$DMG_STAGE" "$DMG_PATH" "$ZIP_PATH"
mkdir -p "$DMG_STAGE"
cp -R "$APP_DIR" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

shasum -a 256 "$DMG_PATH" "$ZIP_PATH" > "$DIST_DIR/SHA256SUMS.txt"

echo "Packaged:"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
echo "  $DIST_DIR/SHA256SUMS.txt"
