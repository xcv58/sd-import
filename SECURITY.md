# Security Policy

## Supported Versions

Security fixes are provided for the latest Mac App Store version of SD Card
Import. Source-code fixes are maintained on the repository's default branch.
Update installed apps through the App Store's Updates section.

## Reporting a Vulnerability

Please do not open a public issue for suspected vulnerabilities.

Use GitHub private vulnerability reporting if it is available for this
repository. If it is not available, contact the maintainer through the GitHub
profile for `xcv58`, or email [sd-card-import@jenny.media](mailto:sd-card-import@jenny.media), and include
only the minimum information needed to start triage.

Useful details:

- Affected SD Card Import version and build.
- macOS version and Mac architecture.
- Clear reproduction steps.
- Whether the issue involves imported media, destination folders, App Store
  purchases, folder permissions, or login item behavior.
- Any relevant logs with personal paths, filenames, and media metadata redacted.

Do not include signing private keys, Apple credentials, GitHub tokens, private
photos, private videos, or full card images.

## Security Posture

- Public app distribution, updates, and purchases are handled through the Mac
  App Store. The App Store app is sandboxed.
- Signing keys, Apple credentials, and GitHub tokens must stay outside the
  repository.
- SD Card Import copies media without deleting, moving, or renaming the originals.
  Optional portable import receipts write only a hidden history ledger on
  writable sources; this feature is disabled by default.
- Automatic telemetry and crash upload are not part of the current release.
