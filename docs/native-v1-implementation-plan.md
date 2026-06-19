# SD Import Native macOS V1 Implementation Plan

## Goal

Build `v1` as a native, direct-download macOS app that preserves the current importer contract while replacing the Python, launchd, Raycast, `swiftDialog`, and Homebrew-dependent pieces with a signed and notarized app bundle.

The product promise is narrow:

- Detect or select an SD card.
- Preview what will be imported.
- Copy photo and video files into user-selected folders.
- Avoid re-importing known originals.
- Show progress, failures, retry actions, and visible history.

This is a migration from a working importer, not a greenfield rewrite. The Swift implementation must prove parity with the current behavior before adding product polish.

## V1 Decisions

- Distribution: direct download only, signed with Developer ID, hardened runtime, notarized, and packaged as `.dmg` or `.zip`.
- Distribution packaging: keep SwiftPM as the source/module layout, but use a thin Xcode app packaging project for public archives, exports, signing, entitlements, Sparkle embedding, and notarized release artifacts.
- In-app updates: use Sparkle 2 with signed appcasts and EdDSA-signed update archives. Do not build a custom updater for `v1`.
- Core architecture: one Swift package shared by the app, login item, and dev CLI.
- Import order: manual import first, history second, background mount prompt third.
- UI: native SwiftUI app with onboarding, settings, manual import, progress, history, and job detail.
- Background behavior: a bundled login item detects mount events and wakes the main app; the main app owns scanning, importing, prompts, bookmarks, and history.
- Persistence: SQLite with versioned migrations from the first Swift commit.
- SQLite library: use GRDB via SwiftPM unless dependency policy changes. It provides migrations, transactions, typed records, and avoids a fragile custom SQLite wrapper.
- Metadata extraction: use native APIs in the shipped product. Do not require `exiftool`, `mdls`, Python, Raycast, `swiftDialog`, Homebrew, or `alerter`.
- History: include it in `v1`, call it `History`, and keep it separate from immutable audit language.
- Dedupe ledger: keep dedupe records longer than UI history. Clearing old History must not make old cards re-import by default.
- Existing repo tooling: keep the Python/Raycast implementation available during migration until Swift parity is proven, then remove it from the shipped product.

## Existing Behavior Contract

These behaviors from the current repo are release-blocking parity requirements:

- Dedupe identity is the metadata fingerprint `size + mtime seconds`, not content hash.
- Dedupe checks are independent of destination folder path.
- Known files are skipped on later scans after import.
- Capture date determines destination folder, with metadata preferred and filesystem dates as fallback.
- Photo destination format: `Photos/YYYY-MM-DD <location>/filename`.
- Video destination format: `Videos/YYYY-MM-DD <location>/filename`.
- Matching photo/video roots use `YYYY-MM-DD <location>-Photos` and `YYYY-MM-DD <location>-Video`.
- Supported photo extensions: `.jpg`, `.jpeg`, `.heif`, `.heic`, `.dng`, `.raw`, `.cr2`, `.nef`, `.arw`, `.raf`.
- Supported video extensions: `.mp4`, `.mov`, `.avi`, `.mkv`.
- Unsupported files are counted and skipped.
- If a planned destination exists with the same fingerprint, skip it and record it as known/skipped.
- If a planned destination exists with different content, classify as conflict and copy to `stem-copy-N.ext`.
- Copy through a same-directory `.part` file and atomically move into final destination.
- Failed files remain retryable.
- Job progress records total files, done files, imported, skipped, failed, bytes, percent, current file, throughput, ETA, and final terminal status.
- History stores jobs and job files with source path, relative path, filename, extension, size, mtime, media type, fingerprint, decision, destination, copy status, and error.
- Reports are lightweight JSON and Markdown summaries.
- Duplicate mount events are debounced.
- No import starts from a prompt flow when the user skips, closes, or times out.

## Target Layout

Create a new native app workspace without disturbing the current Python implementation:

