# SD Import Behavior Contract

This document defines the current importer behavior that the native Swift app must preserve for `v1`.

## Product Invariants

- The app never deletes, moves, renames, or mutates files on the source card.
- Importing the same already-imported original again must not create duplicates.
- Destination folder changes must not make known source files import again.
- A failed or interrupted import must remain visible and retryable.
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
- Retry operates on pending or failed copy rows for an existing job.

## Per-File Copy Status

Minimum statuses:

- `PENDING`
- `COPIED`
- `SKIPPED`
- `FAILED`

Rules:

- Unsupported and known files are skipped.
- New/conflict files start pending.
- Failed files stay retryable.

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
- retry failed/pending files
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
7. Retry a failed job after restoring the source file. The file imports.
8. Cancel during a large copy. No finalized partial file is left behind, and retry remains available.
9. Crash during copy. Relaunch recovers the job and handles stale `.part` files.
10. Prune 30-day History. Old jobs and reports are removed, but dedupe still skips known files.
11. Insert a real SD card with background prompt enabled. One prompt appears.
12. Insert the same card with repeated mount events. No duplicate jobs are created.
13. Disable background prompt. The login item no longer prompts on mount.
14. Use Footage Backup on a card with video sidecar files. Videos and selected sidecars copy as flat files under the generated session folder.
15. Run the notarized app on a clean Mac without Python, Homebrew, Raycast, `swiftDialog`, or `exiftool`.
