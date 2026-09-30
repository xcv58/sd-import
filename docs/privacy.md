# SD Card Import Privacy Policy

Last updated: 2026-09-30

This policy covers SD Card Import, a macOS app for copying photos and videos
from SD cards or selected source folders.

## Data Stored Locally

SD Card Import stores settings, folder permissions, import history, and
duplicate-detection records locally on your Mac. The App Store app uses an App
Group container shared with its card-detection helper and may also store
preferences through macOS UserDefaults. Stored records can include folder
paths, security-scoped bookmarks, import counts, timestamps, and file records.
Imported media stays in the destinations you choose.

## Optional Portable Import Receipts

When enabled, portable receipts create or append
`.sd-import/imported-v1.jsonl` on writable sources. The hidden ledger contains
versioned fingerprints, relative source paths, sizes, modification and import
timestamps, and validation checksums so another Mac can avoid duplicate
imports. It contains no destination paths, usernames, or media contents.

The option is disabled by default. Read-only sources continue without writing
portable history, and ledger access refuses symbolic-link redirection outside
the selected source. The app does not delete the original media.

## Network Use and Purchases

Apple handles App Store downloads, updates, and StoreKit purchases. Verified
StoreKit transactions determine trial and lifetime access; trial timing comes
from the verified transaction date. We do not receive payment card details.

Website links and feedback open your browser or email app. SD Card Import does
not automatically send analytics, telemetry, import history, media, folder
listings, or crash reports to the maintainer.

## Diagnostics and Crash Reports

Diagnostics are exported only when you request them and contain no media files.
Folder names, volume names, paths, and error text may remain. Review and redact
the export before sharing it.

SD Card Import does not automatically upload crash reports. The App Store app
cannot browse system crash reports. macOS may store a local report under
`~/Library/Logs/DiagnosticReports/`; use Console to locate one if support
requests it and review it before sharing.

## Support Requests

When emailing support, you choose which message and attachments to send through
your email provider. In app versions with `Send Feedback…`, the prepared draft
includes app version, build, and macOS details. You add the message and choose
when to send it.

Public GitHub issues are visible to everyone. Do not attach private photos,
videos, full card dumps, credentials, or unredacted logs to public issues.

Contact: [sd-card-import@jenny.media](mailto:sd-card-import@jenny.media).
