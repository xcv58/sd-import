# SD Import 1.24

## Changes

- Redesigns the Import screen into a clearer Source, Scan Summary, Import Plan, and Files flow.
- Shows only the source picker before scanning, then reveals shoot name and destination folders after scan results are available.
- Defaults mixed photo/video cards to Photos + Videos so detected media is not silently excluded.
- Preserves the current compatible destination layout for mixed cards instead of forcing a different layout after scan.

## Verification

- Ran the full Swift package test suite: 101 tests passed.
- Ran packaged app verification with the staged macOS app bundle.