```text
SDImport/
  SDImport.xcworkspace
  SDImport.xcodeproj
  Apps/
    SDImportApp/
      App/
        SDImportApp.swift
        AppDelegate.swift
        Commands.swift
      Views/
        RootView.swift
        SidebarView.swift
        ManualImport/
          ManualImportView.swift
          VolumePickerView.swift
          ScanPreviewView.swift
          ImportProgressView.swift
        History/
          HistoryListView.swift
          HistoryDetailView.swift
          FailedFilesView.swift
        Onboarding/
          OnboardingFlow.swift
          DestinationSetupView.swift
          AutoImportSetupView.swift
        Settings/
          GeneralSettingsView.swift
          DestinationSettingsView.swift
          HistorySettingsView.swift
          DiagnosticsSettingsView.swift
      Stores/
        AppStore.swift
        ImportSessionStore.swift
        HistoryViewStore.swift
        SettingsStore.swift
      Support/
        FilePanelPresenter.swift
        NotificationPresenter.swift
        WindowIDs.swift
    SDImportAgent/
      SDImportAgentApp.swift
      MountEventObserver.swift
      MainAppLauncher.swift
  Packages/
    SDImportCore/
      Package.swift
      Sources/
        SDImportCore/
          Config/
            AppConfiguration.swift
            DestinationRoots.swift
            RetentionPolicy.swift
            BookmarkStore.swift
            ConfigurationStore.swift
          Models/
            FileFingerprint.swift
            ImportJob.swift
            ImportJobStatus.swift
            JobFileRecord.swift
            MediaKind.swift
            MountedVolume.swift
            ScanSummary.swift
            ImportResult.swift
            ImportProgress.swift
          Persistence/
            DatabasePoolFactory.swift
            SchemaMigrator.swift
            JobRepository.swift
            DedupeRepository.swift
            SettingsRepository.swift
            LegacyStateImporter.swift
          Mounts/
            VolumeDetector.swift
            MountDebouncer.swift
          Metadata/
            CaptureDateReader.swift
            ImageCaptureDateReader.swift
            VideoCaptureDateReader.swift
            FileDateFallbackReader.swift
          Scanner/
            MediaClassifier.swift
            FileEnumerator.swift
            DestinationPlanner.swift
            MediaScanner.swift
          Importer/
            ConflictResolver.swift
            CopyEngine.swift
            ImportEngine.swift
            RecoveryService.swift
          Reports/
            ReportWriter.swift
            SummaryFormatter.swift
          Diagnostics/
            DiagnosticsBundleWriter.swift
      Tests/
        SDImportCoreTests/
          FingerprintTests.swift
          DestinationPlannerTests.swift
          ScannerTests.swift
          ImportEngineTests.swift
          HistoryRetentionTests.swift
          LegacyMigrationTests.swift
  Tools/
    sdimport/
      Package.swift
      Sources/
        sdimport/
          main.swift
  scripts/
    build_and_run.sh
    package_dmg.sh
    notarize.sh
  docs/
    native-v1-implementation-plan.md
    behavior-contract.md
```

The existing root-level Python files remain in place until the native product passes parity and distribution gates.

## Swift Targets

`SDImportCore`

- Pure import logic and persistence.
- No SwiftUI.
- No AppKit UI.
- Testable with temp directories and fixtures.

`SDImportApp`

- Main SwiftUI app.
- Owns onboarding, folder selection, security-scoped bookmarks, import preview, progress, settings, history, and user notifications.
- Registers or unregisters the login item through Service Management.

`SDImportAgent`

- Bundled login item.
- Observes mount events.
- Applies debounce.
- Launches or messages `SDImportApp` with the candidate mount.
- Does not scan, copy, prompt for folders, or mutate job history.

`sdimport`

- Developer CLI for parity testing and diagnostics.
- Commands: `list-mounts`, `scan`, `import`, `retry`, `list-jobs`, `show-job`, `prune`, `recover`.
- Not required for normal users.

