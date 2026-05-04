# SD Import 1.11

- Fixed destination validation for folders whose names contain trailing spaces, including mounted drive folders that macOS Finder makes hard to distinguish visually.
- Preserved the validated filesystem path throughout scan, preview, import, settings capacity display, and bookmark saving so imports target the folder the app actually accepted.
- Kept pasted paths forgiving by falling back to trimmed paths when the exact text is not a real folder.
- Avoided guessing when multiple sibling folders only differ by leading or trailing whitespace.
- Kept History job details visible beside the recent-imports list instead of pushing details below long history lists.
