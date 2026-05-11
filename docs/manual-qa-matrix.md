# SD Import Manual QA Matrix

Use this checklist before major public releases and whenever scanner/import
behavior changes.

No real SD cards are currently mounted in this development environment, so this
file is the required hardware pass list rather than evidence that the hardware
pass has already been executed.

## Required Hardware Passes

| Scenario | Card Contents | Expected Result | Status |
| --- | --- | --- | --- |
| Sony video card | `PRIVATE/M4ROOT`, MP4/MOV clips, `MEDIAPRO.XML`, `DATABASE.BIN`, sidecars | Index files ignored; footage backup recommended; sidecars visible and opt-in | Not run |
| Canon photo card | JPEG plus CR2 and CR3 files | Photo import recommended; CR2/CR3 classified as photos; RAW/JPEG pairs summarized when basenames match | Fixture coverage added; hardware not run |
| Fujifilm photo card | RAF plus JPEG files | Photo import recommended; RAF classified as photo; known files skipped on rescan | Fixture coverage added; hardware not run |
| Nikon photo card | NEF plus JPEG files | Photo import recommended; NEF classified as photo; known files skipped on rescan | Fixture coverage added; hardware not run |
| Mixed RAW/JPEG | Matching RAW and JPEG basenames in the same folder | RAW+JPEG pair count appears; both files remain importable | Fixture coverage exists; hardware not run |
| Video sidecars | Video clips with XML/metadata/proxy files | Footage Backup shows sidecar count; sidecars stay skipped unless kept | Fixture coverage exists; hardware not run |
| Duplicate filenames | Two camera folders containing the same clip filename | Destination plan suffixes later copies and avoids overwrites | Fixture coverage exists; hardware not run |
| Card removal during scan | Remove card after scan starts | User-facing failure; no duplicate job loop | Not run |
| Card removal during import | Remove card during copy | Failed file recorded; retry remains available | Not run |
| Clean Mac user | Fresh user account, no prior settings | Onboarding appears; folders can be selected; Sparkle menu appears in release build | Not run |

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

Do not commit private media, full card dumps, private filenames, or unredacted
diagnostics.
