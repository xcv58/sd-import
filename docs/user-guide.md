# SD Import User Guide

SD Import is a macOS app for copying photos and videos from SD cards into dated folders. It remembers files it has already imported, so inserting the same card again only imports new files.

## Download

GitHub Releases are the canonical public download location. Use this link to
install the latest signed and notarized DMG:

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
3. In `General`, keep Theme set to `System` unless you want to force Light or Dark.
4. Leave `Prompt on card mount` on if you want SD Import to appear when you insert a card.

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

## Keyboard Shortcuts

- `Command-I`: open Import.
- `Command-1`: Import.
- `Command-2`: History.
- `Command-3`: Settings.
- `Command-4`: Diagnostics.
- `Control-Tab`: next panel.
- `Control-Shift-Tab`: previous panel.
- `Command-Option-S`: show or hide the sidebar.
- `Command-R`: refresh History.
- `Command-,`: Settings.

## Updates

SD Import uses Sparkle for in-app updates and checks the GitHub Release-hosted
appcast.

To check manually:

1. Open `SD Import`.
2. Choose `SD Import > Check for Updates...`.
3. Follow the update prompt.

Update settings are available in `SD Import > Settings > Updates`.

To verify you are on the latest release:

1. Choose `SD Import > Check for Updates...`.
2. If Sparkle reports that no update is available, the installed app is current
   for the public update feed.
3. You can also compare the installed version from the macOS app information
   panel with the latest GitHub Release:

https://github.com/xcv58/macos-automation/releases/latest

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

For release details and public support, see:

https://github.com/xcv58/macos-automation/releases

Support email: [i@xcv58.com](mailto:i@xcv58.com)

For privacy details, see [privacy.md](privacy.md). For security reporting, see
[../SECURITY.md](../SECURITY.md).
