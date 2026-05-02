#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
UPDATES_DIR="$DIST_DIR/sparkle-updates"
REPO_FULL_NAME="${GITHUB_REPOSITORY:-xcv58/macos-automation}"
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD="${APP_BUILD:-1}"
RELEASE_TAG="${RELEASE_TAG:-v$APP_VERSION}"
RELEASE_TITLE="${RELEASE_TITLE:-SD Import $APP_VERSION}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-xcv58-sd-import}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/$REPO_FULL_NAME/releases/latest/download/appcast.xml}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/$REPO_FULL_NAME/releases/download/$RELEASE_TAG/}"
DMG_PATH="$DIST_DIR/SD-Import.dmg"
ZIP_PATH="$DIST_DIR/SD-Import.zip"
APPCAST_PATH="$UPDATES_DIR/appcast.xml"
UPDATE_NOTES_PATH="$UPDATES_DIR/SD-Import.md"

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
  RELEASE_TITLE               default: SD Import \$APP_VERSION
  RELEASE_NOTES_FILE
  SPARKLE_ACCOUNT             default: xcv58-sd-import
  SPARKLE_PRIVATE_KEY_FILE
  SPARKLE_PRIVATE_KEY
  GITHUB_REPOSITORY           default: xcv58/macos-automation
  GITHUB_TOKEN / GH_TOKEN     needed by gh in CI
EOF
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "DEVELOPER_ID_APPLICATION is required for a public release." >&2
  exit 2
fi

if [[ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY is required for a public release." >&2
  exit 2
fi

if [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
  missing=()
  for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("$name")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "Set NOTARYTOOL_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD." >&2
    exit 2
  fi
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI 'gh' is required." >&2
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
  exit 2
fi

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" && -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "Set only one of SPARKLE_PRIVATE_KEY_FILE or SPARKLE_PRIVATE_KEY." >&2
  exit 2
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
  cat >"$UPDATE_NOTES_PATH" <<EOF
# SD Import $APP_VERSION

See the GitHub release for details.
EOF
fi

SPARKLE_ACCOUNT="$SPARKLE_ACCOUNT" \
SPARKLE_DOWNLOAD_URL_PREFIX="$SPARKLE_DOWNLOAD_URL_PREFIX" \
"$ROOT_DIR/script/generate_appcast.sh" "$UPDATES_DIR"

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
    --title "$RELEASE_TITLE" \
    --notes-file "$release_notes_for_github" \
    --latest
else
  gh release create "$RELEASE_TAG" "$DMG_PATH" "$ZIP_PATH" "$APPCAST_PATH" "$UPDATE_NOTES_PATH" \
    --repo "$REPO_FULL_NAME" \
    --title "$RELEASE_TITLE" \
    --notes-file "$release_notes_for_github" \
    --latest
fi

echo "Release ready:"
echo "  https://github.com/$REPO_FULL_NAME/releases/tag/$RELEASE_TAG"
echo "Sparkle feed:"
echo "  $SPARKLE_FEED_URL"
