#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOLUME_PATH=""
SCENARIO=""
OUTPUT_PATH=""

usage() {
  cat <<'USAGE'
usage: ./script/capture_manual_card_qa.sh --volume /Volumes/CARD --scenario "Canon photo card" [--output /tmp/sdimport-card-qa.md]

Captures a privacy-preserving manual QA evidence report for a mounted camera
card. The report contains environment metadata, filesystem metadata, extension
counts, category counts, and manual result fields to fill in after using the app.

The report intentionally omits file names, full file paths, and media contents.

Options:
  --volume PATH       Mounted card/source volume to inspect. Required unless one
                      non-system /Volumes entry is present.
  --scenario TEXT     Manual QA matrix scenario name.
  --output PATH       Write the report to PATH instead of stdout.
  -h, --help          Show this help.
USAGE
}

fail() {
  echo "capture_manual_card_qa: $*" >&2
  exit 1
}

discover_volumes() {
  local candidate
  shopt -s nullglob
  for candidate in /Volumes/*; do
    [[ -e "$candidate" ]] || continue
    [[ -L "$candidate" ]] && continue
    [[ "$(basename "$candidate")" == ".timemachine" ]] && continue
    [[ -d "$candidate" ]] || continue
    printf '%s\n' "$candidate"
  done
  shopt -u nullglob
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volume)
      [[ $# -ge 2 ]] || fail "--volume requires a path"
      VOLUME_PATH="$2"
      shift 2
      ;;
    --scenario)
      [[ $# -ge 2 ]] || fail "--scenario requires text"
      SCENARIO="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a path"
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

if [[ -z "$VOLUME_PATH" ]]; then
  discovered=()
  while IFS= read -r discovered_volume; do
    discovered+=("$discovered_volume")
  done < <(discover_volumes)
  if [[ ${#discovered[@]} -eq 1 ]]; then
    VOLUME_PATH="${discovered[0]}"
  elif [[ ${#discovered[@]} -eq 0 ]]; then
    fail "no mounted card volumes found under /Volumes; pass --volume after mounting a card"
  else
    printf 'capture_manual_card_qa: multiple candidate volumes found:\n' >&2
    printf '  %s\n' "${discovered[@]}" >&2
    fail "pass --volume explicitly"
  fi
fi

[[ -d "$VOLUME_PATH" ]] || fail "volume path is not a directory: $VOLUME_PATH"

if [[ -n "$OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  exec > "$OUTPUT_PATH"
fi

volume_basename="$(basename "$VOLUME_PATH")"
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
macos_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
macos_build="$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
mac_model="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
architecture="$(uname -m 2>/dev/null || echo unknown)"
app_info="$ROOT_DIR/dist/SD Import.app/Contents/Info.plist"
app_version="not built"
app_build="not built"

if [[ -f "$app_info" ]]; then
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_info" 2>/dev/null || echo unknown)"
  app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_info" 2>/dev/null || echo unknown)"
fi

diskutil_info="$(diskutil info "$VOLUME_PATH" 2>/dev/null || true)"

disk_value() {
  local key="$1"
  printf '%s\n' "$diskutil_info" | awk -F: -v key="$key" '
    index($1, key) {
      value = $0
      sub("^[^:]*:[[:space:]]*", "", value)
      print value
      exit
    }
  '
}

volume_name="$(disk_value "Volume Name")"
filesystem="$(disk_value "File System Personality")"
protocol="$(disk_value "Protocol")"
device_location="$(disk_value "Device Location")"
removable="$(disk_value "Removable Media")"
total_size="$(disk_value "Total Size")"
free_space="$(disk_value "Free Space")"
volume_name_summary="unknown"
if [[ -n "$volume_name" ]]; then
  volume_name_summary="redacted (${#volume_name} chars)"
fi

cat <<REPORT
# SD Import Manual Card QA Capture

- captured: \`$timestamp\`
- scenario: ${SCENARIO:-"(fill in)"}
- volume: \`/Volumes/<redacted>\`
- volume name length: ${#volume_basename}
- app version/build: \`$app_version ($app_build)\`
- macOS: \`$macos_version ($macos_build)\`
- Mac model: \`$mac_model\`
- architecture: \`$architecture\`

## Volume Metadata

- volume name from diskutil: $volume_name_summary
- filesystem: ${filesystem:-unknown}
- protocol: ${protocol:-unknown}
- device location: ${device_location:-unknown}
- removable media: ${removable:-unknown}
- total size: ${total_size:-unknown}
- free space: ${free_space:-unknown}

REPORT

find "$VOLUME_PATH" -type f -print0 2>/dev/null | /usr/bin/perl -0ne '
BEGIN {
  @photo = qw(.jpg .jpeg .jpe .heic .heif .tif .tiff .dng .arw .cr2 .cr3 .nef .raf .rw2 .orf .srw .pef .rwl .3fr .fff .iiq);
  @raw = qw(.dng .arw .cr2 .cr3 .nef .raf .rw2 .orf .srw .pef .rwl .3fr .fff .iiq);
  @jpeg = qw(.jpg .jpeg .jpe);
  @video = qw(.mov .mp4 .m4v .mts .m2ts .avi .mpg .mpeg .wmv);
  @sidecar = qw(.xml .xmp .bin .thm .lrv .srt .aae .dat .bup .insv);
  %photo = map { $_ => 1 } @photo;
  %raw = map { $_ => 1 } @raw;
  %jpeg = map { $_ => 1 } @jpeg;
  %video = map { $_ => 1 } @video;
  %sidecar = map { $_ => 1 } @sidecar;
}
chomp;
$total_files++;
$bytes += -s $_ if -f $_;

my $ext = "<none>";
$ext = lc($1) if /(\.[^\.\/]+)$/;
$ext_count{$ext}++;

my @parts = split(/\//, $_);
my $base = lc($parts[-1] // "");
my $dir = join("/", @parts[0..$#parts-1]);
my $stem = $base;
$stem =~ s/\.[^.]+$//;

$base_count{$base}++ if $base ne "";
$photo_count++ if $photo{$ext};
$raw_count++ if $raw{$ext};
$jpeg_count++ if $jpeg{$ext};
$video_count++ if $video{$ext};
$sidecar_count++ if $sidecar{$ext};
$sony_media_pro++ if $base eq "mediapro.xml";
$sony_database++ if $base eq "database.bin";

my $pair_key = $dir . "\0" . $stem;
$pair{$pair_key}{raw} = 1 if $raw{$ext};
$pair{$pair_key}{jpeg} = 1 if $jpeg{$ext};

END {
  for my $name (keys %base_count) {
    $duplicate_names++ if $base_count{$name} > 1;
  }
  for my $key (keys %pair) {
    $raw_jpeg_pairs++ if $pair{$key}{raw} && $pair{$key}{jpeg};
  }

  print "## Card Content Summary\n\n";
  printf "- total files scanned: %d\n", $total_files || 0;
  printf "- total bytes scanned: %d\n", $bytes || 0;
  printf "- photo-like files: %d\n", $photo_count || 0;
  printf "- raw-like files: %d\n", $raw_count || 0;
  printf "- jpeg-like files: %d\n", $jpeg_count || 0;
  printf "- video-like files: %d\n", $video_count || 0;
  printf "- sidecar/index-like files: %d\n", $sidecar_count || 0;
  printf "- duplicate basename groups: %d\n", $duplicate_names || 0;
  printf "- raw+jpeg basename pairs: %d\n", $raw_jpeg_pairs || 0;
  printf "- Sony MEDIAPRO.XML count: %d\n", $sony_media_pro || 0;
  printf "- Sony DATABASE.BIN count: %d\n", $sony_database || 0;
  print "\n## Extension Counts\n\n";
  print "| Extension | Count |\n";
  print "| --- | ---: |\n";
  for my $ext (sort { $ext_count{$b} <=> $ext_count{$a} || $a cmp $b } keys %ext_count) {
    printf "| %s | %d |\n", $ext, $ext_count{$ext};
  }
}
'

cat <<'REPORT'

## Manual App QA Results

- Import path: automatic prompt / manual scan:
- Preview new files:
- Preview known files:
- Preview sidecars/skipped:
- Preview conflicts:
- Destination preview correct:
- Import result imported:
- Import result skipped:
- Import result failed:
- Rescan known-file behavior:
- Crash report or diagnostics export path, if relevant:
- Pass/fail:
- Notes:

## Privacy Check

- Confirm this report contains no media files:
- Confirm this report contains no file names:
- Confirm this report contains no full source or destination paths:
REPORT
