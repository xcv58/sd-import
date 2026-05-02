#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/SDImport/Packages/SDImportCore"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="SD Import"
PROCESS_NAME="SDImportApp"
AGENT_PROCESS_NAME="SDImportAgent"
BUNDLE_ID="com.xcv58.SDImport"
AGENT_BUNDLE_ID="com.xcv58.SDImport.Agent"
MIN_SYSTEM_VERSION="14.0"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$APP_RESOURCES/SDImport.icns"
LOGIN_ITEMS="$APP_CONTENTS/Library/LoginItems"
AGENT_BUNDLE="$LOGIN_ITEMS/$AGENT_PROCESS_NAME.app"
AGENT_CONTENTS="$AGENT_BUNDLE/Contents"
AGENT_MACOS="$AGENT_CONTENTS/MacOS"
AGENT_BINARY="$AGENT_MACOS/$AGENT_PROCESS_NAME"
AGENT_INFO_PLIST="$AGENT_CONTENTS/Info.plist"

usage() {
  cat >&2 <<'EOF'
usage: ./script/build_and_run.sh [run|build|test|--verify|--debug|--logs|--telemetry]
EOF
}

stage_app() {
  swift build --package-path "$PACKAGE_DIR" --configuration "$BUILD_CONFIGURATION" --product "$PROCESS_NAME"
  swift build --package-path "$PACKAGE_DIR" --configuration "$BUILD_CONFIGURATION" --product "$AGENT_PROCESS_NAME"
  local build_binary
  local build_dir
  build_dir="$(swift build --package-path "$PACKAGE_DIR" --configuration "$BUILD_CONFIGURATION" --show-bin-path)"
  build_binary="$build_dir/$PROCESS_NAME"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS"
  mkdir -p "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  swift "$ROOT_DIR/script/generate_icon.swift" "$APP_ICON"

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PROCESS_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>SDImport</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  mkdir -p "$AGENT_MACOS"
  cp "$build_dir/$AGENT_PROCESS_NAME" "$AGENT_BINARY"
  chmod +x "$AGENT_BINARY"

  cat >"$AGENT_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$AGENT_PROCESS_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$AGENT_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$AGENT_PROCESS_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

case "$MODE" in
  run)
    stage_app
    open_app
    ;;
  test)
    swift test --package-path "$PACKAGE_DIR"
    ;;
  build)
    stage_app
    ;;
  --verify|verify)
    swift test --package-path "$PACKAGE_DIR"
    stage_app
    open_app
    sleep 1
    pgrep -x "$PROCESS_NAME" >/dev/null
    echo "Verified $APP_BUNDLE"
    ;;
  --debug|debug)
    stage_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stage_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    stage_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
