# App Store Connect Metadata

This is the owner-reviewed source of truth for the first Mac App Store release.
Copy from this file into App Store Connect, then record any accepted change here
so the shipped app, StoreKit configuration, screenshots, and review notes do not
drift apart.

## App Record

- App name: `SD Card Import`
- Apple ID: `6807178069`
- Platform: macOS
- Version: `1.0`
- Resubmission build: `6`
- Bundle ID: `media.jenny.sdimport`
- SKU: `media.jenny.sdimport.macos`
- Primary language: English (U.S.)
- Price: Free
- Primary category: Photography
- Suggested secondary category: Utilities
- Release mode: Manual release after approval
- Copyright: `2026 Jenny Media LLC`

## Lifetime In-App Purchase

These values intentionally match
`SDImport/Packaging/MacAppStore/SDImport.storekit`.

- Type: Non-Consumable
- Reference name: `SD Import Unlimited`
- Product ID: `media.jenny.sdimport.unlimited`
- App Store Connect Apple ID: `6807199159`
- Base country or region: United States
- Base price: USD 9.99
- Family Sharing: On
- English (U.S.) display name: `SD Import Unlimited`
- English (U.S.) description: `Unlimited SD imports with Family Sharing.`

### IAP Review Notes

The copy below reflects the renamed app. App Store Connect locks the attached
IAP record during this submission; its existing review notes still refer to
SD Import for Mac. The new name and refreshed purchase screenshot were sent
to App Review in the September 10 response instead.

SD Card Import includes one successfully completed import at no charge.
Previewing and scanning do not consume the allowance. After that first import,
start another import or open Settings > Purchase and choose Unlock Unlimited
Imports to present this non-consumable purchase. The purchase unlocks unlimited
completed imports and supports Family Sharing. Restore Purchases is available
in the same Settings section. The app has no account or purchase server.

For review, select a source containing a JPEG or MOV file and a writable
destination folder. Complete one import, then attempt a second import to open
the purchase sheet. The attached review screenshot shows the same sheet and
the localized App Store price.

### IAP Review Screenshot

The refreshed 2560 x 1600 review image shows the real purchase sheet in the
local development build of version 1.0 (6), including the displayed `$9.99`
price and Family Sharing disclosure. The image uses only synthetic media
and contains no personal filenames, volume names, or paths. It is not a
TestFlight purchase capture.

This image was attached to the App Review response for the current
resubmission. If App Review requires a capture from the processed TestFlight
build, repeat the same flow with a fresh sandbox account that does not own
the product; do not describe this local development capture as a TestFlight
purchase capture.

## Product Page Copy

### Subtitle

`Smart SD card importing`

### Promotional Text

`Preview every card for free, import new photos and videos into organized folders, and safely eject when you are done.`

### Description

SD Card Import makes it easy to copy photos and videos from SD cards into organized
folders on your Mac.

Insert a card, decide whether to scan it, review what is new, choose where the
files should go, and import with a clear completion report. SD Card Import remembers
previously imported files so repeat scans can focus on new content.

Features:

- Explicit permission before each newly inserted card is scanned.
- Separate destinations for photos and videos.
- Capture-date organization with a preview before copying.
- Duplicate awareness across repeat scans.
- Support for common photo, RAW, video, and sidecar workflows.
- Import history and redacted diagnostics.
- Safe ejection for verified removable sources.
- No account, advertising, analytics, or subscription.

Previewing and scanning are free. The Mac App Store edition includes one
successfully completed import, and a one-time lifetime purchase unlocks
unlimited completed imports. Purchases can be restored for the current Apple
ID, and eligible family members receive access through Apple's Family Sharing.

Your media stays on your Mac and in the destination folders you choose. SD Card
Import does not upload media or automatically delete files from a source card.

### Keywords

`sd card,photo import,video import,camera,backup,organize,raw,media,duplicate,eject`

### URLs

- Support URL: `https://sd.jenny.media/support.html`
- Marketing URL: `https://sd.jenny.media/`
- Privacy policy URL: `https://sd.jenny.media/privacy.html`

Publish the current `docs/support.html` and `docs/privacy.html` before entering
these URLs in a submission, then verify the production responses in a private
browser window.

## App Privacy Draft

- Tracking: No
- Data linked to the user: None collected by the developer
- Data not linked to the user: None collected by the developer
- Privacy label: Data Not Collected

Apple processes StoreKit transactions. SD Card Import does not receive payment
details and has no analytics, telemetry, account, purchase server, or automatic
crash-report upload. Recheck these answers against the final uploaded build.

## App Review Notes

SD Card Import is a sandboxed, local SD-card import utility. It does not
require an account or network service beyond Apple StoreKit.

When Prompt when a card is mounted is enabled, the embedded login item detects
a removable-volume mount and wakes the containing app. The helper does not
enumerate or scan the card. The main app first presents its own Scan This Card
consent prompt. If consent is granted and access is not already authorized,
macOS then presents a folder-access panel. No media enumeration occurs until
both steps are accepted.

To test without a physical card, choose a folder containing a JPEG or MOV file
as the source and choose writable destination folders. To test the physical
helper flow, allow SD Card Import under System Settings > General > Login Items &
Extensions, quit the main app, and insert a removable card.

