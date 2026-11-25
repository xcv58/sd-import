# SD Import Manual QA Matrix

Use this checklist before major public releases and whenever scanner/import
behavior changes.

A focused physical-card pass is available for source ejection from a built-in
SD reader. Broader camera and failure-path coverage still relies on fixtures and
the remaining hardware matrix below.

Release decision for this pass:

- Focused built-in-reader passes are complete for manual ejection after an
  error-free import and after a zero-copy scan.
- Physical Sony/Canon/Fujifilm/Nikon compatibility QA remains unavailable.
- Fixture coverage exists for common RAW extensions, RAW/JPEG pairing, sidecar
  handling, duplicate filename planning, and card-removal failure paths.
- Broad camera-compatibility claims should wait until the hardware matrix below
  is actually run.
- The capture script is ready for future physical-card evidence.

Use the capture script for each mounted card before filling in the manual app
results:

```bash
./script/capture_manual_card_qa.sh \
  --volume /Volumes/CARD \
  --scenario "Canon photo card" \
  --output /tmp/sdimport-canon-photo-card-qa.md
```

The capture report omits filenames and full paths. Review it before sharing or
committing any excerpt.

## Required Hardware Passes

| Scenario | Card Contents | Expected Result | Status |
| --- | --- | --- | --- |
| Sony video card | `PRIVATE/M4ROOT`, MP4/MOV clips, `MEDIAPRO.XML`, `DATABASE.BIN`, sidecars | Index files ignored; footage backup recommended; sidecars visible and opt-in | Accepted risk: hardware unavailable; fixture coverage exists for index-file ignore and sidecar behavior |
| Canon photo card | JPEG plus CR2 and CR3 files | Photo import recommended; CR2/CR3 classified as photos; RAW/JPEG pairs summarized when basenames match | Accepted risk: hardware unavailable; fixture coverage exists |
| Fujifilm photo card | RAF plus JPEG files | Photo import recommended; RAF classified as photo; known files skipped on rescan | Accepted risk: hardware unavailable; fixture coverage exists |
| Nikon photo card | NEF plus JPEG files | Photo import recommended; NEF classified as photo; known files skipped on rescan | Accepted risk: hardware unavailable; fixture coverage exists |
| Mixed RAW/JPEG | Matching RAW and JPEG basenames in the same folder | RAW+JPEG pair count appears; both files remain importable | Fixture coverage exists; hardware unavailable |
| Video sidecars | Video clips with XML/metadata/proxy files | Footage Backup shows sidecar count; sidecars stay skipped unless kept | Fixture coverage exists; hardware unavailable |
| Duplicate filenames | Two camera folders containing the same clip filename | Destination plan suffixes later copies and avoids overwrites | Fixture coverage exists; hardware unavailable |
| Card removal during scan | Remove card after scan starts | User-facing failure; no duplicate job loop | Fixture coverage exists; hardware unavailable |
| Card removal during import | Remove card during copy | Failed file recorded; retry remains available | Fixture coverage exists; hardware unavailable |
| Manual source eject | Complete an error-free import, then choose the named eject action on the receipt | The whole source volume unmounts; the receipt says `Ejected — Safe to Remove`; destination files remain accessible | Passed 2026-07-22: 11 of 11 files (200.1 MB) copied, then the built-in-reader source ejected |
| Automatic source eject | Enable `Eject source device after a successful import`, then complete an error-free import | The verified removable source device ejects only after the receipt and report are finalized | Required before releasing source ejection |
| Multi-volume camera detection | Connect a camera that exposes internal storage and a memory card as separate disks | Both volumes are direct, one-click source choices labeled with the same physical device | Topology confirmed 2026-07-25 with DJI Pocket hardware: `Untitled` on one whole disk and `Pocket4` on a second whole disk share one DJI USB-device registry identity |
| Staggered camera mounts | With prompting enabled, connect a camera that exposes two volumes. Exercise the second mount while the first volume remains mounted, both while the prompt is open and after choosing a source. Repeat with another reader attached and after disconnecting and reconnecting the camera. | The second camera volume joins the open prompt or appears in Source after dismissal. A different device keeps its own prompt, and reconnecting can prompt again. On the App Store build, granting access to one volume lets only that selection scan. | Automated prompt coordination coverage. Physical camera and signed App Store UI passes pending. |
| Replacement card in a connected reader | With prompting enabled, acknowledge or dismiss the first card, leave the reader connected, then replace the card. Try a new label, a reused label, and a card with multiple partitions. | The replacement card gets a fresh prompt. A stale handoff still refers to the original card. | Automated coverage for replacement snapshots with reused or changed paths and disk numbers. Physical reader testing pending. |
| Multi-volume camera eject | Import from either storage volume, then choose the device eject action | Every whole disk belonging to the verified physical device unmounts before the UI says the camera is safe to disconnect | Grouped manual eject passed 2026-07-25; the post-import receipt path was not separately exercised on multi-volume hardware |
| Partial multi-volume eject failure | Keep one camera volume busy, then eject the grouped device | No force-eject occurs; the app identifies any volume already ejected and the volume that remains mounted | Fixture coverage required; confirm with hardware when practical |
| Eject blocked by another app | Keep a source file open in another app, then request ejection | macOS refusal is shown in SD Import; the source remains mounted; no force-eject occurs | Required before releasing source ejection |
| Import completed with errors | Enable automatic ejection, then produce a retryable copy failure | The source remains mounted and retry stays available | Fixture policy coverage exists; confirm with hardware before release |
| Source subfolder | Select a folder inside the mounted card as the source, import, then eject | SD Import ejects the card's volume root rather than only the selected folder | Fixture policy coverage exists; confirm with hardware before release |
| Built-in card reader | Import from a card that macOS reports as both internal-location and removable | The verified removable card remains eligible and ejects normally | Passed 2026-07-22 with a removable Secure Digital source reported at an internal device location |
| Ejection completion UI | Complete a clean import, then eject from the copy receipt | The named source has a prominent eject action; success changes to a green `Ejected — Safe to Remove` confirmation | Passed 2026-07-22 with source `Untitled` |
| Zero-copy scan ejection | Scan a verified removable card whose files are all known or excluded | The Source panel offers manual ejection; automatic ejection does not run | Passed 2026-07-22: user confirmed the manual zero-copy eject flow; automatic ejection was not exercised |
| Skip-copy scan ejection | Scan a verified removable source with files available to copy, then choose eject instead of import | The Source panel keeps manual ejection available beside `Scan Again`, copies no files, and automatic ejection does not run | Passed 2026-07-25 with DJI Pocket hardware: user confirmed the persistent Source-panel eject action worked without starting the copy |
| Clean Mac user | Fresh user account, no prior settings | Onboarding appears; folders can be selected; Sparkle menu appears in release build | Accepted risk: clean-user manual pass unavailable |
| Old-to-new update (2.6 UI candidate) | Install 2.5 (41), update through Sparkle, and confirm the app relaunches as 2.6 (42) | Sparkle downloads, verifies, installs, and relaunches the signed app; the bundled helper remains build 42 | Passed 2026-08-13: the installed 2.5 (41) app found 2.6, displayed the published release notes, downloaded the update, installed it, and relaunched as 2.6 (42). The bundled helper is build 42, Settings reports `Background helper: Running`, and the installed app's deep code signature verifies. |
| Auto-prompt upgrade | Enable mount prompting in the previous public release, update through Sparkle, then mount one importable card while the app is closed | The updated helper build matches the app, Settings reports Running without toggling, and one visible prompt appears without opening the app manually | Accepted risk for the 2.5 (41) candidate on 2026-08-02: the original field failure cannot be reproduced locally and a physical old-to-new pass is unavailable. Automated coverage verifies helper identity/build repair, scheduled missing/nonlaunching-helper retries, stale-agent rejection, durable occurrence-identified handoff retry, causal health errors, atomic stale-copy preference preservation, and process-lifetime closed-window presentation. Ask the affected user to confirm after release; retain this as a required gate for future background-prompt releases when suitable hardware is available. |
| Auto-prompt hidden app | Hide or minimize SD Import, then mount one importable card | The existing main window activates and presents exactly one prompt | Required before releasing background-prompt changes |
| Auto-prompt with one volume after quit | Install the signed TestFlight build, enable mount prompting, and quit SD Card Import. Mount exactly one importable volume while any other camera storage stays unmounted. | SD Card Import opens on its own and shows exactly one prompt for that volume. | The stall was reproduced on 1.1.5 (37) with a DJI Pocket 4. TestFlight validation of the retry is pending. |
| Auto-prompt closed window | Close the last SD Import main window without quitting, then mount one importable card | SD Import creates a new main window and presents exactly one prompt without a second manual launch | Required before releasing background-prompt changes |
| Auto-prompt approval repair | Disable SD Import in System Settings Login Items while the saved preference remains enabled | Settings shows Needs approval and opens the correct Login Items pane; reapproval restores Running without toggling twice | Required before releasing background-prompt changes |
| Background helper repair feedback | With mount prompting enabled, click Repair while Settings reports a stale helper. Repeat from Diagnostics and check the status if macOS requires approval or the helper fails to launch | Each view immediately shows `Repairing background helper…` with a spinner and disables Repair. The status becomes `Running` after the new helper launches, or shows the warning and next action when repair needs attention | Pending a signed-app UI pass |
| Auto-prompt missing registration | Leave the saved preference enabled, unregister the helper, then relaunch SD Import | The bundled helper is registered again once for the current build; Settings returns to Running without toggling the preference | Required before releasing background-prompt changes |
| Auto-prompt active retry | Leave the installed app active with the saved preference enabled, force the helper into missing or nonlaunching state, and do not close/reopen the app | Registration or helper repair retries after the bounded cooldown and returns to Running without another activation or preference toggle | Automated retry scheduler and causal policy coverage exists; physical validation required for a future background-prompt release |
| Auto-prompt same-build re-enable | Disable and re-enable mount prompting without changing the app build, then prevent the newly registered helper from launching | Settings does not reuse the earlier launch record as proof of health; the nonlaunching-helper repair starts after the bounded health timeout | Automated precise launch-epoch coverage includes a pre-attempt launch in the same wall-clock second; physical validation required for a future background-prompt release |
| Auto-prompt retry cooldown across activation | Force `.notFound` or `.notRegistered`, let an explicit enable, manual repair, or reconciliation registration attempt fail, then repeatedly reactivate the app during the cooldown | No entry point or activation bypasses the persisted cooldown; one retry is attempted when the bounded delay expires | Automated missing-registration policy coverage exists; physical validation required for a future background-prompt release |
| Auto-prompt same-path card swap | Keep an import or prompt active, mount one card at `/Volumes/CARD`, replace it with another card that reuses that path, then finish the blocking work | The durable mailbox retains two occurrence IDs; the current mounted card receives a prompt and cross-origin observations are coalesced only when their volume UUID matches | Automated durable-queue, one-to-one cross-origin correlation, and post-media-probe UUID revalidation coverage exists; physical validation required for a future background-prompt release |
| Auto-prompt multiple app copies | Keep an older same-build or previous-build copy running outside `/Applications`, install the current copy in `/Applications`, then try the toggle and mount one importable card | The uninstalled copy says `Managed by installed copy`, cannot mutate the helper, and only the authoritative installed copy activates with exactly one prompt | Required before releasing background-prompt changes |
| Auto-prompt stale-copy settings save | Open an uninstalled copy before enabling prompting in the installed copy, then change an unrelated path or theme in the stale copy | The unrelated setting saves, but the installed copy's shared auto-prompt preference remains enabled | Automated atomic two-writer repository coverage exists; physical validation required for a future background-prompt release |
| Auto-prompt installation authority | Test copies in `/Applications`, `~/Applications`, Downloads, and a mounted DMG, including a renamed installed copy | `/Applications/SD Import.app` wins deterministically, then another matching app in `/Applications`, then `~/Applications`; an uninstalled-only copy says `Install required` | Required before releasing background-prompt changes |
| Auto-prompt causal errors | Queue an older successful handoff, then force a newer helper launch or mailbox failure before the old event is acknowledged | The newer error remains visible until a later event succeeds; the older acknowledgement does not erase it | Required before releasing background-prompt changes |

