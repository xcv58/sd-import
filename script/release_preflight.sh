#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_FULL_NAME="${GITHUB_REPOSITORY:-xcv58/sd-import}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-xcv58-sd-import}"

fail() {
  echo "$1" >&2
  exit 2
}

warn() {
  echo "warning: $1" >&2
}

usage() {
  cat >&2 <<EOF
usage: ./script/release_preflight.sh

Checks local release prerequisites without building or publishing.

Expected environment for public releases:
  DEVELOPER_ID_APPLICATION
  SPARKLE_PUBLIC_ED_KEY
  NOTARYTOOL_PROFILE
    or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD

Optional:
  SPARKLE_PRIVATE_KEY_FILE
  SPARKLE_PRIVATE_KEY
  GITHUB_REPOSITORY           default: xcv58/sd-import
  SPARKLE_ACCOUNT             default: xcv58-sd-import
EOF
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

command -v git >/dev/null 2>&1 || fail "git is required."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is required."
command -v swift >/dev/null 2>&1 || fail "swift is required."
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required."
command -v security >/dev/null 2>&1 || fail "security is required."

if ! gh auth status >/dev/null 2>&1; then
  fail "GitHub CLI is not authenticated. Run: gh auth login"
fi

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  fail "DEVELOPER_ID_APPLICATION is required for a public release."
fi

if ! security find-identity -p codesigning -v | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null; then
  fail "Developer ID identity was not found in the login keychain: $DEVELOPER_ID_APPLICATION"
fi

if [[ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  fail "SPARKLE_PUBLIC_ED_KEY is required for a public release."
fi

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" && -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  fail "Set only one of SPARKLE_PRIVATE_KEY_FILE or SPARKLE_PRIVATE_KEY."
fi

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" && ! -r "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  fail "SPARKLE_PRIVATE_KEY_FILE is not readable: $SPARKLE_PRIVATE_KEY_FILE"
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

if [[ "$(git -C "$ROOT_DIR" config --bool commit.gpgsign || true)" == "true" ]]; then
  warn "commit.gpgsign is enabled. If 1Password signing prompts hang, use noninteractive release commits such as: git -c commit.gpgsign=false commit"
fi

if ! git -C "$ROOT_DIR" diff --quiet -- . ':!dist'; then
  warn "worktree has uncommitted changes outside dist; release target should be an intentional commit."
fi

echo "Release preflight passed for $REPO_FULL_NAME"
echo "Sparkle account: $SPARKLE_ACCOUNT"