The app includes one successfully completed import at no charge. Scanning,
previewing, cancelling, and failed or empty imports do not consume it. After the
first completed import, attempting another import opens the lifetime purchase
sheet. Purchase and restore controls are also available under Settings >
Purchase.

The Mac App Store build contains no Sparkle updater, temporary sandbox
exception, privileged operation, or analytics, and it does not download or
launch command-line tools. Source ejection uses the public macOS workspace API
only for the user-selected, verified removable source and never forces a busy
volume.

### Build 6 Rejection Fixes

The App Store listing and installed app are now named SD Card Import. The app
bundle identifier remains media.jenny.sdimport.

After closing the main window with the red close button, choose Window > Show
SD Card Import to reopen it. File > Import From Card (Command-I), Navigate >
Import / History / Settings, and the app Settings command also reopen the
window. Clicking the Dock icon restores it as well. The Show command restores
a minimized window without creating a duplicate window.

### Reply to App Review

Sent on September 10, 2026 at 1:10 AM EDT, with
`03-lifetime-purchase-2560x1600.png` attached:

> Thank you for the review. We have addressed both issues in version 1.0, build 6.
>
> For Guideline 5.2.5, we renamed both the App Store listing and the installed application to “SD Card Import,” removing “for Mac.” The bundle identifier remains media.jenny.sdimport.
>
> For Guideline 4, the Window menu now includes “Show SD Card Import,” which reopens the main window after it is closed. File > Import From Card (Command-I), the Navigate menu, the Settings command, and clicking the Dock icon also restore the window. We verified the close-and-reopen behavior with native application tests and manual local testing.
>
> The corrected build is attached to this submission, and we refreshed the product-page screenshots for file preview, import organization, and the lifetime purchase sheet. To verify the window fix, launch the app, close its main window with the red close button, then choose Window > Show SD Card Import. No sign-in is required.
>
> The attached purchase screenshot shows the genuine purchase sheet in the local development build of version 1.0 (6), including the $9.99 price and Family Sharing disclosure. The existing non-consumable product and bundle identifiers are unchanged.

## Owner-Supplied Fields

Keep these values out of the repository until they are entered directly into
App Store Connect:

- App Review first and last name
- App Review phone number
- App Review email address

## Screenshot Set

Use opaque 2560 x 1600 PNGs on a consistent #F2F3F5 background. Preserve the
unaltered native window capture, including its real controls and transparent
rounded corners, alongside each App Store composition. Use only synthetic
media; never use the volume `Sandisk 4T`.

Final submitted gallery, September 10, 2026:

1. `01-file-preview-2560x1600.png`: 27 synthetic files in the preview grid.
2. `02-import-plan-2560x1600.png`: Sample Shoot and the Shared library destination.
3. `03-lifetime-purchase-2560x1600.png`: genuine purchase sheet showing $9.99
   and Family Sharing.

All three are fresh native captures of the local development build of version
1.0 (6). They are not TestFlight captures. Superseded receipt and Settings
images were removed from the product-page gallery; original files remain in
the local release archives. The purchase image was also attached to the review
response because the separate IAP review materials are locked.

Prepared files and their SHA-256 manifest are in:

`/Users/Shared/SD Card Import Release/2026-09-10/screenshots/`

Native images are 3024 x 1896 with transparent corners. App Store compositions
are opaque 2560 x 1600. All three images were inspected, including all four
corners. They contain no sharing indicator or cursor, and no controls were
repainted. The purchase sheet legitimately disables the red close button.

## Resubmission Record

- Source commit: `615a51f3287a5d470d56fce66bbdacb36bd71d79`.
- Version/build: `1.0 (6)`, built with stable Xcode 26.6 (`17F113`).
- App and helper: universal arm64/x86_64, Apple Distribution signed, exact
  provisioning profiles, sandbox/App Group entitlements and privacy manifests
  verified. Strict bundle audit passed; no Sparkle or development test artifacts.
- Validation: 234 package tests, 9 hosted StoreKit/window tests, and user-confirmed
  local manual window testing passed. The processed build was not installed
  through TestFlight: assigning it to Internal QA required additional permission.
- Upload succeeded: September 10, 2026 at 04:51:43 UTC; processing completed.
- Build ID: `335968b5-e0d8-4181-8ab4-1f00da30dbe7`.
- App name, description, review notes, three screenshots, and selected build 6
  verified in App Store Connect.
- Review response and purchase screenshot sent at 1:10 AM EDT.
- Resubmitted at 1:10 AM EDT. Both the app version and SD Import Unlimited are
  **Waiting for Review**. Manual release after approval remains selected.
- Submission ID: `2f1632a6-a99f-4fba-99ff-3c443bd68523`.
- [Submission and review response](https://appstoreconnect.apple.com/apps/6807178069/distribution/reviewsubmissions/details/2f1632a6-a99f-4fba-99ff-3c443bd68523).
- Signed archive, verification record, sent reply, and submission screenshot:
  `/Users/Shared/SD Card Import Release/2026-09-10/`.

The existing IAP record was preserved. Automatic approval review blocked
removing it from the unresolved submission because Apple's confirmation warns
about releasing other accepted items. No IAP pricing, identifiers, availability,
Family Sharing, or separate IAP review materials were changed. The refreshed
purchase capture was delivered through the app gallery and review response.