## App Scenes And UX

Use a regular Dock app. The main scene should be a `WindowGroup` with a `NavigationSplitView`.

Primary sidebar sections:

- Import
- History
- Diagnostics

Use a native `Settings` scene, not a settings page inside the main navigation.

Commands:

- `Import From Card...`
- `Retry Last Failed Import`
- `Open History`
- `Reveal Photo Destination`
- `Reveal Video Destination`
- `Export Latest Summary`

First launch:

1. Explain destination access in plain language.
2. Ask for photo destination folder.
3. Ask for video destination folder.
4. Ask for default location label.
5. Ask whether auto-import prompt on card mount is enabled.
6. Register the login item only if auto-import prompt is enabled.

Manual import:

1. User chooses `Import From Card...`.
2. App lists likely removable volumes and allows choosing a folder manually.
3. App scans the card.
4. App shows preview counts, destination roots, location label, conflicts, and unsupported count.
5. User starts import or cancels.
6. Progress window stays visible and cancellable.
7. Result opens in History detail.

Background import:

1. Login item sees a volume mount.
2. Login item debounces repeated events.
3. Login item launches or activates main app with the mount path.
4. Main app validates the volume and shows the same preview flow.
5. No copying starts without user confirmation unless an explicit future auto-import mode is added after `v1`.

## Persistence Plan

Use Application Support for native state:

```text
~/Library/Application Support/SD Import/
  state.sqlite
  Reports/
  Progress/
  Diagnostics/
```

On first launch, detect legacy state:

```text
~/.sd-import/
  state.db
  config.json
  reports/
  progress/
```

Migration rules:

- Copy legacy state into Application Support; do not mutate or delete legacy files.
- Import legacy `items`, `jobs`, and `job_files`.
- Import legacy config into native settings.
- Preserve report paths when possible, but generate native report paths for new jobs.
- Migration is idempotent and records completion in `schema_migrations` or `settings`.

Native schema should preserve the current table concepts and add versioning:

- `schema_migrations`
- `settings`
- `bookmarks`
- `items`
- `jobs`
- `job_files`

Recommended additions over the current schema:

- `jobs.started_at`
- `jobs.completed_at`
- `jobs.photos_root`
- `jobs.videos_root`
- `jobs.summary_json_path`
- `jobs.summary_markdown_path`
- `jobs.app_version`
- `job_files.capture_date`
- `job_files.final_dest_path`
- `job_files.failure_kind`
- `job_files.completed_at`

Retention:

- History default: 90 days.
- Options: 30, 90, 365, forever.
- Prune `jobs`, `job_files`, progress files, and generated reports according to the History setting.
- Do not prune `items` by default.
- Add a separate advanced action for resetting the dedupe ledger.

## Core Type Batch

Create these first, before UI:

```swift
public enum MediaKind: String, Codable, Sendable {
  case photo
  case video
  case unsupported
}

public struct FileFingerprint: Hashable, Codable, Sendable {
  public let size: Int64
  public let modificationDate: Date
  public let value: String
}

public struct MountedVolume: Identifiable, Hashable, Codable, Sendable {
  public let id: String
  public let name: String
  public let mountURL: URL
  public let volumeUUID: String?
  public let isRemovable: Bool
}

public struct DestinationRoots: Equatable, Codable, Sendable {
  public let photosURL: URL
  public let videosURL: URL
}

public enum FileDecision: String, Codable, Sendable {
  case new
  case known
  case conflict
  case unsupported
}

public enum CopyStatus: String, Codable, Sendable {
  case pending
  case copied
  case skipped
  case failed
}

public enum ImportJobStatus: String, Codable, Sendable {
  case scanned
  case importing
  case imported
  case importedWithErrors
  case skipped
  case cancelled
  case failed
}
```

Additional first-batch models:

