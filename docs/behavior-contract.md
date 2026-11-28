# SD Import Behavior Contract

This document defines the current importer behavior that the native Swift app must preserve for `v1`.

## Product Invariants

- The app never deletes, moves, renames, or mutates existing files on the source card.
- When the user opts in to portable import receipts, the app may create or append only within `.sd-import` on the source.
- Importing the same already-imported original again must not create duplicates.
- Destination folder changes must not make known source files import again.
- A failed or interrupted import must remain visible and offer a fresh scan.
- A closed, skipped, or timed-out prompt must not start copying.
- History is user-support history, not immutable audit evidence.

## Media Classification

Photo extensions:

- `.jpg`
- `.jpeg`
- `.heif`
- `.heic`
- `.dng`
- `.raw`
- `.cr2`
- `.nef`
- `.arw`
- `.raf`

Video extensions:

- `.mp4`
- `.mov`
- `.avi`
- `.mkv`

Rules:

- Extension matching is case-insensitive.
- Dotfiles and files inside dot-directories are ignored.
- Unsupported files are counted as unsupported and are not copied in normal photo/video imports.
- Footage Backup can include unsupported files as sidecars so camera metadata and clip support files stay with the backed-up card structure.

## Fingerprint And Dedupe

The current dedupe fingerprint is derived from:

- file size
- file modification date rounded/formatted to seconds
- source relative path/filename

The legacy Python value was:

```text
sha1("\(size)|\(mtimeISOSeconds)")
```

Where `mtimeISOSeconds` is the local ISO timestamp produced from filesystem modification time with second precision.

Rules:

- The dedupe key is `(fingerprint, size)`.
- Native `v2` fingerprints include source identity so same-size same-second camera neighbors do not collapse into one imported file.
- Existing copied `v1` records are migrated into `v2` dedupe entries on launch.
- A file present in the dedupe ledger is classified as known.
- A known file is skipped even if the original destination folder was renamed or deleted.
- The dedupe ledger is not pruned by normal History retention.
- Resetting the dedupe ledger must be an explicit advanced action.

Optional portable receipt rules:

- Portable receipts are disabled by default and control both reading and writing.
- Receipts live in `.sd-import/imported-v1.jsonl` on the selected source root.
- Each receipt contains only the exact relative source path, size, modification timestamp, import timestamp, schema metadata, and a checksum. It does not contain destination paths or usernames.
- A valid portable receipt classifies the matching source file as known from another Mac.
- Exact path spelling is part of portable identity; case-distinct or whitespace-distinct names do not collapse on case-sensitive sources.
- Scan records the source modification time as epoch seconds for portable identity; import never reconstructs that identity from the timezone-less display timestamp. Older jobs without the epoch fall back to current source metadata.
- Invalid, corrupted, oversized, or path-traversing records are ignored and surfaced as a warning.
- Ledger records are decoded independently so a truncated or invalid UTF-8 record cannot hide earlier valid receipts.
- Ledger access refuses symbolic-link traversal, stays relative to an opened source root, serializes writers, and separates an interrupted final record before the next append.
- Read-only, locked, full, removed, or otherwise unwritable sources never fail the media import; portable history is skipped with a warning.
- Import reloads portable history before copying pending files so receipts added after the original scan are honored.
- Import verifies the source file's current size and modification epoch against the scan before dedupe or copy. Changed files fail with a rescan-required message, and source identity is checked again before a portable receipt is written.
- Review Import can include previously imported files for the current scan, from local tracking or portable receipts. These choices survive destination replanning. Destination conflicts and source validation still apply, and a fresh scan starts with duplicate tracking enabled.
- Existing local dedupe entries are backfilled to a writable source when portable receipts are enabled.

Known tradeoff:

- This is intentionally faster than full content hashing. It is stricter than the legacy metadata-only key, but a renamed copy of the same source file may import again.

## Capture Date

Destination dates are `YYYY-MM-DD`.

Preferred order for photos:

1. EXIF original date.
2. Other image creation metadata.
3. Filesystem creation date.
4. Filesystem modification date.

Preferred order for videos:

1. QuickTime/media creation date.
2. Other asset creation metadata.
3. Filesystem creation date.
4. Filesystem modification date.

Rules:

- If native metadata APIs cannot read a date, fallback dates are acceptable.
- Metadata differences from the Python/exiftool implementation must be documented with fixtures before release.

## Destination Planning

Separate Folders with different roots:

```text
<photosRoot>/<YYYY-MM-DD> <location>/<filename>
<videosRoot>/<YYYY-MM-DD> <location>/<filename>
```

Separate Folders with the same root:

```text
<root>/<YYYY-MM-DD> <location>-Photos/<filename>
<root>/<YYYY-MM-DD> <location>-Video/<filename>
```

Shoot Sessions:

```text
<photosRoot>/<YYYY-MM-DD> <session label>/Photos/<filename>
<photosRoot>/<YYYY-MM-DD> <session label>/Video/<filename>
```

