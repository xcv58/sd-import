# Contributing to SD Import

SD Import is currently a free, open-source macOS app distributed through GitHub
Releases and Sparkle.

## Project Scope

In scope for the current public release track:

- Native macOS app improvements.
- Import correctness, card detection, destination planning, and history fixes.
- Developer ID signing, notarization, GitHub Release, and Sparkle release-flow
  hardening.
- Documentation, support, privacy, and security improvements.

Out of scope for now:

- Homebrew distribution for the native app.
- App Store distribution.
- Paid licensing, payments, subscriptions, or license checks.
- Required telemetry or automatic crash reporting.

Telemetry or diagnostics collection must be opt-in, documented before release,
and safe to disable.

## Development Setup

Requirements:

- macOS 14 or newer.
- Xcode command line tools.
- Swift 6 toolchain.
- Python 3 for the legacy automation tests.

Run the native Swift tests:

```bash
./script/build_and_run.sh test
```

Run the legacy Python tests:

```bash
python3 -m unittest discover -s tests -v
```

Build the staged native app locally:

```bash
./script/build_and_run.sh build
```

Create local unsigned/ad-hoc distribution artifacts for validation:

```bash
./script/package_dmg.sh
```

Public release artifacts require the Developer ID, notary, and Sparkle
configuration described in [docs/sdimport-release-runbook.md](docs/sdimport-release-runbook.md).

## Pull Requests

Before opening a pull request:

- Keep changes focused and avoid unrelated refactors.
- Add or update tests when import behavior, persistence, release automation, or
  user-facing flows change.
- Update user docs when install, update, support, privacy, or release behavior
  changes.
- Do not commit signing certificates, Sparkle private keys, Apple credentials,
  GitHub tokens, or real user import data.

For release-note-worthy changes, add a short user-facing bullet to the next
`docs/releases/sd-import-<version>.md` file when the release version is known.

## Reporting Bugs

Use the bug report issue template. Include:

- SD Import version and build.
- macOS version.
- Mac model and architecture.
- Camera/card brand, filesystem, and reader type when relevant.
- Whether the import was automatic or manually started.
- What the preview showed and what happened after import.

Do not attach private photos, videos, full card dumps, credentials, or
personally sensitive folder paths. Redact paths when they include private names.

For support that should not start in a public issue, email
[i@xcv58.com](mailto:i@xcv58.com).
