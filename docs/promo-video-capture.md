# SD Import Promo Video Capture

This runbook keeps website demo recordings repeatable across app builds while
preserving a genuine macOS interaction: one native pointer, real pointer motion,
real progress, and click rings added only at genuine clicks.

## Fixed creative direction

- Target: SD Import website.
- Length: about 30-40 seconds.
- Output: H.264 MP4, 1920 pixels wide, 60 fps, `yuv420p`, fast-start enabled.
- Source card: the dedicated removable volume named `Sample Card` only.
- Never use `Sandisk 4T`.
- Source media: the isolated synthetic fixture only.
- Destination: `/Users/Shared/SD Import Library`, authorized through the macOS
  folder picker.
- Shoot name: `Sample Shoot`.
- Pointer: record the real macOS pointer and its complete movement. Keep any UI
  automation pointer outside the retained crop.
- Click treatment: a subtle Apple-blue ring around each genuine click, added in
  post-production.

## Storyboard and pacing

| Target time | Story beat | Maximum static hold |
| --- | --- | ---: |
| 0-3s | Fresh app/desktop state; inserting the card wakes SD Import | 2s |
| 3-7s | Permission prompt; pointer moves to **Allow Scan** | 2s |
| 7-11s | Genuine scan progress | none |
| 11-15s | Review shows `Sample Shoot`, 27 files, size, and destination | 3s |
| 15-28s | Pointer clicks Import; genuine copy progress remains continuous | none |
| 28-34s | Successful receipt | 3s |
| 34-40s | Pointer moves to Eject, clicks it, and successful ejection appears | 3s |

Remove idle waits longer than three seconds. Do not replace real scan/copy
progress with checkpoint stills, and do not cut backward from a receipt to a
previous review state.

## One-time local preparation

The large reusable fixture intentionally lives outside Git:

```text
~/Pictures/SD Import Capture Fixture/
  .sdimport-promo-fixture
  Photos/
  Videos/
```

Validate it and create the realistic destination before inserting the card:

```bash
./script/prepare_promo_capture.sh --local-only
```

The fixture currently contains 24 synthetic photos and 3 synthetic videos,
about 1 GB total. It is separate from the import destination.

## Prepare a fresh card source

After mounting the dedicated test card, create a new run-specific source:

```bash
./script/prepare_promo_capture.sh \
  --volume "/Volumes/Sample Card" \
  --collection "Coastal Weekend" \
  --first-photo 25 --first-video 4 \
  --run-id "capture-audit-01"
```

The script:

- refuses `Sandisk 4T` and any volume not mounted at `/Volumes/Sample Card`;
- requires the volume to be reported as removable;
- creates a new `Coastal Weekend/Sample Card/DCIM/100SAMPLE` directory;
- never deletes or overwrites existing card contents;
- copies 24 synthetic photos and 3 synthetic videos as `PHOTO_0025.JPG`
  through `PHOTO_0048.JPG` and `VIDEO_0004.MOV` through `VIDEO_0006.MOV`;
- writes a SHA-256 source manifest under the system temporary directory.

Use the printed directory ending in `Sample Card` as the app's source. Choose a
new human-readable collection and unused photo/video numbers for every retake,
so the preview starts with new files while retaining import history and existing
card contents. The run ID is used only for the audit manifest outside the card;
it must never appear in the app. Verify the dedicated card's volume UUID against
the current capture preflight before running the preparation script.

## App preflight before recording

1. Verify the installed app build and quit any other SD Import copy.
2. Select `/Users/Shared/SD Import Library` through the macOS folder picker. Do not
   type or inject the path directly; the Mac App Store build needs a real
   security-scoped bookmark.
3. Set **Photos + Videos**, **Same Library**, **By Capture Date**, and
   `Sample Shoot`, then choose **Use as Defaults**.
4. Select the new run-specific source without scanning it.
5. Return to a clean source-ready state, safely eject `Sample Card`, and quit the
   main app. Do not clear import history or other user data.
