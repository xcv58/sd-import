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

You can also pass credentials directly with environment variables:

```bash
APPLE_ID="you@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_PASSWORD="app-specific-password" \
./script/notarize.sh dist/SD-Import.dmg
```
