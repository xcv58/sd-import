#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/SDImport/Packages/SDImportCore"
UPDATES_DIR="${1:-$ROOT_DIR/dist/sparkle-updates}"
SPARKLE_BIN_DIR="$PACKAGE_DIR/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-xcv58-sd-import}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-}"
SPARKLE_RELEASE_NOTES_URL_PREFIX="${SPARKLE_RELEASE_NOTES_URL_PREFIX:-}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"

usage() {
  cat >&2 <<EOF
usage: ./script/generate_appcast.sh [updates-directory]

Place signed/notarized SD Import update archives and matching release notes in
the updates directory, then run this script to generate Sparkle appcast files.

Optional environment:
  SPARKLE_ACCOUNT
  SPARKLE_DOWNLOAD_URL_PREFIX
  SPARKLE_RELEASE_NOTES_URL_PREFIX
  SPARKLE_PRIVATE_KEY_FILE
  SPARKLE_PRIVATE_KEY
EOF
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  swift package --package-path "$PACKAGE_DIR" resolve
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "Sparkle generate_appcast tool was not found at: $GENERATE_APPCAST" >&2
  exit 2
fi

mkdir -p "$UPDATES_DIR"

appcast_args=(--account "$SPARKLE_ACCOUNT")

if [[ -n "$SPARKLE_DOWNLOAD_URL_PREFIX" ]]; then
  appcast_args+=(--download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX")
fi

if [[ -n "$SPARKLE_RELEASE_NOTES_URL_PREFIX" ]]; then
  appcast_args+=(--release-notes-url-prefix "$SPARKLE_RELEASE_NOTES_URL_PREFIX")
fi

if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" && -n "$SPARKLE_PRIVATE_KEY" ]]; then
  echo "Set only one of SPARKLE_PRIVATE_KEY_FILE or SPARKLE_PRIVATE_KEY." >&2
  exit 2
fi

run_generate_appcast() {
  local output
  local status

  set +e
  if [[ -n "$SPARKLE_PRIVATE_KEY" ]]; then
    output="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" "${appcast_args[@]}" "$UPDATES_DIR" 2>&1)"
    status=$?
  else
    output="$("$GENERATE_APPCAST" "${appcast_args[@]}" "$UPDATES_DIR" 2>&1)"
    status=$?
  fi
  set -e

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  fi

  if (( status != 0 )); then
    exit "$status"
  fi

  if [[ "$output" == *"does not match key EdDSA"* ]]; then
    echo "Sparkle appcast signing failed: the private key does not match SUPublicEDKey in the update archive." >&2
    exit 2
  fi
}

if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  appcast_args+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi

if [[ -n "$SPARKLE_PRIVATE_KEY" ]]; then
  appcast_args+=(--ed-key-file -)
fi

run_generate_appcast
