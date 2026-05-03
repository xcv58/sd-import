# SD Import User Guide

SD Import is a macOS app for copying photos and videos from SD cards into dated folders. It remembers files it has already imported, so inserting the same card again only imports new files.

## Download

Use this link to install the latest version:

https://github.com/xcv58/macos-automation/releases/latest/download/SD-Import.dmg

Requirements:

- Apple Silicon Mac
- macOS 14 or newer

## Install

1. Download `SD-Import.dmg`.
2. Open the downloaded file.
3. Drag `SD Import.app` to your `Applications` folder.
4. Open `SD Import` from `Applications`.

If macOS says the app was downloaded from the internet, choose `Open`. If macOS blocks the first launch, open `System Settings > Privacy & Security`, then choose `Open Anyway` for SD Import.

## First Setup

When the app opens:

1. Open `SD Import > Settings`.
2. In `Destinations`, choose where imported photos and videos should go.
3. In `General`, leave `Prompt on card mount` on if you want SD Import to appear when you insert a card.

Default folder pattern:

- Photos: `Pictures/Photos/YYYY-MM-DD Location`
- Videos: `Downloads/tmp-YYYY-MM-DD-videos`

## Import From A Card

1. Insert an SD card or connect a camera card reader.
2. SD Import scans the card and shows a preview.
3. Review what is new, already imported, unsupported, or conflicting.
4. Start the import.
5. Keep the card connected until the progress finishes.

You can also open the app and choose `Import From Card...` from the menu.

## Updates

SD Import checks for updates automatically.

To check manually:

1. Open `SD Import`.
2. Choose `SD Import > Check for Updates...`.
3. Follow the update prompt.

Update settings are available in `SD Import > Settings > Updates`.

## Safety Notes

- SD Import copies files; it does not erase the card.
- Files already imported are skipped on future runs.
- If a destination file already exists but is different, SD Import keeps both files by adding a suffix.
- Leave the app in `Applications` so updates can install correctly.

## Help

If an import does not start automatically:

1. Make sure `Prompt on card mount` is enabled in `Settings > General`.
2. Open SD Import manually.
3. Choose `Import From Card...`.

For release details, see:

https://github.com/xcv58/macos-automation/releases
