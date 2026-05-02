# SD Import Release Runbook

## Hosting

Use GitHub Releases for the stable update channel.

- Human download page: `https://github.com/xcv58/macos-automation/releases`
- Sparkle feed URL: `https://github.com/xcv58/macos-automation/releases/latest/download/appcast.xml`
- Latest DMG URL: `https://github.com/xcv58/macos-automation/releases/latest/download/SD-Import.dmg`

The release script generates an appcast whose update enclosure points at the
versioned GitHub release asset, while the app itself reads the feed from the
latest release URL.

## Versioning

Use the normal macOS/Xcode convention:

- `APP_VERSION`: user-visible marketing version, for example `1.0`, `1.1`, or
  `1.1.1`.
- `APP_BUILD`: monotonically increasing build number, for example `1`, `2`,
  `3`.

First public release:

```bash
APP_VERSION="1.0"
APP_BUILD="1"
```

Increment `APP_BUILD` for every distributed build. Increment `APP_VERSION` when
the release should be user-visible as a new app version.

## Sparkle Key

Generate the Sparkle EdDSA key once and store the private key in 1Password.

```bash
./script/sparkle_generate_keys.sh --account "xcv58-sd-import"
```

This creates or reuses the `xcv58-sd-import` key in your macOS Keychain and
prints the public key to use as `SPARKLE_PUBLIC_ED_KEY`.

Export the same private key for backup:

```bash
./script/sparkle_generate_keys.sh \
  --account "xcv58-sd-import" \
  -x ~/Desktop/sdimport-sparkle-private-key.txt
```

Save the exported file contents in a 1Password Secure Note named something like
`SD Import Sparkle Private Key`, then delete the desktop file:

```bash
rm ~/Desktop/sdimport-sparkle-private-key.txt
```

The export command does not create a second key when the same account is used.
It exports the existing private key from Keychain.

## Apple Developer ID Setup

You need an active Apple Developer Program membership.

1. Open Xcode.
2. Go to `Xcode > Settings > Accounts`.
3. Select your Apple ID.
4. Click `Manage Certificates...`.
5. Add a `Developer ID Application` certificate.
6. Confirm the local signing identity:

```bash
security find-identity -p codesigning -v | grep "Developer ID Application"
```

Copy the full identity string, for example:

```text
Developer ID Application: Your Name (TEAMID)
```

Create an app-specific Apple password at `https://account.apple.com`, then
store notarization credentials in Keychain:

```bash
xcrun notarytool store-credentials "SDImportNotary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

## Local Release

Run this after the Sparkle key and notary profile are available:

```bash
APP_VERSION="1.0" \
APP_BUILD="1" \
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
SPARKLE_PUBLIC_ED_KEY="base64-public-key" \
NOTARYTOOL_PROFILE="SDImportNotary" \
./script/release_github.sh
```

This builds, signs, notarizes, generates `appcast.xml`, and creates or updates
the GitHub Release.

## GitHub Actions Release

The `SD Import Release` workflow can create releases from the GitHub UI once
these repository secrets exist:

- `DEVELOPER_ID_APPLICATION`
- `DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`
- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_KEY`

To create `DEVELOPER_ID_CERTIFICATE_P12_BASE64`, export the Developer ID
Application certificate plus private key from Keychain Access as a `.p12`, then:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Use a strong export password and store it as
`DEVELOPER_ID_CERTIFICATE_PASSWORD`.

## Old-To-New Update Test

Before calling updates ready for users:

1. Release `v1.0` with `APP_VERSION=1.0` and `APP_BUILD=1`.
2. Install `SD Import.app` from the `v1.0` DMG into `/Applications`.
3. Release a newer build, for example `APP_VERSION=1.0.1` and `APP_BUILD=2`.
4. Launch the installed `v1.0` app.
5. Use `Check for Updates...`.
6. Confirm Sparkle downloads, verifies, installs, and relaunches into the newer
   build.
7. Confirm the bundled `SDImportAgent.app` was replaced and still works after
   logout/login or reboot.