- `ImportJob`
- `JobFileRecord`
- `ScanSummary`
- `ImportResult`
- `ImportProgress`
- `RetentionPolicy`
- `LocationLabel`
- `SDImportError`

First-batch services:

- `SchemaMigrator`
- `JobRepository`
- `DedupeRepository`
- `MediaClassifier`
- `FileFingerprint.compute(size:modificationDate:)`
- `DestinationPlanner`
- `ConflictResolver`
- `ReportWriter`

## Native Metadata Plan

Photo date reader:

- Use ImageIO with `CGImageSource`.
- Prefer EXIF `DateTimeOriginal`.
- Fall back to EXIF/TIFF creation-style fields.
- Normalize to local `YYYY-MM-DD` destination date.

Video date reader:

- Use AVFoundation metadata on `AVURLAsset`.
- Prefer QuickTime/media creation date fields.
- Normalize to local `YYYY-MM-DD` destination date.

Fallback:

- Use URL resource creation date when available.
- Use content modification date last.

Parity spike:

- Build a small fixture set with JPEG, HEIC, DNG/RAW, MOV, MP4, and missing metadata cases.
- Compare native date extraction against the current Python/exiftool behavior.
- Document acceptable differences before importing real cards.

## Import Engine Plan

The importer should be an async engine:

- Input: `ImportJob.ID`.
- Output: `AsyncThrowingStream<ImportProgress>`.
- Persistence: update each `job_files` row as work completes.
- Crash safety: copy to `filename.ext.part` in the destination directory, then atomically move to final path.
- Recovery: on app launch, reconcile interrupted jobs and stale `.part` files.
- Cancellation: finish current chunk safely, remove current `.part`, mark remaining pending files as cancelled/pending, and keep retry available.
- Source safety: never delete, move, or mutate source card files.

Conflict resolution:

- If destination is absent, use it.
- If destination fingerprint matches, skip and record `already_exists_same_fingerprint`.
- If destination differs, allocate `stem-copy-1.ext`, `stem-copy-2.ext`, etc.

## Milestones

### M0: Plan And Contract

Outputs:

- This implementation plan.
- `docs/behavior-contract.md` with explicit parity scenarios.
- Fixture list for metadata, dedupe, conflicts, retry, and retention.

Exit criteria:

- The current Python behavior is documented enough to test Swift against it.

### M1: Core Foundation

Outputs:

- Xcode workspace and project.
- `SDImportCore` Swift package.
- GRDB dependency.
- Versioned SQLite migrations.
- Core models.
- Config, bookmark, and retention stores.
- Legacy state importer skeleton.

Exit criteria:

- Unit tests pass for models, fingerprinting, schema creation, and legacy DB detection.

### M2: Core Parity CLI

Outputs:

- `sdimport` dev CLI.
- Volume listing.
- Scanning.
- Native metadata date extraction.
- Destination planning.
- Dedupe classification.
- Conflict resolution.
- Import/copy engine.
- Reports.
- Retry.
- History pruning.

Exit criteria:

- Swift tests cover all current Python tests.
- CLI can import from a fixture card into temp photo/video folders.
- Re-running the same import produces known/skipped files, not duplicates.
- Failed files remain retryable.

### M3: Manual Import App

Outputs:

- First-run onboarding.
- Folder pickers and persistent bookmarks.
- Manual volume picker.
- Scan preview.
- Import progress window.
- Completion summary.
- Native settings scene.

Exit criteria:

- A new user can install, choose folders, import manually, and see results without touching Terminal.
- App launches cleanly with missing or stale bookmarks and offers repair.

### M4: History And Recovery

Outputs:

- History list.
- Job detail.
- Failure list.
- Retry failed import.
- Reveal destination folder.
- Copy/export summary.
- Retention setting.
- Crash recovery on launch.

Exit criteria:

- Every import result is visible and understandable.
- Failed files are actionable.
- Retention pruning removes old jobs/reports but preserves the dedupe ledger.

### M5: Background Mount Prompt

