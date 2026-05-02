#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/SDImport/Packages/SDImportCore"
SPARKLE_BIN_DIR="$PACKAGE_DIR/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"

if [[ ! -x "$GENERATE_KEYS" ]]; then
  swift package --package-path "$PACKAGE_DIR" resolve
fi

if [[ ! -x "$GENERATE_KEYS" ]]; then
  echo "Sparkle generate_keys tool was not found at: $GENERATE_KEYS" >&2
  exit 2
fi

exec "$GENERATE_KEYS" "$@"
