# SD Auto Import (macOS)

This repo provides a deterministic SD-card importer with:

- auto trigger on mount (`launchd` + `StartOnMount`)
- interactive actionable notifications (`alerter`)
- dedupe with SQLite (`~/.sd-import/state.db`) by `sha256 + size`
- preview report before import
- manual CLI trigger for debug/retry
- Raycast extension + Alfred wrapper
- one canonical launcher script (`/Users/xcv58/work/macos-automation/sd-import`)

## Why this solves your "yesterday + today" case

Imported files are tracked by content hash, not folder path.

If you rename/delete destination folders or edit in Lightroom, re-inserting the same card will still skip yesterday's originals (same hash) and import only new content.

## Install

One-line install from this repo:

```bash
cd /Users/xcv58/work/macos-automation && ./install.sh
```

Optional: include Raycast extension import prompt:

```bash
cd /Users/xcv58/work/macos-automation && ./install.sh --with-raycast
```

Optional: custom destination roots:

```bash
cd /Users/xcv58/work/macos-automation && ./install.sh \
  --photos-base /Users/xcv58/Pictures/Photos \
  --videos-base /Users/xcv58/Downloads
```

What `install.sh` configures:

- installs `alerter` (falls back to GitHub binary in `~/.local/bin/alerter`)
- symlinks `sd-import` to `~/.local/bin/sd-import`
- writes `~/Library/LaunchAgents/com.xcv58.sd-import.plist`
- enables and kickstarts launchd service
- creates default config at `~/.sd-import/config.json` if missing

Optional: set default location mapping by editing config:

Create `~/.sd-import/config.json`:

```json
{
  "default_location": "TODO",
  "location_by_volume": {
    "EOS_DIGITAL": "SF"
  },
  "ignore_volume_regex": "Time Machine|Backup"
}
```

Smoke test manually:

```bash
/Users/xcv58/work/macos-automation/sd-import run \
  --input /Volumes/YOUR_SD_CARD \
  --location NYC \
  --notify
```

## Interactive notification flow

On mount (or manual `run`):

1. Script scans files and computes summary.
2. `alerter` shows action buttons:
   - `Review`: opens report (`~/.sd-import/reports/<job_id>.md`)
   - `Import New`: copies only files marked `NEW`/`CONFLICT`
   - `Skip`: no copy

No action can accidentally copy known files because copy is gated by dedupe state.

## CLI commands

### Auto detect removable mount and run interactive flow

```bash
/Users/xcv58/work/macos-automation/sd-import auto
```

### Manual scan only (no copy)

```bash
/Users/xcv58/work/macos-automation/sd-import scan \
  --input /Volumes/YOUR_SD_CARD \
  --location NYC
```

### Import/retry by job id

```bash
/Users/xcv58/work/macos-automation/sd-import import --job-id 20260303-005507
/Users/xcv58/work/macos-automation/sd-import retry --job-id 20260303-005507
/Users/xcv58/work/macos-automation/sd-import retry-latest
```

### Debug jobs

```bash
/Users/xcv58/work/macos-automation/sd-import list-mounts --json
/Users/xcv58/work/macos-automation/sd-import list-jobs
/Users/xcv58/work/macos-automation/sd-import show-job --job-id 20260303-005507
```

### Prune old history (retention)

Prunes `jobs` and `job_files` older than N days, plus their report files in `~/.sd-import/reports/`.
It does **not** prune `items` (dedupe fingerprints), so dedupe history is preserved.

```bash
/Users/xcv58/work/macos-automation/sd-import prune --days 180 --dry-run
/Users/xcv58/work/macos-automation/sd-import prune --days 180 --vacuum
```

## launchd auto-run on SD insert

`install.sh` already installs launchd for you.
Template plist (for reference): `/Users/xcv58/work/macos-automation/launchd/com.xcv58.sd-import.plist`

Install:

```bash
mkdir -p ~/Library/LaunchAgents
cp /Users/xcv58/work/macos-automation/launchd/com.xcv58.sd-import.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/com.xcv58.sd-import >/dev/null 2>&1 || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.xcv58.sd-import.plist
launchctl enable gui/$(id -u)/com.xcv58.sd-import
launchctl kickstart -k gui/$(id -u)/com.xcv58.sd-import
```

Toggle:

```bash
launchctl disable gui/$(id -u)/com.xcv58.sd-import
launchctl enable gui/$(id -u)/com.xcv58.sd-import
launchctl kickstart -k gui/$(id -u)/com.xcv58.sd-import
```

Logs:

- `~/.sd-import/launchd.out.log`
- `~/.sd-import/launchd.err.log`

## Raycast

Use the local extension:

- `/Users/xcv58/work/macos-automation/raycast-extension`
- Import with Raycast `Import Extension` and point to that folder.
- Includes commands:
  - `SD Import Auto`
  - `SD Import Select Volume` (manual volume picker)
  - `SD Import Retry Latest`
  - `SD Import Jobs`

## Alfred

Use `/Users/xcv58/work/macos-automation/alfred/sd-import-auto.sh` in a Script Filter / Run Script workflow.

## Suggested additional features

- import policy by card serial/volume UUID (different destinations per card)
- EXIF/QuickTime capture date extraction (instead of mtime)
- quarantine mode: copy new files to staging, review, then promote
- checksum manifest export (`job_id.manifest.csv`) for audit trail
- optional webhook/Slack summary after each job
- conflict policy options: `skip` / `rename-copy` / `prompt`

## Tests

```bash
cd /Users/xcv58/work/macos-automation
python3 -m unittest discover -s tests -v
```
