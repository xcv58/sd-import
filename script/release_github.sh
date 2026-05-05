#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
UPDATES_DIR="$DIST_DIR/sparkle-updates"
REPO_FULL_NAME="${GITHUB_REPOSITORY:-xcv58/macos-automation}"
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD="${APP_BUILD:-1}"
RELEASE_TAG="${RELEASE_TAG:-v$APP_VERSION}"
RELEASE_TARGET="${RELEASE_TARGET:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
RELEASE_TITLE="${RELEASE_TITLE:-SD Import $APP_VERSION}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
DEFAULT_RELEASE_NOTES_FILE="$ROOT_DIR/docs/releases/sd-import-$APP_VERSION.md"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-xcv58-sd-import}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/$REPO_FULL_NAME/releases/latest/download/appcast.xml}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/$REPO_FULL_NAME/releases/download/$RELEASE_TAG/}"
SPARKLE_RELEASE_NOTES_URL_PREFIX="${SPARKLE_RELEASE_NOTES_URL_PREFIX:-https://github.com/$REPO_FULL_NAME/releases/download/$RELEASE_TAG/}"
DMG_PATH="$DIST_DIR/SD-Import.dmg"
ZIP_PATH="$DIST_DIR/SD-Import.zip"
APPCAST_PATH="$UPDATES_DIR/appcast.xml"
UPDATE_NOTES_PATH="$UPDATES_DIR/SD-Import.md"

fail() {
  echo "$1" >&2
  exit 2
}

usage() {
  cat >&2 <<EOF
usage: ./script/release_github.sh

Builds, signs, notarizes, generates a Sparkle appcast, and creates or updates a
GitHub Release.

Required environment:
  DEVELOPER_ID_APPLICATION
  SPARKLE_PUBLIC_ED_KEY
  NOTARYTOOL_PROFILE
    or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD

Common optional environment:
  APP_VERSION                 default: 1.0
  APP_BUILD                   default: 1
  RELEASE_TAG                 default: v\$APP_VERSION
  RELEASE_TARGET              default: current git HEAD
  RELEASE_TITLE               default: SD Import \$APP_VERSION
  RELEASE_NOTES_FILE
  SPARKLE_ACCOUNT             default: xcv58-sd-import
  SPARKLE_PRIVATE_KEY_FILE
  SPARKLE_PRIVATE_KEY
  GITHUB_REPOSITORY           default: xcv58/macos-automation
  GITHUB_TOKEN / GH_TOKEN     needed by gh in CI
  ALLOW_NON_INCREMENTING_APP_BUILD=1
                              emergency override for replacing an existing
                              release asset without a newer Sparkle build
EOF
}

latest_published_sparkle_build() {
  local latest_appcast_url
  latest_appcast_url="https://github.com/$REPO_FULL_NAME/releases/latest/download/appcast.xml"

  curl -fsSL "$latest_appcast_url" | /usr/bin/python3 -c '
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.fromstring(sys.stdin.buffer.read())
except ET.ParseError:
    sys.exit(0)

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
node = root.find(".//sparkle:version", ns)
if node is not None and node.text:
    print(node.text.strip())
'
}

