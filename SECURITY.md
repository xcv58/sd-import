# Security Policy

## Supported Versions

Security fixes are provided for the latest public GitHub Release of SD Import.
Older releases should be updated through `SD Import > Check for Updates...` or
by installing the latest DMG from GitHub Releases.

## Reporting a Vulnerability

Please do not open a public issue for suspected vulnerabilities.

Use GitHub private vulnerability reporting if it is available for this
repository. If it is not available, contact the maintainer through the GitHub
profile for `xcv58`, or email [i@xcv58.com](mailto:i@xcv58.com), and include
only the minimum information needed to start triage.

Useful details:

- Affected SD Import version and build.
- macOS version and Mac architecture.
- Clear reproduction steps.
- Whether the issue involves imported media, destination folders, Sparkle
  updates, notarization, or login item behavior.
- Any relevant logs with personal paths, filenames, and media metadata redacted.

Do not include Sparkle private keys, Apple credentials, GitHub tokens, private
photos, private videos, or full card images.

## Security Posture

- Public distribution is through signed and notarized DMGs attached to GitHub
  Releases.
- In-app updates use Sparkle with EdDSA-signed appcasts.
- Sparkle private keys, Developer ID certificates, notary credentials, and
  GitHub tokens must stay outside the repository.
- SD Import copies from source cards and does not delete, move, rename, or mutate
  source card files.
- Automatic telemetry and crash upload are not part of the current release.
