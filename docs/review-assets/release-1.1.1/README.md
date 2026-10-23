# Version 1.1.1 screenshot preparation

Prepared on October 23, 2026 from commit `6e867a9e3e023a7b468eb53c9f946560f80477fc`.

Four native window captures replace the outdated file preview, import plan, completion, and purchase images. They show the current **Start Trial or Unlock** action, a clean completion screen, and the Apple authentication explanation. `contact-sheet.jpg` provides a quick comparison.

## Capture provenance

All production view sources are unchanged. An isolated local development harness displays the current `RootView`, `ImportPreviewView`, `ImportResultView`, and `PurchaseView`, and captures their real window with `screencapture -x -o -l`. No controls were repainted or assembled from separate frames. The red close control is genuinely disabled while the purchase sheet is open.

The workflow fixture contains 24 synthetic photos and 3 synthetic videos. The actual `MediaScanner` and `ImportEngine` scanned and copied these files into an isolated library: 27 copied, zero failed, 996,257,943 bytes. All 27 destination files matched the source fixture by SHA-256. Temporary capture-only model helpers populate the unchanged views from these actual results. These captures do not exercise the macOS folder picker, App Store purchase authorization, trial activation, card insertion, or ejection.

The purchase fixture supplies sample StoreKit product metadata ($0.00 trial, $9.99 lifetime, Family Sharing) and no entitlement. No purchase or Apple authentication was performed by the screenshot harness. The ordinary signed app was rebuilt separately and passed all seven hosted StoreKit tests at this source commit. These images are local development captures, not TestFlight captures.

The harness uses a separate app identifier and `CFFIXED_USER_HOME`. Its sandbox blocks network access and writes outside the temporary capture workspace. The app's normal settings and import history are not used. No real card or `Sandisk 4T` access is needed.

## Prepared files

| Screen | Native capture | App Store composition |
| --- | --- | --- |
| File preview | `01-file-preview-native.png` | `01-file-preview-2560x1600.png` |
| Import plan | `02-import-plan-native.png` | `02-import-plan-2560x1600.png` |
| Completion | `04-complete-native.png` | `04-complete-2560x1600.png` |
| Trial and purchase | `05-trial-purchase-native.png` | `05-trial-purchase-2560x1600.png` |

Native windows are 2400 × 1500 with transparent rounded corners. App Store compositions are opaque 2560 × 1600, centered on #F2F3F5 without resizing the native window. The website uses 1920 × 1200 derivatives, plus a 960-pixel variant for preview and plan. `manifest.json` records source revision, dimensions, alpha checks, import verification, and SHA-256 hashes.

All four native images were visually inspected, including their controls and corners. They contain no cursor or sharing indicator. The existing third gallery image (copy progress) can be retained if it still matches the release build.

## Validation and remaining release steps

- Website: 80 generated pages, 10 catalogs, 3,070 local references, and seven settings tests passed. Desktop and phone browser checks cover image loading, enlargement, and page width.
- Review the prepared assets together with the commerce repair in PR #31. Merging that PR publishes the website through its existing deployment workflow; App Store screenshot uploads remain a separate release step. This preparation has not uploaded App Store metadata.
- Merge PR #31 only after owner approval, then verify the resulting internal TestFlight build's source commit. The last verified internal build was 1.1.1 (21), source `94faf68`, before these fixes. A new live check on October 23 reached the App Store Connect sign-in screen, so that earlier build state has not been refreshed.
- Use the manually triggered App Store-eligible workflow for a submission or public external TestFlight build; the master workflow creates internal-only builds.
- Upload the completed gallery when preparing the next editable App Store version.

The temporary capture harness, full source/copy SHA-256 comparison, and native StoreKit test result bundle are retained under `.tmp/release-assets-20261023/`.