Footage Backup:

```text
<videosRoot>/<YYYY-MM-DD> <session label>/<filename>
```

One Shoot Folder grouping uses one date-range folder for the selected import
instead of one folder per capture date. If the media spans one day, the folder
uses `<YYYY-MM-DD> <session label>`. If the media spans multiple days, the
folder uses `<YYYY-MM-DD> to <YYYY-MM-DD> <session label>`.

```text
<photosRoot>/<YYYY-MM-DD> to <YYYY-MM-DD> <session label>/<filename>
<videosRoot>/<YYYY-MM-DD> to <YYYY-MM-DD> <session label>/<filename>
```

Rules:

- Empty location labels are treated as `Untitled`.
- Destination roots are user-selected folders.
- Separate Folders adds `-Photos` and `-Video` when the selected roots are the same directory.
- The job stores the destination roots used at scan/import time.
- Footage Backup uses flat files under the generated session folder for videos and selected sidecar files.
- One Shoot Folder grouping flattens selected files directly under the generated shoot folder.
- Camera-generated index files such as `DATABASE.BIN` and `MEDIAPRO.XML` are ignored during scanning.

## Decisions

Every scanned file gets one decision:

- `NEW`: supported media file not present in the dedupe ledger and no conflicting existing destination.
- `KNOWN`: supported media file already present in the dedupe ledger or matching an existing destination.
- `CONFLICT`: supported media file not present in the dedupe ledger and intended destination exists with a different fingerprint/size.
- `UNSUPPORTED`: unsupported extension.

Counts:

- `scanned` includes all non-dot files visited.
- `new` includes only `NEW`.
- `known` includes only `KNOWN`.
- `conflicts` includes only `CONFLICT`.
- `unsupported` includes only `UNSUPPORTED`.

## Conflict Resolution

When copying a `NEW` or `CONFLICT` file:

1. Plan the normal destination path.
2. If it does not exist, copy there.
3. If it exists and has the same fingerprint/size, skip and record `already_exists_same_fingerprint`.
4. If it exists and differs, try `stem-copy-1.ext`.
5. Increment the suffix until an unused path or matching duplicate is found.

Examples:

```text
IMG_0001.JPG
IMG_0001-copy-1.JPG
IMG_0001-copy-2.JPG
```

## Copy Behavior

Rules:

- Create destination directories before copying.
- Copy to a `.part` file in the final destination directory.
- Preserve source modification dates when practical.
- Verify copied byte size before finalizing.
- Atomically move the `.part` file to the final destination path.
- On copy failure, remove the active `.part` file when possible.
- Insert into the dedupe ledger only after a successful copy or confirmed matching existing destination.

## Job Status

Minimum statuses:

- `SCANNED`
- `IMPORTING`
- `IMPORTED`
- `IMPORTED_WITH_ERRORS`
- `SKIPPED`
- `CANCELLED`
- `FAILED`

Rules:

- A scan creates a job.
- Import updates the same job.
- Failed files retain per-file errors.
- History offers Rescan Source for unfinished imports from cards and folders. Rescan checks any outstanding copy journal for the old job, then creates a new job and review. The user confirms the fresh plan before copying.
- Starting a new scan or changing the source asks before closing a Scan Both session with pending results. The previous results remain available if the user cancels, the new source cannot be opened, or every new volume fails to scan.
- If a planned source volume disconnects during a copy, the app stops the operation and names the volume. Files already copied remain in History.
- For a manually selected card or folder, disconnect protection uses the mounted volume backing the selected path. Automatic prompt name filters apply only to discovery.
- Source selection rejects paths through user-created symbolic links. macOS system path aliases remain usable.

## Per-File Copy Status

Minimum statuses:

- `PENDING`
- `COPIED`
- `SKIPPED`
- `FAILED`

Rules:

- Unsupported and known files are skipped.
- New/conflict files start pending.
- Failed files and their errors remain in History for reference during a fresh scan.

## Progress

Progress should expose:

- job id
- volume name
- status
- started timestamp
- updated timestamp
- total files
- done files
- imported files
- skipped files
- failed files
- total bytes
- processed bytes
- copied bytes
- throughput
- ETA when calculable
- percent
- current filename
- current source path
- report path or summary path

Terminal progress states:

- `completed`
- `completed_with_errors`
- `failed`
- `aborted`
- `idle`

## Source Ejection

