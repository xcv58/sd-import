# SD Import 1.15

- Keeps `Keep sidecars` off by default for Footage Backup imports so video folders stay focused on footage unless support files are explicitly selected.
- Treats tiny JPEG files under 1 MB as likely camera preview files when a card also contains video, preventing those previews from making a video card look like a mixed photo/video shoot.
- Leaves tiny JPEGs on photo-only cards alone so legitimate small still images continue to import normally.
- Allows preview JPEGs and other sidecar-like support files to be copied through the existing `Keep sidecars` opt-in.
- Adds regression coverage for sidecar defaults, tiny video-preview JPEG recommendations, and opt-in copy behavior.
