# SD Import 2.2

## Changes

- Added an `Eject Source` action to successful copy receipts.
- Added an optional setting to eject verified removable source cards automatically after an error-free import.
- Supports removable SD cards in built-in readers even when macOS reports the reader location as internal.
- Makes the named source-card eject action prominent and confirms when the card is safe to remove.
- Offers manual ejection after a successful scan when no files are selected for copying, without automatically ejecting scan-only cards.
- Kept sources mounted after cancellations, copy failures, UUID mismatches, or macOS eject errors so imports remain safely retryable.
- Refined every main screen and Settings with native macOS layouts, system colors, borderless groups, and accessibility-aware contrast in both Light and Dark appearances.
- Updated project, support, and release links for the renamed `xcv58/sd-import` GitHub repository.
