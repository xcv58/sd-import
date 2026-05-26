# SD Import 2.0

## Changes

- Introduces the scan-first import flow: start with a source, scan the card, then choose the import plan from the detected photo and video content.
- Clarifies mixed-card decisions with Import Type, Destination, and Group Into controls instead of the older preset/customize model.
- Supports one library or separate photo/video folders from the same Import Plan, with destination fields shown only when they matter.
- Shows destination context during copying, including compact target summaries and per-file target paths in Recent Files.
- Refreshes the public website media and copy to match the current app.

## Verification

- Ran the full Swift package test suite: 103 tests passed.
- Built the SDImportApp target successfully.
- Verified the refreshed website screenshot and screencast assets against the current Import Plan UI.
