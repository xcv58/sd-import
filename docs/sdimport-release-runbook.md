# SD Import Release Runbook

## Hosting

Use GitHub Releases for the stable update channel.

- Human download page: `https://github.com/xcv58/macos-automation/releases`
- Sparkle feed URL: `https://github.com/xcv58/macos-automation/releases/latest/download/appcast.xml`
- Latest DMG URL: `https://github.com/xcv58/macos-automation/releases/latest/download/SD-Import.dmg`
- Supported public artifact: signed and notarized `SD-Import.dmg`
- Supported app target: Apple Silicon (`arm64`) on macOS 14 or newer

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

GitHub Actions is not part of the supported release path. Keep signing,
notarization, and Sparkle private-key material on the release Mac rather than
duplicating those secrets into the repository.

## Public Release Checklist

Before running the release script:

- Confirm the worktree is clean or contains only intentional release changes.
- Confirm `APP_VERSION` is the user-visible version and `APP_BUILD` is greater
  than the latest published Sparkle build.
- Confirm `docs/releases/sd-import-$APP_VERSION.md` exists or set
  `RELEASE_NOTES_FILE` to a user-facing release-notes file.
- Confirm `DEVELOPER_ID_APPLICATION`, `SPARKLE_PUBLIC_ED_KEY`, and notary
  credentials are available on the release Mac.
- Run the required real-card QA matrix in `docs/manual-qa-matrix.md` when the
  release changes scanner/import behavior. Use
  `script/capture_manual_card_qa.sh` to record redacted card evidence.
- Confirm the release remains free and open source, with no Homebrew, App Store,
  paid licensing, or payment infrastructure changes.

Run the release preflight before building:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
SPARKLE_PUBLIC_ED_KEY="base64-public-key" \
NOTARYTOOL_PROFILE="SDImportNotary" \
./script/release_preflight.sh
```

The preflight checks GitHub CLI auth, Developer ID identity availability,
Sparkle public/private key configuration, notary credential configuration, and
signed-commit prompt risk.

The release script enforces these release gates:

- Fails public releases without `DEVELOPER_ID_APPLICATION`.
- Fails public releases without `SPARKLE_PUBLIC_ED_KEY`.
- Fails if notary credentials are missing.
- Fails if local release preflight fails.
- Fails if `APP_BUILD` is not a monotonically increasing integer.
- Fails if the generated appcast does not contain the expected version, build,
  macOS minimum version, `arm64` hardware requirement, versioned DMG URL,
  versioned release-notes URL, positive enclosure length, and Sparkle EdDSA
  signature.
- Fails if required local release artifacts are missing or empty.
- Fails if the published GitHub Release is missing `SD-Import.dmg`,
  `SD-Import.zip`, `appcast.xml`, or `SD-Import.md`.

After the script finishes, manually inspect the release page:

```bash
gh release view "$RELEASE_TAG" \
  --repo "xcv58/macos-automation" \
  --json tagName,name,isLatest,assets,url \
  --jq '{tagName,name,isLatest,url,assets:[.assets[].name]}'
```

Validate the local signed/notarized artifact:

```bash
xcrun stapler validate dist/SD-Import.dmg
spctl --assess --type open --context context:primary-signature --verbose dist/SD-Import.dmg
codesign --verify --deep --strict --verbose=2 "dist/SD Import.app"
```

Validate the public latest links:

```bash
curl -fsI "https://github.com/xcv58/macos-automation/releases/latest/download/SD-Import.dmg"
curl -fsSL "https://github.com/xcv58/macos-automation/releases/latest/download/appcast.xml" -o /tmp/sdimport-appcast.xml
```

Confirm `/tmp/sdimport-appcast.xml` references the versioned release asset for
the release you just published, not a stale older release.

## Release Notes Expectations

Release notes should be user-facing and short. Use
`docs/releases/sd-import-$APP_VERSION.md` unless a different
`RELEASE_NOTES_FILE` is passed.

Good release notes include:

- What changed for users.
- Any import correctness, update, compatibility, or recovery impact.
- Any manual follow-up users need after installing.
- Known limitations if a fix is partial.

Avoid internal-only implementation details unless they explain a user-visible
change.

## Rollback Notes

Sparkle clients follow the appcast attached to the GitHub Release marked as
latest. If a release must be pulled:

1. Mark the previous known-good GitHub Release as latest.
2. Confirm `https://github.com/xcv58/macos-automation/releases/latest/download/appcast.xml`
   now serves the previous known-good appcast.
3. Leave the bad release visible only if users need the notes for context;
   otherwise mark it as a pre-release or delete the broken assets.
4. If users may already have installed the bad release, publish a new hotfix
   release with a higher `APP_BUILD`. Do not reuse or decrement Sparkle build
   numbers.
5. Document the rollback or hotfix reason in release notes and in any linked
   issue.

## Credential Fragility Notes

The release path intentionally keeps Developer ID certificates, notarization
credentials, and Sparkle private keys on the release Mac. That also means the
release can fail or hang if Keychain, 1Password, GitHub CLI, or git signing is
not ready before the build starts.

- Prefer `NOTARYTOOL_PROFILE` stored with `xcrun notarytool store-credentials`
  over typing Apple credentials during release.
- Prefer `SPARKLE_PRIVATE_KEY_FILE` or `SPARKLE_PRIVATE_KEY` prepared before the
  release command when Keychain prompts are unreliable.
- Run `./script/release_preflight.sh` before packaging.
- If signed commits hang through 1Password during release prep, use an explicit
  noninteractive commit command for release docs or version commits:

```bash
git -c commit.gpgsign=false commit
```

Do not disable artifact signing. The workaround is only for repository commits;
the app and DMG must still use Developer ID signing and notarization.

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
