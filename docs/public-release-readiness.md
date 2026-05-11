# Public Release Readiness Audit

This audit tracks what must be true before SD Import is promoted as a free,
open-source public release.

## Current Release Position

- Distribution path: GitHub Releases with signed/notarized `SD-Import.dmg`.
- Updates: Sparkle appcast hosted as a GitHub Release asset.
- Price/licensing: free, open source under the MIT License.
- Native app support target: Apple Silicon Macs on macOS 14 or newer.
- Unsupported paths for now: Homebrew distribution, App Store distribution,
  payments, subscriptions, and license checks.

## Ready Enough For First Public Release

- Developer ID release scripts exist for packaging, notarization, stapling,
  Sparkle appcast generation, and GitHub Release publication.
- Sparkle is wired into the app and disabled in local builds unless feed URL and
  public EdDSA key are present.
- User install docs point to the latest GitHub Release DMG.
- The app copies from cards and selected folders without mutating source files.
- Import behavior has Swift package tests for scanning, planning, dedupe,
  persistence, recovery, path validation, and workflow recommendations.
- Opt-in diagnostics export is available from the Diagnostics screen and omits
  media files, file names, and full paths.
- A static website under `docs/` covers install, updates, support, privacy,
  EULA, and refund policy.

## Gaps To Keep Visible

### Support Policy

Status: documented.

GitHub issues are the public support path, with support email
`i@xcv58.com`. The project should keep support expectations modest: best-effort
help for the latest release, with security reports handled privately.

Next action: after the first public release, add issue labels or saved replies
for unsupported cards, update failures, destination permission failures, and
duplicate-import reports if volume grows.

### Privacy And Security Posture

Status: acceptable for a free local utility if the privacy policy remains true.

The app has no automatic telemetry or crash upload. Sparkle update checks are
the expected network use. Diagnostics export is opt-in and redacted. The
Diagnostics screen can reveal the local crash-report folder or export the latest
local SD Import crash report for opt-in support sharing.
Credentials and Sparkle private keys must remain outside git and outside GitHub
Actions.

Next action: revisit the privacy policy before adding any automatic collection,
crash upload, or telemetry. Any collection must be opt-in and documented.

### Crash And Diagnostics Strategy

Status: basic but usable for a first public release.

Users can report issues through GitHub or email and may choose what logs,
screenshots, diagnostics, or crash reports to share. The app has a Diagnostics
view with a redacted diagnostics export, local crash-report folder reveal, and
latest local crash-report export. Automatic crash upload remains intentionally
unimplemented.

### Onboarding Gaps

Status: improved, with remaining risk around first-run permissions.

The first-run sheet explains source, destinations, known/skipped files, and
sidecars. The app asks for destinations and supports security-scoped bookmarks,
but public users may still need clearer recovery when a destination bookmark
becomes stale or an SD card disappears during scan/import.

Next action: manually test first launch on a clean macOS user account and record
permission prompts, destination repair behavior, and card-removal behavior.

### Camera And Card Compatibility

Status: fixture-backed for key behaviors. Broad hardware validation is accepted
as a release risk because physical cards are unavailable for this pass.

Current supported extensions include common JPEG/HEIF/raw photo formats,
including Canon CR2/CR3, Sony ARW, Nikon NEF, and Fujifilm RAF, plus common
video containers. Real-world cameras can use different sidecar layouts, preview
JPEG patterns, card filesystems, and reader behavior.

Release decision: do not claim broad camera-card compatibility from this pass.
The hardware compatibility matrix in `docs/manual-qa-matrix.md` remains the
future evidence path when physical cards are available. For this release-prep
pass, fixture and synthetic coverage are the available validation.

- Canon photo card with JPEG/CR2 workflow coverage, and a separate CR3 sample
  if CR3 support is added.
- Sony video card with `MEDIAPRO.XML`/`DATABASE.BIN` index files.
- Nikon photo card with NEF files.
- Fujifilm photo card with RAF files.
- exFAT SDXC card through an external card reader.
- Card removal during scan and during import.

### Release Automation Fragility

Status: improved local-release foundation, still reliant on one release Mac.

The supported release path intentionally keeps signing, notarization, and
Sparkle private-key material off GitHub Actions. That reduces secret exposure
but makes release success dependent on local Keychain state, installed Xcode
tools, GitHub CLI auth, and Sparkle key availability. `script/release_preflight.sh`
checks these dependencies before packaging and warns about signed-commit prompt
risk.

Next action: run the release checklist for each release and keep a private
backup of the Sparkle key and Developer ID recovery process.
