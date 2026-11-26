# SD Card Import User Guide

SD Card Import copies photos and videos from SD cards or selected source folders
into the destinations you choose. It remembers previous imports so repeat scans
can focus on new files.

## Install

Get [SD Card Import on the Mac App Store](https://apps.apple.com/us/app/sd-card-import/id6807178069?mt=12).
It supports Apple Silicon and Intel Macs running macOS 14 or newer. Apple handles
installation, updates, and purchases.

Scanning and previewing stay free. A free 14-day trial provides unlimited
completed imports without renewal or automatic charges. After the trial, a
one-time $9.99 U.S. purchase unlocks lifetime access with Family Sharing. Local
pricing may vary.

## Set Up and Import

1. Open Settings and choose your photo and video destinations.
2. Insert a card or choose `File > Import From Card...` (`Command-I`).
3. Select the source and click `Scan Card`. If the button says `Allow Access & Scan`,
   confirm the source in the macOS folder picker. Review the files, shoot name,
   and planned destinations after scanning.
4. If a destination shows `Allow Access`, choose the folder in the macOS picker
   and review the updated plan. Then start copying and keep the source connected
   until the import finishes.
5. Use the eject action on the copy receipt when finished with a verified
   removable source. Wait for the safe-to-remove confirmation.

If copying stops, files already copied stay in the destination and in History.
Reconnect the original card if needed, then choose `Rescan Source` from the
interrupted import or its History entry. Choose the source folder and confirm
the fresh import plan. The new scan can recognize files already copied.

Select the original source folder on the card or Mac when choosing a folder to
scan. Source paths through user-created symbolic links are rejected.

You can keep photos and videos together or use separate destinations, and group
imports by capture date. Each detected camera storage volume remains selectable
in the source menu.

In `Settings > General`, `Prompt when a card is mounted` enables background card
prompts. When the app recognizes your camera's internal storage and memory card
as one device, choose either volume or `Scan Both` from the same prompt. With
`Scan Both`, grant access to each volume as macOS asks. After both scans, open
`Review import` and choose `Confirm Plan` for each volume you want to copy.
Use `Skip` to leave a volume out. Select `Start Imports` to copy the confirmed
volumes one at a time. If a plan changes before its copy starts, review it again.
Keep both volumes mounted until the imports finish.

The app asks before a new scan or source change discards pending Scan Both
results. `Keep Scan Results` returns to those results. You can use `Eject`
from the combined results when both volumes are resolved and the device can
be safely ejected. If a second volume mounts after the prompt closes, look for
it in `Source`. If all volumes unmount, reconnecting the camera or inserting
a replacement card can open a fresh prompt.

Keep the App Store app installed in `Applications`. If the helper needs
approval, allow it in macOS System Settings under Login Items & Extensions. Open
the app manually and use `Import From Card...` if automatic prompting fails.

## Safety and Duplicate Imports

- The app copies media without deleting the originals from the card.
- Optional portable import receipts add a hidden `.sd-import/imported-v1.jsonl`
  history ledger to writable sources. This option is off by default. Read-only
  sources continue without writing portable history.
- Files recognized from portable history are labeled `Other Mac`. Choose
  `Import Anyway` only when you want to copy those files again.
- If a source file changes after scanning, rescan before copying it.
- Ordinary filename conflicts get a suffix to preserve both files. If an
  Insta360 recording has a filename conflict, choose another destination to
  keep the original filenames.
- Automatic ejection requires an error-free import that copied files. With
  Scan Both, the app checks for auto-eject after the final successful copy.
  Skipping a volume after an unsuccessful copy leaves ejection manual.

Maintain backups and verify copied files before formatting a card.

## Keyboard Shortcuts

- `Command-I`: open Import.
- `Command-1`, `Command-2`, `Command-3`: Import, History, Settings.
- `Control-Tab` / `Control-Shift-Tab`: next / previous panel.
- `Command-R`: refresh History.
- `Command-,`: Settings.

Diagnostics are available from `Help > Diagnostics...`.

## Updates, Purchases, and Feedback

Open the App Store and choose Updates. The
[App Store listing](https://apps.apple.com/us/app/sd-card-import/id6807178069?mt=12)
has the public version history. Purchases can be restored from
`Settings > General > Restore Purchases` using the purchasing Apple Account or
an eligible Family Sharing account.

Email [sd-card-import@jenny.media](mailto:sd-card-import@jenny.media).
In app versions that include `Send Feedback…`, use
`Settings > General > Send Feedback…` or `Help > Send Feedback…`. This opens an
email draft with app version, build, and macOS details; add your message and
send it from your email app.

Diagnostics export is optional and includes no media files. Folder names, paths,
and error text may remain, so review and redact the export before sharing it.
See [support.md](support.md), [privacy.md](privacy.md), and
[SECURITY.md](../SECURITY.md) for more detail.
