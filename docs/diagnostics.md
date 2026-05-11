# Diagnostics And Crash Reporting

SD Import uses two local diagnostics mechanisms:

- Apple unified logging for high-signal scan/import events.
- Opt-in redacted diagnostics export from the Diagnostics screen.

SD Import does not upload telemetry or crash reports automatically.
The Diagnostics screen can reveal the local macOS crash-report folder or export
the latest local SD Import crash report. Crash reports are not redacted by the
app; review them before sharing.

## Local Logs

The app logs bounded scan and import state transitions through Apple's unified
logging system under the `com.xcv58.SDImport` subsystem. Logs avoid source paths,
destination paths, file names, and media metadata.

Useful local filters:

```bash
log stream --info --style compact --predicate 'subsystem == "com.xcv58.SDImport"'
log stream --info --style compact --predicate 'subsystem == "com.xcv58.SDImport" && category == "Import"'
```

## Opt-In Export

Use `Diagnostics > Export Diagnostics` or `Diagnostics > Copy Diagnostics`.

The export includes:

- App version and build.
- macOS version and architecture.
- Sparkle feed configuration status.
- Redacted source and destination paths.
- Recent local crash-report metadata, without crash-report filenames.
- Recent job counts and statuses.
- Selected job file extensions, media kinds, decisions, copy statuses, sizes,
  and errors.

The export excludes:

- Media files.
- File names.
- Full source and destination paths.
- Sparkle private keys, Apple credentials, GitHub tokens, or payment data.

Review diagnostics before sharing them in public.

## Crash Reports

Automatic crash upload is not implemented. If SD Import crashes, macOS may store
local crash reports under:

```text
~/Library/Logs/DiagnosticReports/
```

Users choose whether to share those reports.

Use `Diagnostics > Reveal Crash Reports` to open the folder, or
`Diagnostics > Export Latest Crash Report` to save the newest local SD Import
report for support.
