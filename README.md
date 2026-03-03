# SD Auto Import (macOS)

This repo provides a deterministic SD-card importer with:

- auto trigger on mount (`launchd` + `StartOnMount`)
- interactive actionable dialogs via `swiftDialog`
- dedupe with SQLite (`~/.sd-import/state.db`) by metadata fingerprint (`size + mtime`)
- destination folders grouped by capture date (EXIF/QuickTime/metadata, fallback to mtime)
- live copy progress state in `~/.sd-import/progress/<job_id>.json`
- preview report before import
- manual CLI trigger for debug/retry
- Raycast extension + Alfred wrapper
- one canonical launcher script (`$HOME/work/macos-automation/sd-import`)

## Why this solves your "yesterday + today" case

Imported files are tracked by metadata fingerprint (`size + mtime`), not folder path.

If you rename/delete destination folders or edit in Lightroom, re-inserting the same card will still skip yesterday's originals (same fingerprint) and import only new content.

Folder naming:

- photos: `~/Pictures/Photos/YYYY-MM-DD <location>/`
- videos: `~/Downloads/tmp-YYYY-MM-DD-videos/`

`YYYY-MM-DD` is taken from capture date metadata when available (EXIF/QuickTime/Spotlight), with mtime as fallback.

## Install

One-line install from this repo:

```bash
cd $HOME/work/macos-automation && ./install.sh
```

Optional: include Raycast extension import prompt:

```bash
cd $HOME/work/macos-automation && ./install.sh --with-raycast
```

Optional: custom destination roots:

```bash
cd $HOME/work/macos-automation && ./install.sh \
  --photos-base $HOME/Pictures/Photos \
  --videos-base $HOME/Downloads
```

What `install.sh` configures:

- installs `alerter` (legacy fallback; GitHub binary in `~/.local/bin/alerter`)
- installs `exiftool` via Homebrew when available (for reliable capture-date extraction)
- installs `swiftDialog` via Homebrew cask when available (desktop prompts + progress window)
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
$HOME/work/macos-automation/sd-import run \
  --input /Volumes/YOUR_SD_CARD \
  --location NYC \
  --notify
```

## Interactive notification flow

On mount (or manual `run`):

1. Immediate `swiftDialog` decision prompt appears: `Skip` or `Continue`.
2. If `Continue`, a `swiftDialog` status window shows scan/prepare progress (`indexing`, `capture metadata`, `analyzing`).
3. A `swiftDialog` preview prompt appears with counts (`new/known/conflicts/unsupported`); choose `Open Report`, `Import New`, or `Skip`.
4. During copy, a `swiftDialog` status window shows live progress, stays on top, and is moveable.
5. When copy finishes (or is skipped), the status window remains open until you click `Dismiss`.

No action can accidentally copy known files because copy is gated by dedupe state.

Notes:

- Duplicate mount events are debounced (20s default) to avoid double prompts.
- In `--notify` flows, actionable prompts are `swiftDialog`-only (safe timeout/skip if no response).
- If actionable notification is not responded to, flow ends with `no_response_or_timeout` in logs.

Performance note:

- Dedupe now uses a lightweight metadata fingerprint (`size + mtime`) instead of full content hashing.
- Capture-date extraction uses batched `exiftool` reads during scan (instead of per-file calls) to keep prepare stage faster.
- This keeps scan/import fast, but is less strict than full-file SHA-256 dedupe.

## SSH / Headless Mode

CLI works over SSH without desktop access. Use `--no-notify` to avoid GUI notifications:

```bash
~/.local/bin/sd-import auto --no-notify --auto-import --input /Volumes/YOUR_SD_CARD --location NYC
~/.local/bin/sd-import scan --input /Volumes/YOUR_SD_CARD --location NYC
~/.local/bin/sd-import import --job-id <JOB_ID>
```

Notes:

- Raycast/Alfred and `swiftDialog` prompts require a GUI user session.
- `launchd` LaunchAgent auto-mount trigger also depends on a logged-in GUI session.
- For fully headless hosts, trigger `sd-import` from SSH/cron/manual scripts instead.

## CLI commands

### Auto detect removable mount and run interactive flow

```bash
$HOME/work/macos-automation/sd-import auto
```

### Manual scan only (no copy)

```bash
$HOME/work/macos-automation/sd-import scan \
  --input /Volumes/YOUR_SD_CARD \
  --location NYC
```

### Import/retry by job id

```bash
$HOME/work/macos-automation/sd-import import --job-id 20260303-005507
$HOME/work/macos-automation/sd-import import --job-id 20260303-005507 --progress-ui
$HOME/work/macos-automation/sd-import retry --job-id 20260303-005507
$HOME/work/macos-automation/sd-import retry --job-id 20260303-005507 --progress-ui
$HOME/work/macos-automation/sd-import retry-latest
```

### Live copy status (CLI/debug)

```bash
$HOME/work/macos-automation/sd-import status
$HOME/work/macos-automation/sd-import status --job-id 20260303-005507 --follow
$HOME/work/macos-automation/sd-import status --follow --json
```

Progress JSON path:

- `~/.sd-import/progress/<job_id>.json`

### Debug jobs

```bash
$HOME/work/macos-automation/sd-import list-mounts --json
$HOME/work/macos-automation/sd-import list-jobs
$HOME/work/macos-automation/sd-import show-job --job-id 20260303-005507
```

### Prune old history (retention)

Prunes `jobs` and `job_files` older than N days, plus their report files in `~/.sd-import/reports/`.
It does **not** prune `items` (dedupe fingerprints), so dedupe history is preserved.

```bash
$HOME/work/macos-automation/sd-import prune --days 180 --dry-run
$HOME/work/macos-automation/sd-import prune --days 180 --vacuum
```

## launchd auto-run on SD insert

`install.sh` already installs launchd for you.
Template plist (for reference): `$HOME/work/macos-automation/launchd/com.xcv58.sd-import.plist`
The reference plist contains `/Users/YOUR_USER/...` placeholders because launchd requires absolute paths and does not expand `$HOME`.

Install:

```bash
mkdir -p ~/Library/LaunchAgents
sed "s|/Users/YOUR_USER|$HOME|g" \
  "$HOME/work/macos-automation/launchd/com.xcv58.sd-import.plist" \
  > ~/Library/LaunchAgents/com.xcv58.sd-import.plist
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

- `$HOME/work/macos-automation/raycast-extension`
- Import with Raycast `Import Extension` and point to that folder.
- Includes commands:
  - `SD Import Auto`
  - `SD Import Select Volume` (manual volume picker)
  - `SD Import Retry Latest`
  - `SD Import Jobs`

## Alfred

Use `$HOME/work/macos-automation/alfred/sd-import-auto.sh` in a Script Filter / Run Script workflow.

## Suggested additional features

- import policy by card serial/volume UUID (different destinations per card)
- quarantine mode: copy new files to staging, review, then promote
- checksum manifest export (`job_id.manifest.csv`) for audit trail
- optional webhook/Slack summary after each job
- conflict policy options: `skip` / `rename-copy` / `prompt`

## Tests

```bash
cd $HOME/work/macos-automation
python3 -m unittest discover -s tests -v
```
