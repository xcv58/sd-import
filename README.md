# SD Import for macOS

SD Import is a free, open-source macOS app for copying photos and videos from
SD cards into dated folders. It remembers files it has already imported, so
inserting the same card again only imports new content.

## Install The Native App

GitHub Releases are the canonical public distribution path. Download the latest
signed and notarized DMG here:

https://github.com/xcv58/sd-import/releases/latest/download/SD-Import.dmg

Requirements:

- Apple Silicon Mac.
- macOS 14 or newer.

Install:

1. Download `SD-Import.dmg`.
2. Open it.
3. Drag `SD Import.app` to `Applications`.
4. Open `SD Import` and choose your photo/video destination folders in Settings.

SD Import uses Sparkle for in-app updates. To verify you are on the latest
release, choose `SD Import > Check for Updates...` or compare your installed
version with the latest GitHub Release:

https://github.com/xcv58/sd-import/releases/latest

Full user instructions are in [docs/user-guide.md](docs/user-guide.md). Privacy
details are in [docs/privacy.md](docs/privacy.md).

## Support

- Public support and bug reports: GitHub Issues.
- Support email: [i@xcv58.com](mailto:i@xcv58.com).
- Security reports: see [SECURITY.md](SECURITY.md).
- Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
- License: MIT, see [LICENSE](LICENSE).
- Website: [docs/index.html](docs/index.html).

Please do not attach private photos, videos, full card dumps, credentials, or
unredacted logs to public issues.

## Native App Development

The native app lives under `SDImport/` and shares its core logic through the
Swift package in `SDImport/Packages/SDImportCore`.

Common local commands:

```bash
./script/build_and_run.sh build
./script/build_and_run.sh test
./script/package_dmg.sh
```

Public releases use the Developer ID, notarization, GitHub Release, and Sparkle
flow documented in [docs/sdimport-release-runbook.md](docs/sdimport-release-runbook.md).
The native public release path does not include Homebrew, the App Store, paid
licensing, or payment infrastructure.

Production-readiness docs:

- [Support](docs/support.md)
- [Diagnostics](docs/diagnostics.md)
- [EULA](docs/eula.md)
- [Refund policy](docs/refund-policy.md)
- [Manual QA matrix](docs/manual-qa-matrix.md)

## Legacy Python Automation

This repo provides a deterministic SD-card importer with:

- auto trigger on mount (`launchd` + `StartOnMount`)
- interactive actionable dialogs via `swiftDialog`
- dedupe with SQLite (`~/.sd-import/state.db`) by metadata fingerprint (`size + mtime`)
- destination folders grouped by capture date (EXIF/QuickTime/metadata, fallback to mtime)
- live copy progress state in `~/.sd-import/progress/<job_id>.json`
- preview report before import
- manual CLI trigger for debug/retry
- Raycast extension
- one canonical launcher script (`$HOME/work/sd-import/sd-import`)

## Internal Architecture

`sd_import.py` is now a thin CLI/orchestration layer. Core behavior is split into:

- `sd_import_modules/db.py` - SQLite schema, mount discovery, job state
- `sd_import_modules/scan.py` - file scan, metadata capture-date extraction, report generation
- `sd_import_modules/importer.py` - copy/retry pipeline, progress state, dedupe-safe destination resolve
- `sd_import_modules/ui.py` - `swiftDialog` prompts/preview/progress window integration
- `sd_import_modules/common.py` - shared utility functions (IDs, JSON IO, formatting)

This keeps future UI work separate from import correctness logic.

## Why this solves your "yesterday + today" case

Imported files are tracked by metadata fingerprint (`size + mtime`), not folder path.

If you rename/delete destination folders or edit in Lightroom, re-inserting the same card will still skip yesterday's originals (same fingerprint) and import only new content.

Folder naming:

- photos: `~/Pictures/Photos/YYYY-MM-DD <location>/`
- videos: `~/Downloads/YYYY-MM-DD <location>/`
- if photo and video roots are the same: `YYYY-MM-DD <location>-Photos/` and `YYYY-MM-DD <location>-Video/`

`YYYY-MM-DD` is taken from capture date metadata when available (EXIF/QuickTime/Spotlight), with mtime as fallback.

## Legacy Python Install

This installs the older local automation stack, not the native public macOS app.
For normal users, install the signed DMG from GitHub Releases instead.

One-line install from this repo:

```bash
cd $HOME/work/sd-import && ./install.sh
```

Optional: include Raycast extension import prompt:

```bash
cd $HOME/work/sd-import && ./install.sh --with-raycast
```

Optional: custom destination roots:

```bash
cd $HOME/work/sd-import && ./install.sh \
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
  "default_location": "Untitled",
  "location_by_volume": {
    "EOS_DIGITAL": "SF"
  },
  "ignore_volume_regex": "Time Machine|Backup|Recovery|Preboot|Macintosh HD"
}
```

Smoke test manually:

```bash
$HOME/work/sd-import/sd-import run \
  --input /Volumes/YOUR_SD_CARD \
  --location NYC \
  --notify
```

## Interactive notification flow

On mount (or manual `run`), the flow is:

1. `Skip` / `Scan This Card` prompt.
2. Scan + preview summary (`new/known/conflicts/unsupported`).
3. Optional import with live copy progress, then `Dismiss`.

Safety:

- Known files are never copied again (dedupe gate).
- Duplicate mount events are debounced (20s default).
- If no prompt response, the run exits as `no_response_or_timeout`.

Performance note:

- Dedupe now uses a lightweight metadata fingerprint (`size + mtime`) instead of full content hashing.
- Capture-date extraction uses batched `exiftool` reads during scan (instead of per-file calls) to keep prepare stage faster.
- This keeps scan/import fast, but is less strict than full-file SHA-256 dedupe.

## Daily usage (recommended)

Typical flow after install:

- Keep `launchd` enabled and just insert SD cards.
- Use Raycast for manual control (`SD Import Auto`, `SD Import Select Volume`, `SD Import Retry Latest`, `SD Import Jobs`).
- Use CLI only for debugging or recovery.

## launchd auto-run on SD insert

`install.sh` installs and enables launchd automatically.
If needed, toggle manually:

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

- `$HOME/work/sd-import/raycast-extension`
- Import with Raycast `Import Extension` and point to that folder.
- Includes commands:
  - `SD Import Auto`
  - `SD Import Select Volume` (manual volume picker)
  - `SD Import Retry Latest`
  - `SD Import Jobs`

## CLI (debug/recovery)

```bash
$HOME/work/sd-import/sd-import auto
$HOME/work/sd-import/sd-import retry-latest
$HOME/work/sd-import/sd-import list-jobs
$HOME/work/sd-import/sd-import show-job --job-id <JOB_ID>
$HOME/work/sd-import/sd-import status --job-id <JOB_ID> --follow
```

## Tests

```bash
cd $HOME/work/sd-import
python3 -m unittest discover -s tests -v
```