Outputs:

- `SDImportAgent` login item.
- Service Management registration.
- Mount observer.
- Debounce.
- Main app activation/message handoff.
- Setting to enable/disable auto prompt.

Exit criteria:

- Inserting a card prompts through the main app.
- Duplicate mount events do not create duplicate scan/import jobs.
- Disabling auto prompt unregisters or deactivates the login item.

### M6: Distribution

Outputs:

- App icon and bundle metadata.
- `CFBundleShortVersionString` and monotonically increasing `CFBundleVersion`.
- Thin Xcode app packaging project for distributable builds.
- Xcode archive/export flow for public Developer ID artifacts.
- Developer ID signing configuration.
- Hardened runtime configuration.
- Notarization script.
- DMG or ZIP packaging.
- Clean-machine install smoke test.

Exit criteria:

- `codesign --verify --deep --strict` passes on the exported app.
- `spctl --assess` passes on the distributed artifact.
- Notarization succeeds and the ticket is stapled where applicable.
- The app runs on a clean Mac without Python, Homebrew, Raycast, `swiftDialog`, or `exiftool`.

### M7: Sparkle 2 In-App Updates

Recommendation:

- Keep `SDImportCore`, `SDImportApp`, and `SDImportAgent` organized through SwiftPM.
- Use Xcode as the release packaging owner so Sparkle.framework, helper services, the bundled login item, entitlements, and nested signatures are embedded consistently.
- Use Sparkle 2 from the main app only; the update replaces the whole app bundle, including `Contents/Library/LoginItems/SDImportAgent.app`.
- Host release archives and appcast files on GitHub Releases, R2/S3, or another HTTPS static host.

Outputs:

- Sparkle 2 dependency embedded in the distributable app.
- `SPUStandardUpdaterController` wired to Sparkle's standard update UI.
- `Check for Updates...` command in the app menu.
- Automatic update checks with user-controlled preferences.
- `SUFeedURL` and `SUPublicEDKey` in the release `Info.plist`.
- Sparkle EdDSA key pair generated and private key stored outside git.
- Appcast generation flow using Sparkle's `generate_appcast` tool.
- Release notes convention for each shipped archive.
- Stable appcast and optional beta-channel appcast policy.
- Pre-update handling for any running login item process if Sparkle cannot replace the bundle while the agent is active.

Exit criteria:

- Install an older signed/notarized release, publish a newer signed/notarized release, and update through Sparkle.
- Manual `Check for Updates...` finds and installs the newer version.
- Automatic checks find updates on the configured interval.
- The app relaunches into the newer version.
- The bundled login item is replaced with the newer version and still works after reboot/login.
- Sparkle rejects tampered or incorrectly signed archives.
- Gatekeeper accepts the updated app after installation.

## Sandbox And Bookmark Spike

Do this during M1 before locking the architecture:

- Test sandboxed access to user-selected photo and video folders.
- Test sandboxed reading of removable volumes selected through a panel.
- Test whether the login item can reliably observe mounts while sandboxed.
- Test whether the main app can handle agent-to-app handoff without broad entitlements.

Decision rule:

- If sandboxing does not compromise card detection, folder access, or supportability, keep the sandbox enabled.
- If sandboxing causes fragile `v1` behavior, ship direct distribution unsandboxed but keep the folder access abstraction and bookmarks so App Store compatibility remains possible later.

## Distribution Requirements

Direct distribution requires:

- Public release builds should come from the Xcode archive/export packaging path, not from a fully hand-assembled SwiftPM bundle.
- The SwiftPM `build_and_run.sh` path can remain the fast local development runner and local validation path.
- Developer ID Application signing for the app and nested helper.
- Hardened runtime enabled.
- No debug `get-task-allow` entitlement in distribution builds.
- Properly signed nested frameworks, Sparkle helper services, helper apps, and CLI tools.
- Notarization with current Apple tooling.
- Stapling and Gatekeeper validation.
- User-facing first-run permission repair flow.

