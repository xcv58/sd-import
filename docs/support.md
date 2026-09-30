# SD Card Import Support

Support email: [sd-card-import@jenny.media](mailto:sd-card-import@jenny.media)

In app versions with `Send Feedback…`, choose
`Settings > General > Send Feedback…` or `Help > Send Feedback…`. This opens an
email draft with the app version, build, and macOS version. Add your message,
then send it from your email app.

Public bugs and feature requests should use GitHub Issues:

https://github.com/xcv58/sd-import/issues

Do not attach private photos, videos, full card dumps, credentials, or
unredacted logs to public issues.

## What To Include

- SD Card Import version and build.
- macOS version and Mac model.
- Camera/card brand, filesystem, and reader type.
- Whether import was automatic or manually started.
- What the preview showed before import.
- What happened after import.
- A redacted diagnostics export when useful.

## Diagnostics Export

Open `Help > Diagnostics...`, then choose `Export Diagnostics` or
`Copy Diagnostics`. Export is optional.

The export includes app version, macOS version, settings status, recent job
counts, and selected-job file statuses. It contains no media files. Folder names,
volume names, paths, and error text may remain.

Review the export and redact private information before sharing it.

## Purchases and Restore

Scanning and previewing stay free. The App Store app offers a free 14-day trial
with unlimited imports, no renewal, and no automatic charge. After the trial,
a one-time $9.99 U.S. purchase unlocks lifetime access with Family Sharing.
Local pricing may vary.

Choose `Settings > General > Restore Purchases` using the purchasing Apple
Account or an eligible Family Sharing account. If access is still missing,
email support with the app version and what the purchase sheet shows.

## Card Mount Prompt Troubleshooting

Settings shows the current macOS background-helper state next to `Prompt when a
card is mounted`.

- `Running`: the helper is registered, matches the installed app, and has
  launched since the latest enable or repair attempt.
- `Install required`: install SD Card Import through the App Store in
  `Applications`. Copies launched from other folders cannot own the background
  helper.
- `Managed by installed copy`: choose `Open Installed Copy`. The copy in
  `/Applications` takes precedence over `~/Applications`; within either folder,
  the canonical `SD Card Import.app` name takes precedence over renamed copies.
- `Needs attention`: read the detail shown below the status, then choose
  `Repair`. Runtime launch and handoff failures stay visible until a later
  card handoff succeeds.
- `Needs approval`: choose `Open Login Items`, then allow SD Card Import under
  System Settings > General > Login Items & Extensions.
- `Not registered` or `Helper update needed`: leave the installed app running
  while it retries registration and helper launch with a bounded cooldown. If
  the state remains after the retry window, choose `Repair`.
- `Helper missing`: update SD Card Import through the App Store and open the
  installed copy in `Applications`.

If the state does not return to `Running`, export diagnostics before changing
the setting so support can see the actual macOS helper status, ownership, build,
last launch, last handoff, and last runtime error. Closing the last main window
is supported: a later card mount should create a new main window and present the
prompt without requiring a second manual launch. Mounts observed while an
import or another prompt is active are kept in a durable queue. Card swaps that
reuse the same `/Volumes/...` path remain separate queue entries.

## Crash Reports

SD Card Import does not upload crash reports automatically.

If the app crashes, macOS may store a local crash report under:

```text
~/Library/Logs/DiagnosticReports/
```

The App Store app cannot browse system crash reports. Use macOS Console to
locate a report if support requests one.

Only share crash reports you have reviewed. Redact private folder names,
filenames, card names, serial numbers, and any media metadata you do not want to
share.
