# SD Import Source Selection And Path Validation Plan

This plan improves the manual import entry point so users can select a mounted
SD card directly and get immediate feedback when a path is missing, unmounted,
or not usable.

## Product Goal

The app should treat source and destination paths as live filesystem resources,
not inert strings. A user should be able to:

- pick a detected mounted card from the Import screen
- choose any folder as a source when automatic detection is not enough
- see whether the source and destinations currently exist
- understand when a card has been unmounted before scan or import
- repair missing destination folders or permissions before copying

## Non-Goals

- Do not remove absolute path editing.
- Do not auto-import after selecting a card.
- Do not hide the manual `Choose Folder` escape hatch.
- Do not attempt to remount missing disks.

## UX Shape

On the Import screen:

- `Card or source` should include:
  - a detected-card menu when likely import volumes are mounted
  - a refresh button to re-scan mounted volumes
  - a folder picker for manual source selection
  - the editable absolute path
  - inline validation status
- Destination rows should show inline validation status.
- `Scan Card` should be disabled if the source path is invalid.
- `Import Planned Files` should be disabled if the source has disappeared or
  the needed destination root is invalid.

Validation copy examples:

- `Ready`
- `Card is not mounted`
- `Folder does not exist`
- `Not a folder`
- `Permission needed`

## Core Model

Add small, testable validation types:

```swift
public enum PathValidationPurpose {
    case source
    case destination
}

public struct PathValidationResult {
    public let path: String
    public let purpose: PathValidationPurpose
    public let status: PathValidationStatus
    public var isUsable: Bool
}
```

Validation rules:

- Source must exist, be a directory, and be readable.
- Destination must exist, be a directory, and be writable.
- Empty paths are invalid.
- Tilde paths are expanded before validation.

## Volume Listing

Extend `VolumeDetector` with a mounted-volume listing helper:

- enumerate `/Volumes`
- convert each child into `MountedVolume`
- filter with `isLikelyImportVolume`
- sort by name for stable UI

The UI should also keep the currently typed source path even if it is not in the
detected list.

## Implementation Slices

### S1: Validation Core

Status: `[x]`

Goal:

- Add reusable source/destination path validation.

Code scope:

- `SDImportCore/Validation/PathValidator.swift`
- unit tests for missing, file-not-directory, readable source, writable
  destination, and tilde expansion

### S2: Mounted Card Picker

Status: `[x]`

Goal:

- Surface likely mounted cards directly in the Import UI.

Code scope:

- `VolumeDetector`
- `AppModel.availableSourceVolumes`
- `AppModel.refreshAvailableSourceVolumes()`
- `ManualImportView`

Verification:

- Unit test volume listing filters likely import volumes.
- Manual test refresh lists mounted `/Volumes/*` cards.

### S3: Inline Validation UI

Status: `[x]`

Goal:

- Show validation status under source and destination fields and disable unsafe
  actions.

Code scope:

- `AppModel.sourceValidation`
- `AppModel.photosValidation`
- `AppModel.videosValidation`
- `ManualImportView` field rows

Verification:

- Manual test source path to unmounted card disables scan.
- Manual test missing destination disables import and shows repair feedback.

### S4: Preflight Before Scan And Import

Status: `[x]`

Goal:

- Prevent scan/import from starting if paths became invalid after selection.

Code scope:

- `AppModel.scan()`
- `AppModel.importCurrentJob()`

Verification:

- Unit or manual test remove source after scan, then import shows a path error
  before copy starts.

## Acceptance Scenarios

1. A mounted card appears in the source menu and selecting it updates the path.
2. A manually typed missing source path shows `Card is not mounted` and disables
   `Scan Card`.
3. A valid source and valid destination enable scanning.
4. If the card is unmounted after scan, `Import Planned Files` is disabled and
   explains why.
5. A missing destination shows inline feedback and does not start copying.
6. Manual `Choose Folder` still works for non-card folders.

## Recommended Next Step

Implement this before the media-aware workflow profiles. It is the safer base:
once the selected source is trustworthy, scan-based workflow recommendation can
make better decisions.