## Scan Both

Use an internal TestFlight build and an Insta360 Luna Ultra or DJI Pocket 4
in USB file-transfer mode. Use a camera with media on both storage volumes.
Record the build number and per-volume counts.

1. Confirm the two volumes appear in one prompt with individual choices and
   **Scan Both**. If the mounts are staggered, confirm the second volume joins
   the open prompt.
2. Select **Scan Both** and grant folder access when macOS asks. Confirm
   internal storage finishes scanning before the SD card starts scanning.
3. Confirm the review shows each volume's label, sample filenames, and file
   count. Open each volume's **Review import** and return with **Back to Scan
   Results**. Check that the file list and copy action are scoped to the
   selected volume. Leave the copy action unselected during the scan check.
4. Repeat and decline access to one volume when asked. Confirm the skipped
   volume shows its reason and the sibling's scan result remains available.
   If the device can unmount one volume separately, repeat by safely
   unmounting that volume before its scan starts.
5. Reconnect and choose one volume directly. Confirm the app opens that volume's
   import review.

On November 25, 2026, internal TestFlight 1.2 (40) passed on an Insta360 Luna
Ultra with two exFAT volumes on macOS 27.3. The SD Card joined the open
Internal prompt after a staggered remount. The combined review showed 14
files on Internal and 52 on SD Card, with a separate import review for each.
The scan jobs recorded Internal first. Declining access to Internal kept the
SD Card result. Unmounting the SD Card before its scan kept the Internal
result and reported the SD Card as unmounted. After restoring both mounts,
choosing SD Card by itself opened its individual review. The camera scans
recorded zero imported files.

