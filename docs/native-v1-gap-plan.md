# SD Import Native V1 Gap Execution Plan

This plan turns the documented `v1` gaps into implementation slices. Each slice
has a user-facing goal, code scope, verification, and dependencies. Update the
status as each slice lands.

Status legend:

- `[ ]` not started
- `[~]` partial
- `[x]` complete

## Current Baseline

Already implemented:

- `[x]` SwiftPM package with `SDImportCore`, `SDImportApp`, and `sdimport`.
- `[x]` Manual folder-based scan/import flow.
- `[x]` SQLite job, file, and dedupe schema.
- `[x]` Metadata fingerprint dedupe using `size + mtime seconds`.
- `[x]` Capture-date destination planning using filesystem fallback dates.
- `[x]` Conflict suffixing with `stem-copy-N.ext`.
- `[x]` Bounded-memory copy through same-directory `.part` files.
- `[x]` Import progress model and visible progress panel.
- `[x]` Basic History list/detail.
- `[x]` Basic Diagnostics view.
- `[x]` CLI commands: `scan`, `import`, `retry`, `list-jobs`, `show-job`.
- `[x]` Build/run script that stages `dist/SD Import.app`.

## Slice 1: Native Metadata Extraction

Status: `[~]`

Goal:

- Use native APIs to derive capture dates before filesystem fallback.
- Photos prefer EXIF/TIFF creation metadata through ImageIO.
- Videos prefer AVFoundation creation metadata.
- Files without readable metadata still use filesystem creation/modification dates.

Code scope:

- `SDImportCore/Metadata/CaptureDateReader.swift`
- New focused tests in `SDImportCoreTests`
- Update `MediaScanner` default reader to the native composite reader.

Verification:

- Unit test JPEG EXIF `DateTimeOriginal` drives photo folder date.
- Unit test parser accepts common EXIF and QuickTime/ISO strings.
- Existing scanner/import parity tests remain green.

Risks:

- Camera/vendor metadata varies. Keep fallback behavior conservative.
- Video metadata APIs may be slower than filesystem dates, so avoid loading more
  than the asset metadata needed for creation date.

## Slice 2: Settings And Persistent Folder Access

Status: `[x]`

Goal:

- Store destination/source choices in a first-class settings store instead of
  path strings only.
- Save security-scoped bookmarks for selected folders.
- Provide a native Settings scene for destinations, location, history retention,
  diagnostics, and future auto-prompt control.

Code scope:

- `SDImportCore/Config/`
- `SettingsRepository`
- `BookmarkStore`
- `SDImportApp/Views/Settings/`
- `SDImportApp/Stores/AppModel.swift`
- `SchemaMigrator` if bookmark/settings columns need extensions.

Verification:

- Unit tests round-trip settings and bookmarks.
- Manual app test: choose folders, relaunch app, paths still work.
- Manual app test: stale/missing folder shows repair state instead of crashing.

Dependencies:

- Slice 1 can land independently.
- Onboarding should use this store, so finish this before Slice 3.

## Slice 3: First-Run Onboarding

Status: `[x]`

Goal:

- First launch guides the user through photo folder, video folder, default
  location label, and auto-prompt preference.
- A user can complete setup without touching Diagnostics or Terminal.

Code scope:

- `SDImportApp/Views/Onboarding/`
- `SDImportApp/Stores/AppModel.swift`
- Settings store from Slice 2.

Verification:

- Manual app test: empty app support state opens onboarding.
- Manual app test: completing onboarding opens Import with chosen values.
- Manual app test: app does not re-open onboarding after setup is complete.

Dependencies:

- Slice 2.

## Slice 4: Retry, Cancellation, And Recovery

Status: `[x]`

Goal:

- Retry only failed/pending files for an existing job.
- Imports can be cancelled safely.
- Relaunch recovers interrupted jobs and removes stale `.part` files.

Code scope:

- `ImportEngine`
- `CopyEngine`
- `JobRepository`
- New `RecoveryService`
- App progress UI cancel action
- History retry actions

Verification:

- Unit test failed-file retry imports restored source without duplicating copied files.
- Unit test cancellation removes active `.part` and leaves remaining files retryable.
- Unit test recovery marks interrupted jobs and cleans stale `.part` files.
- Manual large-file import cancel/retry smoke test.

Dependencies:

- Slice 1 can land independently.
- Slice 5 should reuse the improved retry/recovery states.

## Slice 5: Retention, History Filters, And Export

Status: `[x]`

Goal:

- History supports success/failed filtering.
- Retention policy prunes jobs, job files, progress files, and generated reports.
- Dedupe `items` are preserved by normal pruning.
- Users can export/copy summaries from History.

Code scope:

- `RetentionPolicy`
- `JobRepository`
- New retention/prune service
- `sdimport prune`
- `HistoryView`
- `HistoryDetailView`
- Diagnostics dry-run action

Verification:

- Unit test 30-day prune removes old jobs/files/reports.
- Unit test prune does not delete `items`.
- Unit test dry run reports candidates without deleting.
- Manual History filter/export test.

Dependencies:

- Slice 4 recommended first so failed-file states are reliable.

## Slice 6: In-App Mount Observer And Prompt

Status: `[x]`

Goal:

- When the app is running, mounting a likely SD card opens a prompt/preview flow.
- Duplicate mount events are debounced.
- No import starts unless the user explicitly confirms.

Code scope:

- New `SDImportCore/Mounts/VolumeDetector`
- New `SDImportCore/Mounts/MountDebouncer`
- `SDImportApp` mount observer service using `NSWorkspace` notifications
- Prompt UI or sheet in the main app
- Auto-prompt setting from Slice 2