validate_app_build() {
  if [[ ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
    fail "APP_BUILD must be a monotonically increasing integer; got '$APP_BUILD'."
  fi

  if [[ "${ALLOW_NON_INCREMENTING_APP_BUILD:-0}" == "1" ]]; then
    echo "Skipping latest-build guard because ALLOW_NON_INCREMENTING_APP_BUILD=1 is set." >&2
    return
  fi

  local latest_build
  if ! latest_build="$(latest_published_sparkle_build)"; then
    echo "Could not read the latest appcast; skipping latest-build guard." >&2
    return
  fi

  if [[ -z "$latest_build" ]]; then
    echo "Latest appcast did not contain a Sparkle build; skipping latest-build guard." >&2
    return
  fi

  if [[ ! "$latest_build" =~ ^[0-9]+$ ]]; then
    fail "Latest appcast has non-integer sparkle:version '$latest_build'; inspect the feed before releasing."
  fi

  if (( APP_BUILD <= latest_build )); then
    fail "APP_BUILD=$APP_BUILD is not newer than latest published Sparkle build $latest_build. Use APP_BUILD=$((latest_build + 1)) or higher."
  fi
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  fail "DEVELOPER_ID_APPLICATION is required for a public release."
fi

if [[ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  fail "SPARKLE_PUBLIC_ED_KEY is required for a public release."
fi

if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
  missing=()
  for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("$name")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    fail "Set NOTARYTOOL_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD."
  fi
fi

if ! command -v gh >/dev/null 2>&1; then
  fail "GitHub CLI 'gh' is required."
fi

if ! gh auth status >/dev/null 2>&1; then
  fail "GitHub CLI is not authenticated. Run: gh auth login"
fi

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" && -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  fail "Set only one of SPARKLE_PRIVATE_KEY_FILE or SPARKLE_PRIVATE_KEY."
fi

validate_app_build

if [[ -z "$RELEASE_NOTES_FILE" && -f "$DEFAULT_RELEASE_NOTES_FILE" ]]; then
  RELEASE_NOTES_FILE="$DEFAULT_RELEASE_NOTES_FILE"
fi

echo "Building release $RELEASE_TAG for $REPO_FULL_NAME"

APP_VERSION="$APP_VERSION" \
APP_BUILD="$APP_BUILD" \
SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
REQUIRE_SPARKLE_CONFIGURATION=1 \
"$ROOT_DIR/script/package_dmg.sh"

"$ROOT_DIR/script/notarize.sh" "$DMG_PATH"

rm -rf "$UPDATES_DIR"
mkdir -p "$UPDATES_DIR"
cp "$DMG_PATH" "$UPDATES_DIR/SD-Import.dmg"

if [[ -n "$RELEASE_NOTES_FILE" ]]; then
  cp "$RELEASE_NOTES_FILE" "$UPDATE_NOTES_PATH"
else
  previous_tag="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 "$RELEASE_TARGET^" 2>/dev/null || true)"
  changelog_range="$RELEASE_TARGET"
  if [[ -n "$previous_tag" ]]; then
    changelog_range="$previous_tag..$RELEASE_TARGET"
  fi
  changelog="$(git -C "$ROOT_DIR" log --max-count=20 --pretty=format:'- %s' "$changelog_range" 2>/dev/null || true)"
  if [[ -z "$changelog" ]]; then
    changelog="- Update SD Import."
  fi

  cat >"$UPDATE_NOTES_PATH" <<EOF
# SD Import $APP_VERSION

## Changes

$changelog
EOF
fi

SPARKLE_ACCOUNT="$SPARKLE_ACCOUNT" \
SPARKLE_DOWNLOAD_URL_PREFIX="$SPARKLE_DOWNLOAD_URL_PREFIX" \
SPARKLE_RELEASE_NOTES_URL_PREFIX="$SPARKLE_RELEASE_NOTES_URL_PREFIX" \
"$ROOT_DIR/script/generate_appcast.sh" "$UPDATES_DIR"

if ! grep -q 'sparkle:edSignature=' "$APPCAST_PATH"; then
  echo "Generated appcast is missing Sparkle EdDSA signatures; refusing to publish." >&2
  exit 2
fi

release_notes_for_github="$UPDATE_NOTES_PATH"
if [[ -n "$RELEASE_NOTES_FILE" ]]; then
  release_notes_for_github="$RELEASE_NOTES_FILE"
fi

if gh release view "$RELEASE_TAG" --repo "$REPO_FULL_NAME" >/dev/null 2>&1; then
  gh release upload "$RELEASE_TAG" "$DMG_PATH" "$ZIP_PATH" "$APPCAST_PATH" "$UPDATE_NOTES_PATH" \
    --repo "$REPO_FULL_NAME" \
    --clobber
  gh release edit "$RELEASE_TAG" \
    --repo "$REPO_FULL_NAME" \
    --target "$RELEASE_TARGET" \
    --title "$RELEASE_TITLE" \
    --notes-file "$release_notes_for_github" \
    --latest
else
  gh release create "$RELEASE_TAG" "$DMG_PATH" "$ZIP_PATH" "$APPCAST_PATH" "$UPDATE_NOTES_PATH" \
    --repo "$REPO_FULL_NAME" \
    --target "$RELEASE_TARGET" \
    --title "$RELEASE_TITLE" \
    --notes-file "$release_notes_for_github" \
    --latest
fi

echo "Release ready:"
echo "  https://github.com/$REPO_FULL_NAME/releases/tag/$RELEASE_TAG"
echo "Sparkle feed:"
echo "  $SPARKLE_FEED_URL"
