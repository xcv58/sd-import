# Website maintenance

The public site is static HTML in `docs/`. Its main product is **SD Card Import**
from the Mac App Store. All public installation and update links point to that
listing, apart from the unlisted TestFlight invitation page described below.
GitHub is linked only for source code, licensing, and issue reporting.

Edit `website/templates/` for structure and `website/locales/` for copy. The same
seven pages are available in English, Simplified and Traditional Chinese,
Japanese, Korean, German, French, Spanish, Brazilian Portuguese and Italian.
English URLs remain at the root; translated pages use a locale directory.

The unlisted TestFlight invitation is available at `/beta` (rewritten to
`beta.html`) with matching pages in all ten languages. Edit
`website/templates/beta.html` and its `beta.*` catalog messages, then regenerate.
These pages have `noindex, nofollow, noarchive` metadata and hosting headers.
They stay out of public navigation and the sitemap. This is an unlisted page,
not a password-protected page; anyone with its URL can open it.

The public TestFlight link is recorded as `TESTFLIGHT` in the generator and in
the template's join button; the checker requires them to match. Before changing
the link, verify the app, external build approval, and enrollment availability
in App Store Connect. An internal-only cloud build does not update the public
beta group.

```sh
python3 script/build_website.py
python3 script/check_website.py
node --test website/settings.test.cjs
```

Generated pages and the sitemap are committed, so hosting needs no build step.
The checker fails on stale output, missing messages, altered placeholders,
untranslated template or token text, broken local links and changed badge bytes.

Message IDs are stable. `units.json` maps placeholders to inline HTML tags.
Visible button text and app-command names belong in the locale catalogs, even
inside links or code formatting. Only explicitly listed paths, filenames,
email addresses, keyboard shortcuts and decorative symbols may be opaque tokens.
Translators may reorder numbered placeholders but must preserve their pairing;
HTML supplied as translation text is escaped. File paths, keyboard shortcuts,
product names and original screenshots remain unchanged. Add new visible text
and accessibility labels to every catalog, then regenerate and check all pages.
Screenshots and the silent demo show the original English app UI; their captions,
transcript, alternative text and playback controls are localized.

The product gallery and social preview use the versioned `20261023` images
from the local version 1.1.1 development capture. The preview and plan show the
current trial action; the purchase sheet includes Apple authentication guidance.
`docs/review-assets/release-1.1.1/` preserves the original native windows,
App Store compositions, capture provenance, and SHA-256 manifest. The purchase
capture uses sample StoreKit product metadata. Older workflow images in the
video section remain labeled as captures from earlier versions. Never edit
screenshots to manufacture newer app controls. Previously published immutable
assets remain available at their original filenames.

The language menu is native HTML and works without JavaScript. With JavaScript,
explicit selection wins, followed by the localized URL, saved preference and
browser languages, with English as the fallback. English navigation includes
`?lang=en` so the choice still works when browser storage is unavailable.
The theme follows the system until the single toggle is used; it remembers the
choice when storage is available and remains usable when storage is denied.

For browser regression checks, serve `docs/` locally, install `agent-browser@0.37.1`
in an isolated tool directory, and run:

```sh
python3 -m http.server 8769 --bind 127.0.0.1 --directory docs
# In another terminal:
AGENT_BROWSER_BIN=/path/to/agent-browser \
  python3 website/browser-check.py http://127.0.0.1:8769 /tmp/sd-import-browser-check
```

The check creates and closes its own browser session. It covers all 70 pages,
phone and desktop layouts, language navigation, storage denial, theme persistence,
keyboard controls, gallery/video interaction and the fallback without scripts.
Native-speaker review of translations remains useful, particularly for legal copy.

Apple's badge files are unmodified downloads from its official marketing toolbox.
`apple-badges.json` records the source URLs and SHA-256 values. Traditional Chinese
uses Apple's `zh-hk` Mac badge (the `zh-tw` Mac endpoint is unavailable). Follow
[Apple's marketing guidelines](https://developer.apple.com/app-store/marketing/guidelines/):
keep the artwork unchanged, at least 40 pixels high, with quarter-height clear space.
The site displays one badge per page at 48 pixels high with 12 pixels of padding.

Assets are cached as immutable for a year. Publish changed CSS, JavaScript and
media at new versioned filenames; do not overwrite previously published assets.

The website demo is 20 seconds. `screencast-edit.json` records its source/output
hashes, source frame ranges (end exclusive), and reproducible FFmpeg filter.
It removes idle holds while preserving recorded clicks, scanning, and copying
at their original speed, then holds the existing receipt for about two seconds.
The original 28-second MP4 remains available. To reproduce a separate preview:

```sh
python3 - <<'PY'
import json, subprocess
from pathlib import Path
edit = json.loads(Path('website/screencast-edit.json').read_text())
subprocess.run(['ffmpeg', '-n', '-i', edit['source'], '-filter_complex',
                edit['filter_complex'], *edit['encoder_arguments'],
                '/tmp/sd-import-demo-preview.mp4'], check=True)
PY
```

After editing the demo, update its three duration messages (`m016`, `m052`,
`m063`) in every catalog, the English template, the edit record, and the browser
duration/ending checks, then regenerate the site.

The shared header keeps one vertically centered desktop row and appearance at
the physical top right in compact layouts. At 1050 pixels or below, or whenever
the full navigation no longer fits, an accessible menu opens the existing links
and native language picker. Without the menu script those links stay visible.
Current header assets are `header-alignment-20261016.css` and
`header-alignment-20261016.js`; older immutable assets stay intact.