The native fixture tests also verify that importing one scan job leaves the
other pending.

## Disclosure headers

Use a folder fixture with photos from two dates and two distinct Insta360
recordings, each with its own matching proxy. In Import Review, choose
**Photos + Videos**, **By Capture Date**, and the Files list.
Use a completed fixture import for History and Import Report.
A report fixture with a load error exposes the warning header.

For each header under test, click its title twice, the blank space in its row
twice, and its chevron twice. Each first click should expand the section and
each second click should collapse it. Repeat at the edge of the chevron and
in the gap between the chevron and the label. Check that accessibility exposes
one named disclosure with the matching expanded state.

| Header | Check while expanded |
| --- | --- |
| Import Review → Customize Dates | Edit one day's shoot name and click its Photos and Videos labels. The other day's name stays intact, the copy count updates, and the section stays open. Collapse and reopen it to confirm the edit persists. |
| Import Review → Files → grouped recording | Both member files appear. Selecting one opens its inspector and leaves the group expanded. |
| History → Files → grouped recording | Each member appears under its own recording. Expanding one recording leaves adjacent recordings alone. |
| Import Report → Files → grouped recording | Both member rows appear. Collapsing the group hides those rows. |
| Import Report → Report opened with warnings | The warning detail appears on expand and disappears on collapse. Selecting text inside the detail leaves it expanded. |

