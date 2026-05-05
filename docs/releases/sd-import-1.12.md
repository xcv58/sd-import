# SD Import 1.12

- Publishes a new Sparkle build so users on `1.10` build `11` can update into the trailing-space destination folder fix from `1.11`.
- Keeps the destination validation behavior from `1.11`: folders like `/Volumes/Crucial/footage/maylasia ` are accepted even when Finder or text fields make the trailing space hard to see.
- Adds a release guard so future public releases fail if `APP_BUILD` is not greater than the latest published Sparkle build.
