# SD Import Native

This directory contains the native macOS app for SD Import.

For normal installation and daily use, start with the user guide:

```text
docs/user-guide.md
```

The app target is `SDImportApp`, backed by `Packages/SDImportCore` for shared scanning, import planning, persistence, and history logic. The existing Python/Raycast implementation at the repository root remains available for legacy automation users.

## Developer Notes

Build and launch the app bundle from the repository root:

```bash
./script/build_and_run.sh
```

The staged app bundle is written to:

```text
dist/SD Import.app
```

Create local distribution artifacts:

```bash
./script/package_dmg.sh
```

Set bundle versions per release:

```bash
APP_VERSION="1.0" \
APP_BUILD="1" \
./script/package_dmg.sh
```

Set `DEVELOPER_ID_APPLICATION` to a Developer ID Application signing identity
to produce Developer ID signed artifacts. Without it, the packaging script uses
ad-hoc signing for local bundle validation.

Store notarization credentials in Keychain once:

```bash
xcrun notarytool store-credentials "SDImportNotary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID"
```

Submit a signed DMG for notarization using the saved Keychain profile:

```bash
NOTARYTOOL_PROFILE="SDImportNotary" \
./script/notarize.sh dist/SD-Import.dmg
```

## Sparkle Updates

The main app has Sparkle 2 wired through the standard updater UI. Local builds
leave Sparkle disabled unless both update values are present in the generated
app bundle:

- `SPARKLE_FEED_URL`
- `SPARKLE_PUBLIC_ED_KEY`

Generate a Sparkle EdDSA key pair once:

```bash
./script/sparkle_generate_keys.sh --account "xcv58-sd-import"
```

Export the same private key for 1Password backup:

```bash
./script/sparkle_generate_keys.sh \
  --account "xcv58-sd-import" \
  -x ~/Desktop/sdimport-sparkle-private-key.txt
```

The export command does not generate a second key when the same account is used.

Use the printed public key for release builds:

```bash
APP_VERSION="1.0" \
APP_BUILD="1" \
SPARKLE_FEED_URL="https://github.com/xcv58/macos-automation/releases/latest/download/appcast.xml" \
SPARKLE_PUBLIC_ED_KEY="base64-public-key" \
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
./script/package_dmg.sh
```

For CI or public release jobs, set `REQUIRE_SPARKLE_CONFIGURATION=1` so the
packaging script fails if the feed URL or public key is missing.

Generate the appcast from the directory that contains signed/notarized update
archives and matching release notes:

```bash
./script/generate_appcast.sh dist/sparkle-updates
```

Create or update a GitHub Release in one local command:

```bash
APP_VERSION="1.0" \
APP_BUILD="1" \
RELEASE_NOTES_FILE="docs/releases/sd-import-1.0.md" \
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
SPARKLE_PUBLIC_ED_KEY="base64-public-key" \
NOTARYTOOL_PROFILE="SDImportNotary" \
./script/release_github.sh
```

Every public release should include a short, user-facing changelog in the
release notes. Prefer writing a `RELEASE_NOTES_FILE` with 3-8 high-level bullets
that explain what changed for users. If no notes file is provided, the release
script generates a basic changelog from commit subjects instead of publishing a
generic placeholder.

The release script should publish Sparkle release notes with a version-specific
GitHub asset URL, such as
`https://github.com/xcv58/macos-automation/releases/download/v1.0/SD-Import.md`.
Avoid `releases/latest/download/SD-Import.md` for release notes because GitHub's
latest-release redirect can be stale while a new update is being published.

Sparkle's private key must stay outside git and outside the public hosting
bucket. Public builds should move to a native Xcode app archive/export target
before automatic updates are enabled for users; the current SwiftPM bundle path
is kept for local development and validation.

See `docs/sdimport-release-runbook.md` for the full GitHub Releases, Apple
Developer ID, Sparkle key, and old-to-new update test workflow.

You can also pass credentials directly with environment variables:

```bash
APPLE_ID="you@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_PASSWORD="app-specific-password" \
./script/notarize.sh dist/SD-Import.dmg
```
