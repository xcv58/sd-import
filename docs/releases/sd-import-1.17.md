# SD Import 1.17

- Fixes a destination correctness bug where files could still copy to the folder that was selected during scan after the destination was changed before import.
- Replans pending files against the current destination immediately before copying, so the preview and import use the latest selected folders.
- Updates native job history to record the actual destination roots used for the import.
- Moves the legacy auto-prompt launch agent to runtime destination configuration instead of install-time hardcoded folder arguments.
- Adds regression coverage for scan-with-destination-A, import-with-destination-B flows in both the native app and legacy automation path.
