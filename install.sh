#!/usr/bin/env bash
set -euo pipefail

LABEL="com.xcv58.sd-import"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.sd-import"
LOCAL_BIN="$HOME/.local/bin"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PLIST="$LAUNCH_AGENT_DIR/$LABEL.plist"
CONFIG_PATH="$STATE_DIR/config.json"

PHOTOS_BASE="$HOME/Pictures/Photos"
VIDEOS_BASE="$HOME/Downloads"
INSTALL_RAYCAST=0
SKIP_LAUNCHD=0

log() {
  printf '[sd-import-install] %s\n' "$*"
}

fail() {
  printf '[sd-import-install] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: install.sh [options]

Options:
  --photos-base <path>      Photos destination base (default: $HOME/Pictures/Photos)
  --videos-base <path>      Videos destination base (default: $HOME/Downloads)
  --with-raycast            Open Raycast import deeplink for local extension
  --skip-launchd            Do not install/enable launchd agent
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --photos-base)
      shift
      [[ $# -gt 0 ]] || fail "--photos-base requires a value"
      PHOTOS_BASE="$1"
      ;;
    --videos-base)
      shift
      [[ $# -gt 0 ]] || fail "--videos-base requires a value"
      VIDEOS_BASE="$1"
      ;;
    --with-raycast)
      INSTALL_RAYCAST=1
      ;;
    --skip-launchd)
      SKIP_LAUNCHD=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || fail "This installer supports macOS only"
[[ -x /usr/bin/python3 ]] || fail "python3 is required at /usr/bin/python3"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v unzip >/dev/null 2>&1 || fail "unzip is required"
command -v launchctl >/dev/null 2>&1 || fail "launchctl is required"

mkdir -p "$STATE_DIR" "$LOCAL_BIN" "$LAUNCH_AGENT_DIR"

install_alerter() {
  if command -v alerter >/dev/null 2>&1; then
    log "alerter found in PATH"
    return
  fi
  if [[ -x "$LOCAL_BIN/alerter" ]]; then
    log "alerter already installed at $LOCAL_BIN/alerter"
    return
  fi

  log "Installing alerter to $LOCAL_BIN/alerter"
  local tmpdir
  tmpdir="$(mktemp -d)"

  local release_json zip_url
  release_json="$(curl -fsSL https://api.github.com/repos/vjeantet/alerter/releases/latest)"
  zip_url="$(
    /usr/bin/python3 - <<'PY'
import json, sys
obj = json.loads(sys.stdin.read())
for asset in obj.get("assets", []):
    url = asset.get("browser_download_url", "")
    if url.endswith(".zip"):
        print(url)
        break
PY
  <<<"$release_json")"

  if [[ -z "$zip_url" ]]; then
    rm -rf "$tmpdir"
    fail "Could not find alerter zip asset in latest release"
  fi

  curl -fsSL "$zip_url" -o "$tmpdir/alerter.zip"
  unzip -q "$tmpdir/alerter.zip" -d "$tmpdir/unzip"

  local bin_path
  bin_path="$(find "$tmpdir/unzip" -type f -name alerter | head -n 1)"
  if [[ -z "$bin_path" ]]; then
    rm -rf "$tmpdir"
    fail "alerter binary not found in downloaded archive"
  fi

  install -m 755 "$bin_path" "$LOCAL_BIN/alerter"
  rm -rf "$tmpdir"
  log "alerter installed"
}

install_launcher() {
  ln -sfn "$ROOT_DIR/sd-import" "$LOCAL_BIN/sd-import"
  log "symlinked $LOCAL_BIN/sd-import -> $ROOT_DIR/sd-import"
}

write_default_config_if_missing() {
  if [[ -f "$CONFIG_PATH" ]]; then
    log "keeping existing config at $CONFIG_PATH"
    return
  fi
  cat > "$CONFIG_PATH" <<'JSON'
{
  "default_location": "TODO",
  "location_by_volume": {},
  "ignore_volume_regex": "Time Machine|Backup"
}
JSON
  log "created default config at $CONFIG_PATH"
}

write_launch_agent_plist() {
  cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$ROOT_DIR/sd_import.py</string>
    <string>auto</string>
    <string>--notify</string>
    <string>--photos-base</string>
    <string>$PHOTOS_BASE</string>
    <string>--videos-base</string>
    <string>$VIDEOS_BASE</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$LOCAL_BIN</string>
  </dict>

  <key>StartOnMount</key>
  <true/>

  <key>RunAtLoad</key>
  <false/>

  <key>StandardOutPath</key>
  <string>$STATE_DIR/launchd.out.log</string>

  <key>StandardErrorPath</key>
  <string>$STATE_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST

  plutil -lint "$LAUNCH_PLIST" >/dev/null
  log "wrote launch agent plist to $LAUNCH_PLIST"
}

install_launch_agent() {
  write_launch_agent_plist
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PLIST"
  launchctl enable "gui/$(id -u)/$LABEL"
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  log "launch agent installed and enabled"
}

maybe_open_raycast_import() {
  if [[ "$INSTALL_RAYCAST" -ne 1 ]]; then
    return 0
  fi

  local extension_dir
  extension_dir="$ROOT_DIR/raycast-extension"
  if [[ ! -d "$extension_dir" ]]; then
    log "raycast extension folder not found: $extension_dir"
    return
  fi

  local encoded
  encoded="$(
    EXT_PATH="$extension_dir" /usr/bin/python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ["EXT_PATH"]))
PY
  )"

  if command -v open >/dev/null 2>&1; then
    open "raycast://extensions/raycast/raycast/import-extension?fallbackText=$encoded" || true
    log "Opened Raycast import deeplink"
  fi
}

install_alerter
install_launcher
write_default_config_if_missing

if [[ "$SKIP_LAUNCHD" -eq 0 ]]; then
  install_launch_agent
else
  log "Skipping launchd installation (--skip-launchd)"
fi

maybe_open_raycast_import

log "Install complete"
log "Use command: $LOCAL_BIN/sd-import"
log "If needed, add to PATH: export PATH=\"$LOCAL_BIN:\$PATH\""