- A successful copy receipt may offer a named eject action for the source card or device.
- The receipt presents ejection as the primary completion action, names the mounted source device, states how many storage volumes will be unmounted, and confirms when it is safe to remove.
- Whenever a verified removable source is selected and no scan or copy is active, the Source panel offers a manual eject action. This lets the user safely disconnect before scanning, after scanning, or instead of importing. A scan never triggers automatic ejection.
- `Eject source device after a successful import` is an opt-in setting and defaults off.
- Automatic ejection requires at least one copied file, an error-free imported job, and a currently mounted removable volume whose UUID matches the scanned job.
- In Scan Both, review one plan with shared settings and file details for each volume. Skip or include each volume before starting. Start Imports checks the whole plan before copying the included volumes in order. If the copy plan changes, the app shows the updated review before copying. Device ejection waits for both volumes to be resolved.
- A failed or cancelled scan of a still-mounted volume can be explicitly skipped. The combined results retain the scan error and show a manual Eject action. It becomes available when the session is resolved and the device passes the eject checks.
- In Scan Both, only a successful copy can trigger automatic ejection. Skipping a volume never triggers it. If a user skips an attempted import that did not succeed, the session offers manual ejection instead.
- Non-removable volumes, disk images, UUID mismatches, cancelled imports, and imports with failures are never ejected automatically.
- Removable cards remain eligible when macOS reports their built-in reader location as internal.
- Ejection uses the source volume root even when the scanned source is a folder inside that volume.
- Volumes that share the nearest physical USB-device registry identity are presented as one source device.
- Multiple mounted volumes on the same whole disk require one whole-disk eject operation. Multiple whole disks exposed by one physical USB device are each ejected before the app reports that the device is safe to disconnect.
- After an import, a destination on the same physical device blocks receipt-driven source-device ejection. Ejection checks the resolved volume behind each approved copy folder, including through symlinks. Eject stays disabled if a destination volume cannot be verified. Scan Both applies the check to both volumes. The explicit Source-panel action remains available whenever no scan or copy is active.
- Device grouping never relies only on volume names, model names, or mount timing. If macOS does not expose a reliable shared identity, volumes remain separate.
- Ejection never forces a busy volume. A partial multi-disk failure reports which storage was ejected and which storage remains mounted.

## History

History jobs store:

- job id
- created timestamp
- started timestamp
- completed timestamp
- mount path
- volume name
- volume UUID when available
- location label
- photo destination root
- video destination root
- status
- scanned count
- new count
- known count
- unsupported count
- conflict count
- imported count
- skipped count
- failed count
- report paths

History files store:

- job id
- source path
- relative source path
- filename
- extension
- size
- mtime
- media type
- fingerprint
- capture date
- decision
- planned destination directory
- planned destination path
- final destination path
- copy status
- error
- completion timestamp

History UI must support:

- recent jobs list
- success/failed filtering
- job detail
- failed file list
- rescan sources from unfinished imports
- reveal destination folder
- copy/export summary
- retention pruning

## Retention

Options:

- 30 days
- 90 days
- 365 days
- forever

Default:

- 90 days

Rules:

- Retention prunes job rows, job file rows, progress files, and generated reports.
- Retention does not prune dedupe `items`.
- A dry run should be available in diagnostics or CLI.

## Mount Detection

Rules:

- Ignore disk images.
- Ignore configured volume name patterns such as Time Machine or backup volumes.
- Prefer removable volumes.
- Debounce repeated mount events for the same mount path.
- Manual import must allow explicit folder selection even if auto detection misses a card.

## Prompt Flow

On mount prompt:

1. User can continue or skip.
2. Timeout or close means no import.
3. Continue starts scan and preview.
4. Preview can import or cancel.
5. Import starts only after explicit confirmation.

Manual flow:

1. User chooses card/folder.
2. Scan starts.
3. Preview appears.
4. User imports or cancels.

## Legacy Migration

Legacy state location:

```text
~/.sd-import/
```

Native state location:

```text
~/Library/Application Support/SD Import/
```

Rules:

- Migration copies or imports legacy data.
- Migration never deletes or mutates legacy files.
- Migration can run repeatedly without duplicating data.
- Legacy config maps to native settings.
- Legacy dedupe items remain effective after migration.

## Release Acceptance Scenarios

1. Import a fixture card with one photo and one video. Both land in the expected date folders.
2. Re-run the same card. Both files are known/skipped.
3. Rename the destination folders and re-run the same card. Files are still known/skipped.
4. Add one new file to the same card. Only the new file imports.
5. Create a different file at the planned destination. Import uses `-copy-N`.
6. Remove the source file after scan and before import. The job records a failed file.
7. Restore a failed job's source file. Use Rescan Source, verify the fresh plan recognizes completed copies, and confirm any remaining copy.
8. Cancel during a large copy. No finalized partial file is left behind. Rescan Source offers a fresh review.
9. Crash during copy. Relaunch recovers the job and handles stale `.part` files.
10. Prune 30-day History. Old jobs and reports are removed, but dedupe still skips known files.
11. Insert a real SD card with background prompt enabled. One prompt appears.
12. Insert the same card with repeated mount events. No duplicate jobs are created.
13. Disable background prompt. The login item no longer prompts on mount.
14. Use Footage Backup on a card with video sidecar files. Videos and selected sidecars copy as flat files under the generated session folder.
15. Run the notarized app on a clean Mac without Python, Homebrew, Raycast, `swiftDialog`, or `exiftool`.