6. Confirm the background helper is running so physical insertion can wake the
   app.

This preflight may require one setup insertion followed by a physical
remove/reinsert for the final recording.

Use the shared destination consistently in review, copying, receipt, and video.
It contains no account name and works with the installed App Store build's
existing path display. Preserve previous capture imports in the user's Pictures
directory; a retake does not require moving or deleting them.

## Screenshot capture

Capture permission, active scanning, review, copying, receipt followed by safe
eject, and optionally a Nothing New rescan directly from the app window. Use
one fixed window size and light appearance. For example, after reading the
current main-window ID:

```bash
screencapture -x -o -l "$WINDOW_ID" /private/tmp/sd-import-window.png
```

Do not extract final screenshots from the video. Native PNGs must retain real
transparent corners and exclude the cursor. Verify full-resolution content and
all four corners, then create separate opaque 2560x1600 App Store compositions
on a consistent neutral background. A modal permission sheet may genuinely
disable the red close control; preserve that state.

Computer Use can place a purple remote-control indicator over the traffic
lights. A capture containing it is provisional. Excluding attached windows,
AX Raise, zoom, or single-window CoreGraphics capture did not remove it in the
September 5 session. Physical foreground activation did. Resolve this before a
retained video take; do not paint traffic lights over the indicator or replace
the title bar with another frame.

## Native recording

### Select the capture display

Display numbers can change when a monitor is connected, disconnected, or made
the main display. Calibrate immediately before every take:

```bash
screencapture -D 1 /private/tmp/sd-import-display-1.png
screencapture -D 2 /private/tmp/sd-import-display-2.png
sips -g pixelWidth -g pixelHeight /private/tmp/sd-import-display-*.png
```

Open the calibration images and identify the display containing the SD Import
window. Pass that display number explicitly with `-D`; do not rely on whichever
display macOS currently considers the main display. Recalibrate after any
display-arrangement change.

If an external display causes the helper-launched app to reopen on a different
display, either move the app and verify its restored placement after a complete
quit/relaunch or disconnect the external display for the take. The known-good
Build 5 capture used the built-in Retina display as the sole display
(`3024 x 1964`), which macOS numbered as display 1:

Use a bounded native capture and include the hardware insertion, app wake,
permission prompt, scan, review, copy, receipt, and eject in one continuous raw
take whenever possible:

```bash
screencapture -v -C -D 1 -V 120 /private/tmp/sd-import-promo-raw.mov
```

Record pointer movement at a natural pace. Pause briefly over each target before
clicking. Keep the native pointer on the recorded display before capture begins.
Do not use simulated pointer artwork or checkpoint screenshots.

## Post-production

First inspect the raw take and note the source ranges worth retaining. A keep
range may optionally end with a playback-speed multiplier, such as
`18.0:24.0:1.5`; this time-compresses slow pointer travel while retaining the
decoded frames. Specify click markers in the edited-output timeline and
output-pixel coordinates:

```bash
./script/postprocess_promo_capture.sh \
  --input /private/tmp/sd-import-promo-raw.mov \
  --output /private/tmp/sd-import-promo-preview.mp4 \
  --keep 2.0:15.0 \
  --keep 18.0:24.0:1.5 \
  --keep 24.0:46.0 \
  --click 4.8:1143:615 \
  --click 16.2:1784:42 \
  --click 36.0:1710:149
```

The example times are illustrative; measure every new raw take. The processor
crops 67 Retina pixels from the top by default, removing the macOS menu bar
while preserving the app title bar and window controls. It scales with Lanczos,
preserves 60 fps, overlays 72-pixel click rings, decodes the complete result to
detect errors, and prints final stream metadata.

The known-good Build 5 take used these source ranges after trimming the opening
hold to 1.5 seconds:

```bash
./script/postprocess_promo_capture.sh \
  --input /private/tmp/sd-import-promo-raw-take5.mov \
  --output /private/tmp/sd-import-promo-preview-take5.mp4 \
  --keep 2767.3:2775 \
  --keep 2818:2823.5:1.5 \
  --keep 2823.5:2837:1.25 \
  --keep 2864.5:2869:1.5 \
  --keep 2869:2873 \
  --click 1.5:1142:666 \
  --click 11.3:1795:91 \
  --click 24.8:516:416
```

## Review gate

Before touching website assets:

1. Inspect a full-resolution frame from every story beat.
2. Inspect frames immediately before, during, and after every click ring.
3. Confirm there is exactly one pointer throughout.
4. Confirm `Sample Shoot` and the realistic destination are visible.
5. Confirm scan and copy progress are continuous rather than still-frame jumps.
6. Confirm the receipt transitions forward into the eject action.
7. Show the `/private/tmp` preview to the user and wait for approval.

Only after approval should the preview replace website media or be committed.

## September 5 capture findings

The review package uses the original installed Mac App Store edition, version
1.0 build 5, with `/Users/Shared/SD Import Library` as the authorized destination.
Native screenshots are 3024×1896 with transparent corners. Separate 2560×1600
App Store compositions place them on `#F2F3F5` with a 2360×1480 maximum inner size.
Keep original PNG bytes; never repaint the title bar or controls. A permission
sheet legitimately disables the red close button.

For the fixed window at `(0, 34, 1512, 948)` points, region recording preserves
the genuine title bar without the extra shadow and sharing indicator observed
with window-video capture:

```bash
screencapture -v -C -R0,34,1512,948 -V 120 /private/tmp/sd-import-promo-raw.mov
```

Let the bounded recording finish naturally. In this environment, sending
SIGINT cancelled and discarded a recording instead of saving it. Region capture
records whatever becomes foreground, including the Dock; coordinate an idle
interval and inspect the saved frames. After Computer Use, quitting and
reopening SD Import cleared a lingering purple sharing indicator. Recheck the
selected source and its permission after reopening before starting a take.
Native input was used only after the user specifically approved that method.

The September 5 review video retains raw seconds 2–34 at normal speed and then
cuts to four seconds of separately recorded safe-eject confirmation. It includes
real card detection, permission, scan, review, copy, and receipt. The eject click
itself fell outside the saved recording, so this candidate does not satisfy the
continuous eject-action check above. Disclose that cut during review; do not
fabricate an eject click or add a highlight for it. The two genuine recorded
clicks receive short highlights at output seconds 9.0 and 17.45.

The approved website version, `sd-import-screencast-light-20260905-v2.mp4`,
retains only the first 28 seconds of that candidate and ends on the successful
copy receipt. The final eight seconds, including the separate safe-eject ending,
were removed after review. The original 36-second candidate remains preserved.

The subsequent approved website pacing edit is
`sd-import-screencast-light-20260912-20s.mp4`. It trims idle source-selection,
permission-dialog, and import-preview holds from the 28-second version, while
preserving the recorded clicks and continuous scan/copy progression at original
speed. The existing final receipt frame is extended so the successful result
remains on screen for about two seconds. It still ends on the receipt and adds
no eject action. The exact source frame ranges, hashes, and reproduction filter
are recorded in `website/screencast-edit.json`; both earlier videos are retained.

Use the native window alpha as the video's corner mask and alpha-composite onto
the neutral background. Do not use a YUV mask blend that also changes the app's
colors. Window-region inputs already exclude the menu bar; use `--crop-top 0`
with the single-input postprocessor.

The gallery also includes earlier genuine scan and dedup captures from separate
synthetic collections on Sample Card. Retain their source paths and provenance;
do not present the whole gallery as one uninterrupted import. All 27 files in
the latest import matched source SHA-256 hashes, and the actual receipt showed
zero failures. OCR omitted some lone zero glyphs, so verify receipt numbers
against the actual image before taking the next action.
