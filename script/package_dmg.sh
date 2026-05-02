#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/SD Import.app"
AGENT_BUNDLE="$APP_BUNDLE/Contents/Library/LoginItems/SDImportAgent.app"
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
DMG_PATH="$DIST_DIR/SD-Import.dmg"
ZIP_PATH="$DIST_DIR/SD-Import.zip"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
ADHOC_APP_ENTITLEMENTS=""

cleanup() {
  if [[ -n "$ADHOC_APP_ENTITLEMENTS" ]]; then
    rm -f "$ADHOC_APP_ENTITLEMENTS"
  fi
}
trap cleanup EXIT

if [[ -z "${SPARKLE_FEED_URL:-}" || -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  echo "SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY are not both set; in-app updates will be disabled for this artifact." >&2
  if [[ "${REQUIRE_SPARKLE_CONFIGURATION:-0}" == "1" ]]; then
    exit 2
  fi
fi

SKIP_STAGE_ADHOC_SIGN=1 BUILD_CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" build

sign_code() {
  local target="$1"
  shift

  if [[ -n "$SIGN_IDENTITY" ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@" "$target"
  else
    /usr/bin/codesign --force --options runtime --sign - "$@" "$target"
  fi
}

sign_app_bundle() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    sign_code "$APP_BUNDLE"
    return
  fi

  ADHOC_APP_ENTITLEMENTS="$(mktemp)"
  cat >"$ADHOC_APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
PLIST

  /usr/bin/codesign --force --options runtime --sign - --entitlements "$ADHOC_APP_ENTITLEMENTS" "$APP_BUNDLE"
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with Developer ID identity: $SIGN_IDENTITY"
else
  echo "DEVELOPER_ID_APPLICATION is not set; using ad-hoc signing for local validation."
fi

if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  sign_code "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
  sign_code "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
  sign_code "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
  sign_code "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
  sign_code "$SPARKLE_FRAMEWORK"
fi

sign_code "$AGENT_BUNDLE"
sign_app_bundle

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
