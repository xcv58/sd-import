#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/SDImport/Packages/SDImportCore"
UPDATES_DIR="${1:-$ROOT_DIR/dist/sparkle-updates}"
SPARKLE_BIN_DIR="$PACKAGE_DIR/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"

usage() {
  cat >&2 <<EOF
usage: ./script/generate_appcast.sh [updates-directory]

Place signed/notarized SD Import update archives and matching release notes in
the updates directory, then run this script to generate Sparkle appcast files.
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
exec "$GENERATE_APPCAST" "$UPDATES_DIR"