Verification:

- Unit test volume filtering ignores disk images and backup patterns.
- Unit test debouncer suppresses duplicate mount paths.
- Manual test mounting a removable volume while app is running prompts once.
- Manual test skip/close starts no import.

Dependencies:

- Slice 2 for auto-prompt setting.
- Slice 3 is useful but not required.

## Slice 7: Login Item Agent

Status: `[x]`

Goal:

- Background helper observes mounts when the main app is not already running.
- Helper launches or activates the main app with the candidate mount.
- Setting enables/disables registration cleanly.

Code scope:

- New `SDImportAgent` executable target.
- Service Management registration from the main app.
- App/agent handoff mechanism.
- Build script staging for nested helper.

Verification:

- Manual test enable auto-prompt registers login item.
- Manual test reboot/login then insert card prompts through main app.
- Manual test disable auto-prompt unregisters/deactivates helper.
- Manual duplicate mount test still prompts once.

Dependencies:

- Slice 6 must land first.
- Distribution packaging must account for the helper.

## Slice 8: Distribution Packaging

Status: `[x]`

Goal:

- Produce a direct-download artifact suitable for a clean Mac.
- Sign with Developer ID, enable hardened runtime, notarize, staple, and package.

Code scope:

- `[x]` Bundle metadata and generated app icon.
- `[x]` Developer ID signing with hardened runtime.
- `[x]` `script/package_dmg.sh`
- `[x]` `script/notarize.sh`
- `[x]` Build script updates for release mode.

Verification:

- `[x]` `codesign --verify --deep --strict` passes.
- `[x]` `spctl --assess` passes.
- `[x]` Notarization succeeds.
- `[ ]` Clean-machine smoke test: app launches and imports without Python/Homebrew.

Dependencies:

- Slices 1-7 should be stable first.

## Slice 9: Source Selection And Path Validation

Status: `[x]`

Goal:

- Let users pick a detected mounted SD card directly from the Import UI.
- Validate source and destination paths before scan/import.
- Show inline feedback when paths are missing, unmounted, or unusable.

Detailed plan:

- `docs/source-selection-validation-plan.md`

Code scope:

- Core path validation helper.
- Mounted-volume listing in `VolumeDetector`.
- `AppModel` validation state and preflight checks.
- `ManualImportView` detected-card menu and validation feedback.

Verification:

- Unit tests for source/destination validation and mounted-volume filtering.
- Manual checks for mounted card selection, missing source, missing destination,
  and card removed after scan.

## Slice 10: Media-Aware Workflow Profiles

Status: `[x]`

Goal:

- Recommend the right workflow after scan based on whether the card is photo-only,
  video-only, or mixed.
- Make one-type-at-a-time imports feel first-class while preserving mixed shoot
  sessions.

Detailed plan:

- `docs/media-aware-workflow-plan.md`

Code scope:

- New workflow profile model and recommender in `SDImportCore`.
- `AppModel` applies the recommendation after scan.
- `ImportPreviewView` leads with a workflow choice and hides irrelevant controls.
- Settings remember global/per-volume workflow preferences.

Verification:

- Unit tests for photo-only, video-only, dominant, mixed, and empty recommendations.
- Manual preview checks for photo cards, video cards with sidecars, and mixed cards.
- Existing import, history, recovery, and packaging checks remain green.

## Slice 11: Sparkle 2 In-App Updates

Status: `[ ]`

Goal:

- Add safe automatic updates for users who install the direct-download app
  outside the Mac App Store.
- Keep SwiftPM as the source/module layout, but use a thin Xcode packaging
  project as the owner of public app archives, Sparkle embedding, entitlements,
  nested signatures, and Developer ID export.
- Use Sparkle 2 rather than a custom updater.

Detailed plan:

- `docs/native-v1-implementation-plan.md`, M7.

Code scope:

- Add Sparkle 2 to the main app target.
- Wire `SPUStandardUpdaterController` and a `Check for Updates...` menu item.
- Add release-only `SUFeedURL`, `SUPublicEDKey`,
  `CFBundleShortVersionString`, and monotonically increasing
  `CFBundleVersion`.
- Add update preferences for automatic checks/downloads using Sparkle defaults.
- Add a pre-update path if the bundled login item must quit before the app
  bundle can be replaced.

Release scope:

- Generate Sparkle EdDSA keys and keep the private key outside git.
- Generate appcasts with Sparkle tooling.
- Host signed/notarized archives, release notes, and appcast files on GitHub
  Releases, R2/S3, or another HTTPS static host.
- Decide whether beta updates use Sparkle channels or a separate beta appcast.

Verification:

- Install an older signed/notarized release, publish a newer signed/notarized
  release, and update through Sparkle.
- Manual `Check for Updates...` finds, installs, and relaunches into the newer
  version.
- Automatic update checks find the newer version on the configured interval.
- The updated bundle contains the updated `SDImportAgent` login item and it
  still prompts after reboot/login.
- Sparkle rejects a tampered or incorrectly signed archive.
- Gatekeeper accepts the updated app.

Dependencies:

- Slice 8 must provide a reliable signed/notarized distribution artifact.
- Public updater builds should use the Xcode archive/export packaging path
  before Sparkle is enabled for users.

## Always-On Verification

Run after every slice:

```bash
./script/build_and_run.sh test
python3 -m unittest discover -s tests -v
./script/build_and_run.sh --verify
```

Feature-specific manual checks should be recorded in the final response for the
slice that required them.
