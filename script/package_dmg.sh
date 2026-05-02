#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/SD Import.app"
AGENT_BUNDLE="$APP_BUNDLE/Contents/Library/LoginItems/SDImportAgent.app"
DMG_PATH="$DIST_DIR/SD-Import.dmg"
ZIP_PATH="$DIST_DIR/SD-Import.zip"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"

BUILD_CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" build

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with Developer ID identity: $SIGN_IDENTITY"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$AGENT_BUNDLE"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  echo "DEVELOPER_ID_APPLICATION is not set; using ad-hoc signing for local validation."
  /usr/bin/codesign --force --options runtime --sign - "$AGENT_BUNDLE"
  /usr/bin/codesign --force --options runtime --sign - "$APP_BUNDLE"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

rm -f "$DMG_PATH" "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
/usr/bin/hdiutil create -volname "SD Import" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_PATH" >/dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing DMG with Developer ID identity: $SIGN_IDENTITY"
  /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  /usr/bin/codesign --verify --verbose=2 "$DMG_PATH"
fi

echo "Created:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
