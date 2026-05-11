# SD Import Support

Support email: [i@xcv58.com](mailto:i@xcv58.com)

Public bugs and feature requests should use GitHub Issues:

https://github.com/xcv58/macos-automation/issues

Do not attach private photos, videos, full card dumps, credentials, or
unredacted logs to public issues.

## What To Include

- SD Import version and build.
- macOS version and Mac model.
- Camera/card brand, filesystem, and reader type.
- Whether import was automatic or manually started.
- What the preview showed before import.
- What happened after import.
- A redacted diagnostics export when useful.

## Diagnostics Export

Diagnostics export is opt-in from `Diagnostics > Export Diagnostics` or
`Diagnostics > Copy Diagnostics`.

The export includes app version, macOS version, settings status, recent job
counts, and selected-job file statuses. It excludes media files, file names, and
full source/destination paths.

Review the export before sharing it.

## Crash Reports

SD Import does not upload crash reports automatically.

If the app crashes, macOS may store a local crash report under:

```text
~/Library/Logs/DiagnosticReports/
```

Use `Diagnostics > Reveal Crash Reports` to open the folder, or
`Diagnostics > Export Latest Crash Report` to save the newest local SD Import
report for support.

Only share crash reports you have reviewed. Redact private folder names,
filenames, card names, serial numbers, and any media metadata you do not want to
share.
