# SD Import Native

This directory contains the native macOS migration for SD Import.

The first native app target is `SDImportApp`, backed by `Packages/SDImportCore` for shared scanning, import planning, persistence, and history logic. The existing Python/Raycast implementation at the repository root remains the reference implementation until the native app reaches parity.

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
APP_VERSION="1.0.0" \
APP_BUILD="100" \
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
./script/sparkle_generate_keys.sh
```

Use the printed public key for release builds:

```bash
APP_VERSION="1.0.0" \
APP_BUILD="100" \
SPARKLE_FEED_URL="https://example.com/sd-import/appcast.xml" \
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

Sparkle's private key must stay outside git and outside the public hosting
bucket. Public builds should move to a native Xcode app archive/export target
before automatic updates are enabled for users; the current SwiftPM bundle path
is kept for local development and validation.

You can also pass credentials directly with environment variables:

```bash
APPLE_ID="you@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_PASSWORD="app-specific-password" \
./script/notarize.sh dist/SD-Import.dmg
```
