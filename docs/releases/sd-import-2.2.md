# SD Import 2.2

## Changes

- Added an `Eject Source` action to successful copy receipts.
- Added an optional setting to eject verified removable source cards automatically after an error-free import.
- Supports removable SD cards in built-in readers even when macOS reports the reader location as internal.
- Makes the named source-card eject action prominent and confirms when the card is safe to remove.
- Kept sources mounted after cancellations, copy failures, UUID mismatches, or macOS eject errors so imports remain safely retryable.
- Updated project, support, and release links for the renamed `xcv58/sd-import` GitHub repository.
