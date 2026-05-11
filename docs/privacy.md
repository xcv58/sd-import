# SD Import Privacy Policy

Last updated: 2026-05-10

SD Import is a local macOS utility for copying photos and videos from SD cards
or selected source folders into user-selected destinations.

## Data SD Import Stores Locally

SD Import stores app settings, security-scoped folder bookmarks, import history,
and dedupe records on your Mac. The native app stores its database under:

```text
~/Library/Application Support/SD Import/state.sqlite
```

It may also store ordinary app preferences through macOS `UserDefaults`.

The stored data can include:

- Source, photo destination, and video destination folder paths.
- Security-scoped bookmarks for selected folders.
- Import job history, counts, timestamps, and file-level records used to avoid
  duplicate imports.
- Workflow preferences such as history retention, theme, prompt-on-mount, and
  last-used import organization choices.

Imported photos and videos are copied to the destination folders you choose.
SD Import does not delete files from the source card.

## Network Use

The native app uses the network for Sparkle update checks when updates are
configured in the installed release build. Update checks contact the GitHub
Release-hosted appcast for this repository.

SD Import does not currently send analytics, telemetry, import history, media
files, folder listings, or crash reports to the maintainer. Diagnostics export
is opt-in and redacted.

## Diagnostics And Crash Reports

SD Import does not include automatic crash-report upload. macOS may keep local
diagnostic or crash logs according to your system settings. If you report a bug,
you may choose what diagnostic details to share. The Diagnostics screen can
reveal the local crash-report folder or export the latest local SD Import crash
report, but the app does not upload it for you.

When sharing diagnostics, redact private folder names, filenames, camera serial
numbers, account names, and any media metadata you do not want public.

## Support Requests

Public GitHub issues are visible to everyone. Do not attach private photos,
videos, full card dumps, credentials, or unredacted logs to public issues.

Support email: [i@xcv58.com](mailto:i@xcv58.com)

## Changes

Privacy-impacting changes should be documented in this file before release.