## Recorded Ejection Evidence

- Date: 2026-07-22.
- Build: SD Import 2.2 (31), local ad-hoc test build.
- Reader: built-in Secure Digital reader; macOS reported the removable card at
  an internal device location.
- Source: `Untitled`, 512.64 GB capacity.
- Successful-import pass: 11 of 11 files copied, 200.1 MB total, zero failures;
  the named manual eject action unmounted the source and showed the safe-removal
  confirmation.
- Date: 2026-07-25.
- Build: SD Import 2.3 (39), local ad-hoc test build.
- Device: DJI Pocket camera exposing `Pocket4` and `Untitled` as separate whole
  disks under one USB-device identity.
- Multi-volume manual pass: both storage volumes appeared as direct source
  choices; the grouped source action ejected the physical device without
  starting the available copy. The post-import receipt path was not separately
  exercised on this hardware.
- Zero-copy pass: the user confirmed that a completed scan with zero files
  planned for copying offered manual ejection and successfully ejected the
  source.
- Not recorded for this pass: macOS version, Mac model, card brand, filesystem,
  automatic ejection, blocked ejection, copy-failure behavior, and source
  subfolder behavior.

## Evidence To Record

For each hardware pass, record:

- SD Import version and build.
- macOS version and Mac model.
- Camera/card brand and reader type.
- Filesystem, usually exFAT or FAT32.
- Whether import was automatic or manual.
- Preview counts: new, known, sidecars, conflicts.
- Final result: imported, skipped, failed.
- Any diagnostics export or crash report path, if relevant.
- The redacted output from `script/capture_manual_card_qa.sh`, if useful.

Do not commit private media, full card dumps, private filenames, or unredacted
diagnostics.