## Sparkle Update Requirements

Sparkle 2 requires:

- A stable HTTPS `SUFeedURL`.
- A bundled `SUPublicEDKey`.
- A protected EdDSA private key used only by the release process.
- A monotonically increasing `CFBundleVersion`.
- A user-facing `CFBundleShortVersionString`.
- Signed update archives generated from signed/notarized builds.
- An appcast generated by Sparkle tooling rather than hand-edited for normal releases.
- Release notes attached to each archive, either embedded in the appcast or hosted next to the artifacts.
- A tested policy for stable vs beta channels before beta builds are shared.

Use `.zip` or `.dmg` for the first updater implementation. Prefer one public artifact format for both website downloads and Sparkle updates unless testing shows a real reason to split them.

Useful Apple references:

- [Developer ID and Gatekeeper](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Service Management](https://developer.apple.com/documentation/servicemanagement/)

## Key Risks

- Native metadata extraction may not match `exiftool` for every camera/video format.
- Sandboxing may complicate removable-volume access and login-item handoff.
- `size + mtime` dedupe is fast and intentional, but less strict than content hashing.
- Login item behavior differs across macOS versions and System Settings states.
- Migrating legacy state must be idempotent and non-destructive.
- UI must make failed/partial imports obvious enough that users trust retry.
- Sparkle integration risk is mostly packaging risk: nested framework/helper signing, entitlements, bundle versioning, and replacing the bundled login item must be verified on clean machines.
- If the app is run from a read-only DMG or is affected by app translocation, Sparkle may be unable to update it. The installer/download flow should strongly guide users to copy the app to `/Applications`.

## First Implementation Batch

Create only foundation files first:

```text
SDImport/SDImport.xcworkspace
SDImport/SDImport.xcodeproj
SDImport/Packages/SDImportCore/Package.swift
SDImport/Packages/SDImportCore/Sources/SDImportCore/Models/MediaKind.swift
SDImport/Packages/SDImportCore/Sources/SDImportCore/Models/FileFingerprint.swift
SDImport/Packages/SDImportCore/Sources/SDImportCore/Models/ImportJobStatus.swift
SDImport/Packages/SDImportCore/Sources/SDImportCore/Models/JobFileRecord.swift
SDImport/Packages/SDImportCore/Sources/SDImportCore/Models/ScanSummary.swift
SDImport/Packages/SDImportCore/Sources/SDImportCore/Persistence/SchemaMigrator.swift
SDImport/Packages/SDImportCore/Sources/SDImportCore/Persistence/DatabasePoolFactory.swift
SDImport/Packages/SDImportCore/Tests/SDImportCoreTests/FingerprintTests.swift
SDImport/Packages/SDImportCore/Tests/SDImportCoreTests/SchemaMigratorTests.swift
docs/behavior-contract.md
```

First batch acceptance:

- `swift test` runs for `SDImportCore`.
- Fingerprint output matches the current Python `metadata_fingerprint`.
- SQLite schema creates cleanly in a temp directory.
- Legacy `~/.sd-import/state.db` can be detected without being modified.

## V1 Release Checklist

- Fresh install onboarding works.
- Destination bookmark repair works.
- Manual import works from a real SD card.
- Reinsert same card skips known files.
- New files from same card import into correct date folders.
- Conflict files use copy suffixes.
- Progress remains accurate for large video files.
- Cancel/retry works.
- Crash recovery works.
- History list/detail works.
- Failed-file retry works.
- Retention pruning works without clearing dedupe items.
- Login item prompt works after reboot.
- App disables background prompt cleanly.
- No shipped dependency on Python or Homebrew.
- Signed, hardened, notarized, stapled, packaged.
- Public release build uses the Xcode archive/export packaging path.
- Sparkle manual update works from an older release to a newer release.
- Sparkle automatic update check works.
- Updated app includes the updated login item.
