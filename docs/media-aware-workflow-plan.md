# SD Import Media-Aware Workflow Plan

This plan refines the import flow for the real working pattern: a card usually
contains either photos or videos, and the user usually processes one media type
per import. Mixed photo/video shoot sessions remain supported, but they should
not be the mental default when a card clearly contains one media type.

## Product Goal

After scanning a card, the app should recommend the workflow that best matches
the card contents:

- photo-heavy card: import photos into the photo library
- video-heavy card: back up footage with card-relative structure and sidecars
- mixed card: organize as a shoot session with `Photos/`, `Video/`, and reports

The user should still be able to override the recommendation before copying.

## Non-Goals

- Do not remove the existing Shoot Sessions workflow.
- Do not auto-copy after mount or scan.
- Do not require users to tag every card before previewing destinations.
- Do not build full catalog/photo-management features.

## Workflow Profiles

Add a first-class workflow profile concept above the existing lower-level
import controls.

| Profile | Best For | Media Selection | Organization | Sidecars |
| --- | --- | --- | --- | --- |
| Photo Import | cards with only or mostly photos | Photos | Classic or photo library dated folders | skipped |
| Footage Backup | cards with only or mostly videos | Videos | Footage Backup | included by default |
| Mixed Shoot Session | cards with meaningful photos and videos | Photos + Videos | Shoot Sessions | skipped unless footage profile is chosen |

The existing `ImportMediaSelection` and `ImportOrganizationPreset` types can
remain as implementation details. A new profile enum should map to them.

## Recommendation Heuristics

Recommendation should run after scan, using the scanned job files.

Suggested first-pass rules:

- If `photoCount > 0` and `videoCount == 0`, recommend `Photo Import`.
- If `videoCount > 0` and `photoCount == 0`, recommend `Footage Backup`.
- If both exist and one side is at least 90 percent of supported media, recommend
  the dominant one but show the other media type as excluded.
- If both exist and neither side dominates, recommend `Mixed Shoot Session`.
- If no supported media exists, keep the current selection and show the unsupported
  count clearly.

Sidecars:

- In `Footage Backup`, unsupported files are sidecars and default to included.
- In other profiles, unsupported files remain skipped.
- Future refinement: associate sidecars to nearby clips by basename/path. The
  first pass can include all unsupported files in footage backup because it
  preserves the card-relative structure.

## UI Changes

The preview should lead with a `Workflow` segmented picker or pop-up:

- `Photo Import`
- `Footage Backup`
- `Mixed Shoot Session`

Below that, show the destination/organization implied by the selected profile.
Avoid showing both media-type controls when the card only contains one type.

Preview behavior:

- Photo-only card:
  - select `Photo Import`
  - hide video toggles
  - show photo destination summary
- Video-only card:
  - select `Footage Backup`
  - hide photo toggles
  - show sidecar count and destination root
- Mixed card:
  - select `Mixed Shoot Session`
  - show both media toggles
  - show per-date session labels

Advanced controls:

- Keep current import/organize controls accessible through a small advanced area
  or menu if needed for debugging and unusual imports.
- Do not expose redundant controls in the primary preview surface when a profile
  already implies them.

## Remembering User Preference

Add preference memory in two layers:

- global last-used workflow profile
- optional per-volume last-used workflow profile keyed by volume name or UUID

Recommendation should use card contents first, then user memory as a tie-breaker
for ambiguous mixed cards.

Examples:

- A card named `A7CII` that repeatedly contains photos can default to
  `Photo Import`.
- A card named `FX3-A` that repeatedly contains videos can default to
  `Footage Backup`.
- If the user overrides a recommendation, save that override after import starts.

## Data Model Additions

Suggested new core models:

```swift
public enum ImportWorkflowProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case photoImport
    case footageBackup
    case mixedShootSession
}

public struct MediaContentProfile: Equatable, Sendable {
    public let photoCount: Int
    public let videoCount: Int
    public let sidecarCount: Int
    public let unsupportedCount: Int
    public let recommendedWorkflow: ImportWorkflowProfile
    public let confidence: RecommendationConfidence
}
```

`ImportWorkflowProfile` should have a pure mapping to:

- `ImportMediaSelection`
- `ImportOrganizationPreset`
- default sidecar behavior

This keeps UI state simple and makes recommendation logic testable without
SwiftUI.

## Implementation Slices

### W1: Core Recommendation Model

Status: `[x]`

Goal:

- Add workflow profile and content-profile recommendation logic.

Code scope:

- `SDImportCore/Models/ImportWorkflow.swift`
- new `SDImportCore/Workflow/ImportWorkflowRecommender.swift`
- unit tests for photo-only, video-only, mixed, dominant, and empty cards

Verification:

- Pure unit tests require no filesystem.
- Existing scanner/import tests remain green.

### W2: Apply Recommendations After Scan

Status: `[x]`

Goal:

- After scan, set the preview workflow to the recommended profile unless the user
  has already manually chosen a profile for the current job.

Code scope:

- `SDImportApp/Stores/AppModel.swift`
- `SettingsRepository` if global/per-volume preference storage is added now

Verification:

- AppModel or core tests prove scan files map to the expected selected profile.
- Manual test photo-only fixture defaults to `Photo Import`.
- Manual test video-only fixture defaults to `Footage Backup`.

### W3: Preview UI Simplification

Status: `[x]`

Goal:

- Make the preview read like a single workflow choice, not a matrix of unrelated
  switches.

Code scope:

- `SDImportApp/Views/Import/ImportPreviewView.swift`
- optional small subviews for workflow picker, recommendation banner, and session rows

Verification:

- Photo-only preview hides video controls.
- Video-only preview hides photo controls and shows sidecar count.
- Mixed preview keeps both toggles and per-session labels.
- Narrow window check confirms controls do not push or clip the sidebar.

### W4: Preference Memory

Status: `[x]`

Goal:

- Remember the user's workflow preference globally and optionally by volume.

Code scope:

- `AppConfiguration`
- `SettingsRepository`
- `AppModel`

Verification:

- Unit test configuration round-trips workflow profile.
- Manual test override, import, rescan same volume, and confirm default profile.

### W5: Photo-Specific Preview Polish

Status: `[x]`

Goal:

- Make photo-only imports more understandable for camera cards.

Code scope:

- preview row grouping or summary helpers
- optional RAW+JPEG pair detection

Verification:

- A RAW+JPEG fixture reports pair counts without changing copy behavior.
- Photo-only copy behavior remains unchanged.

## Acceptance Scenarios

1. Scan a card with only `.ARW`/`.JPG` files. Preview recommends `Photo Import`.
2. Scan a card with only `.MP4`/`.MOV` files and `.XML` sidecars. Preview
   recommends `Footage Backup` and includes sidecars.
3. Scan a mixed card with similar photo and video counts. Preview recommends
   `Mixed Shoot Session`.
4. Scan a card with 95 percent videos and a few photos. Preview recommends
   `Footage Backup`, with photos excluded but visible.
5. User overrides a recommendation before import. The planned destinations update
   before copying.
6. Re-scan a known volume after overriding its workflow. The remembered profile
   participates in the next recommendation.
7. No import starts until the user confirms from preview.

## Open Decisions

- Should `Photo Import` use Classic dated folders or a new photo library preset
  under `Photos/<YYYY>/<YYYY-MM-DD label>/`?
- Should per-volume memory key by volume UUID when available, falling back to
  volume name?
- Should sidecars in Footage Backup include every unsupported file or only files
  near video directories? First pass should include all, because structure is
  preserved.

## Recommended Next Step

Implement W1 and W2 first. They make the app smarter without redesigning the
whole preview UI, and they give tests a stable base before the visible controls
are simplified.
