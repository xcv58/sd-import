#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="${1:-$ROOT_DIR/dist/SD-Import.dmg}"

if [[ ! -f "$ARTIFACT" ]]; then
  echo "Artifact not found: $ARTIFACT" >&2
  exit 2
fi

submit_args=(submit --wait)

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  echo "Submitting with notarytool Keychain profile: $NOTARYTOOL_PROFILE"
  submit_args+=(--keychain-profile "$NOTARYTOOL_PROFILE")

  if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
    submit_args+=(--keychain "$NOTARYTOOL_KEYCHAIN")
  fi
else
  missing=()
  for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("$name")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "Notarization credentials are required." >&2
    echo "Set NOTARYTOOL_PROFILE to a saved notarytool Keychain profile, for example:" >&2
    echo "  xcrun notarytool store-credentials \"SDImportNotary\" --apple-id \"you@example.com\" --team-id \"5736QK4NZX\"" >&2
    echo "  NOTARYTOOL_PROFILE=\"SDImportNotary\" $0 \"$ARTIFACT\"" >&2
    echo "" >&2
    echo "Or set APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD." >&2
    exit 2
  fi

  echo "Submitting with Apple ID credentials for team: $APPLE_TEAM_ID"
  submit_args+=(
    --apple-id "$APPLE_ID"
    --team-id "$APPLE_TEAM_ID"
    --password "$APPLE_APP_PASSWORD"
  )
fi

submit_args+=("$ARTIFACT")

/usr/bin/xcrun notarytool "${submit_args[@]}"

/usr/bin/xcrun stapler staple "$ARTIFACT"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "$ARTIFACT"

echo "Notarized and stapled: $ARTIFACT"
