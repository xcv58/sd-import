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
3. Allow the scan and review the files, shoot name, and planned destinations.
4. Start copying and keep the source connected until the import finishes.
5. Choose `Eject Source` when finished with a verified removable source.

You can keep photos and videos together or use separate destinations, and group
imports by capture date. Each mounted storage volume remains selectable in the
source menu. A device eject action can unmount related volumes belonging to the
same camera; wait for the safe-to-remove confirmation before disconnecting it.

In `Settings > General`, `Prompt when a card is mounted` enables background card
prompts. Keep the App Store app installed in `Applications`. If the helper needs
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
- Different files at an existing destination are not overwritten. Ordinary
  filename conflicts get a suffix. Insta360 recording conflicts are skipped to
  preserve filenames; select another destination before copying.
- Automatic ejection runs only after an error-free import. Failed, cancelled,
  and zero-copy imports do not automatically eject the source.

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
