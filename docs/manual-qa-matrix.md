# SD Import Manual QA Matrix

Use this checklist before major public releases and whenever scanner/import
behavior changes.

No real SD cards are available for the current release-prep pass. The release
therefore ships with fixture/synthetic scanner coverage and this hardware matrix
as an accepted compatibility risk. Do not treat this file as evidence that the
physical-card pass has been executed.

Release decision for this pass:

- Physical Sony/Canon/Fujifilm/Nikon card QA is unavailable.
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
| Manual source eject | Complete an error-free import, then choose `Eject Source` on the receipt | The whole source volume unmounts; the receipt says `Source Ejected`; destination files remain accessible | Required before releasing source ejection |
| Automatic source eject | Enable `Eject source after successful import`, then complete an error-free import | The verified removable source volume ejects only after the receipt and report are finalized | Required before releasing source ejection |
| Eject blocked by another app | Keep a source file open in another app, then request ejection | macOS refusal is shown in SD Import; the source remains mounted; no force-eject occurs | Required before releasing source ejection |
| Import completed with errors | Enable automatic ejection, then produce a retryable copy failure | The source remains mounted and retry stays available | Fixture policy coverage exists; confirm with hardware before release |
| Source subfolder | Select a folder inside the mounted card as the source, import, then eject | SD Import ejects the card's volume root rather than only the selected folder | Fixture policy coverage exists; confirm with hardware before release |
| Built-in card reader | Import from a card that macOS reports as both internal-location and removable | The verified removable card remains eligible and ejects normally | Required before releasing source ejection |
| Ejection completion UI | Complete a clean import, then eject from the copy receipt | The named source has a prominent eject action; success changes to a green `Ejected — Safe to Remove` confirmation | Required before releasing source ejection |
| Clean Mac user | Fresh user account, no prior settings | Onboarding appears; folders can be selected; Sparkle menu appears in release build | Accepted risk: clean-user manual pass unavailable |

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
