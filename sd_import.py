#!/usr/bin/env python3
"""
Deterministic SD card importer for macOS.

Features:
- Auto/mount trigger entrypoint for launchd.
- SQLite-backed dedupe by lightweight metadata fingerprint.
- Interactive actionable dialogs via swiftDialog.
- Preview reports for review before import.
- CLI commands for scan/import/retry/debug.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

VIDEO_EXTENSIONS = {".mp4", ".mov", ".avi", ".mkv"}
PHOTO_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".heif",
    ".heic",
    ".dng",
    ".raw",
    ".cr2",
    ".nef",
    ".arw",
    ".raf",
}

TERMINAL_PROGRESS_STATES = {"completed", "completed_with_errors", "failed", "aborted", "idle"}


def now_local_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def today_iso() -> str:
    return dt.date.today().isoformat()


def make_job_id() -> str:
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def atomic_write_text(path: Path, content: str) -> None:
    ensure_dir(path.parent)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(content)
    os.replace(tmp_path, path)


def write_json_atomic(path: Path, payload: Dict[str, Any]) -> None:
    atomic_write_text(path, json.dumps(payload, indent=2))


def read_json_file(path: Path) -> Optional[Dict[str, Any]]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def has_command(name: str) -> bool:
    if shutil.which(name) is not None:
        return True
    fallback_paths = [
        Path.home() / ".local" / "bin" / name,
        Path.home() / "bin" / name,
    ]
    return any(p.exists() and os.access(p, os.X_OK) for p in fallback_paths)


def metadata_fingerprint(file_size: int, mtime_iso: str) -> str:
    # Fast non-content fingerprint: stable across repeated scans of unchanged files.
    payload = f"{file_size}|{mtime_iso}"
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()


def format_bytes(num_bytes: float) -> str:
    value = float(max(0.0, num_bytes))
    units = ["B", "KB", "MB", "GB", "TB"]
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)}{unit}"
            return f"{value:.1f}{unit}"
        value /= 1024.0
    return f"{value:.1f}TB"


def format_duration(seconds: Optional[float]) -> str:
    if seconds is None:
        return "?"
    s = int(max(0, seconds))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h > 0:
        return f"{h}h{m:02d}m"
    if m > 0:
        return f"{m}m{sec:02d}s"
    return f"{sec}s"


def classify_ext(ext: str) -> Optional[str]:
    ext = ext.lower()
    if ext in VIDEO_EXTENSIONS:
        return "video"
    if ext in PHOTO_EXTENSIONS:
        return "photo"
    return None


def capture_date_from_mtime(stat_result: os.stat_result) -> str:
    return dt.datetime.fromtimestamp(stat_result.st_mtime).date().isoformat()


def _parse_date_from_text(text: str) -> Optional[str]:
    s = (text or "").strip()
    if not s or s == "(null)":
        return None

    # Matches: 2026-03-03, 2026:03:03, or datetime prefixed with those formats.
    m = re.search(r"(\d{4})[-:](\d{2})[-:](\d{2})", s)
    if not m:
        return None
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"


def capture_date_from_exiftool(file_path: Path, media_type: str) -> Optional[str]:
    if shutil.which("exiftool") is None:
        return None
    if media_type == "photo":
        tags = ["DateTimeOriginal", "CreateDate", "MediaCreateDate"]
    else:
        tags = ["MediaCreateDate", "CreateDate", "TrackCreateDate"]

    cmd = ["exiftool", "-s3", "-d", "%Y-%m-%d"] + [f"-{tag}" for tag in tags] + [str(file_path)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except Exception:
        return None
    if proc.returncode != 0:
        return None

    for line in (proc.stdout or "").splitlines():
        parsed = _parse_date_from_text(line)
        if parsed:
            return parsed
    return None


def capture_dates_from_exiftool_batch(
    media_files: List[Tuple[Path, str]],
    batch_size: int = 200,
    progress_cb: Optional[Callable[[int, int], None]] = None,
) -> Dict[str, str]:
    if shutil.which("exiftool") is None or not media_files:
        return {}

    # Use a single exiftool process per chunk instead of per file to speed up prepare stage.
    tags = ["DateTimeOriginal", "CreateDate", "MediaCreateDate", "TrackCreateDate"]
    media_type_by_path = {str(p): t for p, t in media_files}
    result: Dict[str, str] = {}

    total = len(media_files)
    done = 0
    for i in range(0, total, max(1, batch_size)):
        chunk = media_files[i : i + batch_size]
        cmd = ["exiftool", "-j", "-d", "%Y-%m-%d"] + [f"-{tag}" for tag in tags] + [str(p) for p, _ in chunk]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except Exception:
            done += len(chunk)
            if progress_cb:
                progress_cb(done, total)
            continue

        if not (proc.stdout or "").strip():
            done += len(chunk)
            if progress_cb:
                progress_cb(done, total)
            continue
        try:
            rows = json.loads(proc.stdout)
        except Exception:
            done += len(chunk)
            if progress_cb:
                progress_cb(done, total)
            continue
        if not isinstance(rows, list):
            done += len(chunk)
            if progress_cb:
                progress_cb(done, total)
            continue

        for row in rows:
            if not isinstance(row, dict):
                continue
            source = str(row.get("SourceFile") or "")
            if not source:
                continue
            media_type = media_type_by_path.get(source, "photo")
            if media_type == "photo":
                ordered_tags = ["DateTimeOriginal", "CreateDate", "MediaCreateDate", "TrackCreateDate"]
            else:
                ordered_tags = ["MediaCreateDate", "CreateDate", "TrackCreateDate", "DateTimeOriginal"]
            for tag in ordered_tags:
                parsed = _parse_date_from_text(str(row.get(tag) or ""))
                if parsed:
                    result[source] = parsed
                    break
        done += len(chunk)
        if progress_cb:
            progress_cb(done, total)

    return result


def capture_date_from_mdls(file_path: Path) -> Optional[str]:
    if shutil.which("mdls") is None:
        return None
    try:
        proc = subprocess.run(
            ["mdls", "-raw", "-name", "kMDItemContentCreationDate", str(file_path)],
            capture_output=True,
            text=True,
            check=False,
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    return _parse_date_from_text(proc.stdout)


def capture_date_for_file(file_path: Path, media_type: str, stat_result: os.stat_result) -> str:
    for candidate in (
        capture_date_from_exiftool(file_path, media_type),
        capture_date_from_mdls(file_path),
    ):
        if candidate:
            return candidate
    return capture_date_from_mtime(stat_result)


def capture_date_fallback_without_exiftool(file_path: Path, stat_result: os.stat_result) -> str:
    mdls_date = capture_date_from_mdls(file_path)
    if mdls_date:
        return mdls_date
    return capture_date_from_mtime(stat_result)


def iter_files(root: Path) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.startswith("."):
                continue
            yield Path(dirpath) / name


def load_json(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def connect_db(db_path: Path) -> sqlite3.Connection:
    ensure_dir(db_path.parent)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS items (
            hash TEXT NOT NULL,
            size INTEGER NOT NULL,
            first_seen_at TEXT NOT NULL,
            first_job_id TEXT,
            first_source_path TEXT,
            PRIMARY KEY (hash, size)
        );

        CREATE TABLE IF NOT EXISTS jobs (
            job_id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            mount_path TEXT NOT NULL,
            volume_name TEXT,
            volume_uuid TEXT,
            location TEXT,
            status TEXT NOT NULL,
            scanned_files INTEGER NOT NULL DEFAULT 0,
            new_files INTEGER NOT NULL DEFAULT 0,
            known_files INTEGER NOT NULL DEFAULT 0,
            unsupported_files INTEGER NOT NULL DEFAULT 0,
            conflict_files INTEGER NOT NULL DEFAULT 0,
            imported_files INTEGER NOT NULL DEFAULT 0,
            skipped_files INTEGER NOT NULL DEFAULT 0,
            failed_files INTEGER NOT NULL DEFAULT 0,
            report_path TEXT
        );

        CREATE TABLE IF NOT EXISTS job_files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL,
            src_path TEXT NOT NULL,
            rel_path TEXT,
            filename TEXT,
            ext TEXT,
            size INTEGER,
            mtime TEXT,
            media_type TEXT,
            hash TEXT,
            decision TEXT,
            dest_dir TEXT,
            dest_path TEXT,
            copy_status TEXT,
            error TEXT,
            UNIQUE(job_id, src_path),
            FOREIGN KEY(job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_job_files_job_decision
            ON job_files(job_id, decision, copy_status);

        CREATE INDEX IF NOT EXISTS idx_job_files_hash_size
            ON job_files(hash, size);
        """
    )
    return conn


def get_diskutil_info(path: str) -> Dict[str, Any]:
    try:
        proc = subprocess.run(
            ["diskutil", "info", "-plist", path],
            capture_output=True,
            text=False,
            check=True,
        )
        return plistlib.loads(proc.stdout)
    except Exception:
        return {}


def discover_removable_mounts(ignore_volume_regex: Optional[str]) -> List[Dict[str, Any]]:
    mounts: List[Dict[str, Any]] = []
    try:
        proc = subprocess.run(
            ["diskutil", "list", "-plist"],
            capture_output=True,
            text=False,
            check=True,
        )
        plist = plistlib.loads(proc.stdout)
    except Exception:
        return mounts

    disks = plist.get("AllDisksAndPartitions", [])
    ignore_re = re.compile(ignore_volume_regex) if ignore_volume_regex else None
    seen_mount_paths = set()

    for disk in disks:
        dev_ids: List[str] = []
        whole_dev = disk.get("DeviceIdentifier")
        if whole_dev:
            dev_ids.append(whole_dev)
        for part in disk.get("Partitions", []):
            part_dev = part.get("DeviceIdentifier")
            if part_dev:
                dev_ids.append(part_dev)

        for dev in dev_ids:
            info = get_diskutil_info(f"/dev/{dev}")
            mount_path = info.get("MountPoint")
            if not mount_path:
                continue
            if info.get("RemovableMedia") is not True:
                continue

            # Disk images should not trigger camera-card import workflows.
            bus_protocol = str(info.get("BusProtocol") or "")
            media_name = str(info.get("MediaName") or "")
            if bus_protocol == "Disk Image" or media_name == "Disk Image":
                continue

            volume_name = info.get("VolumeName") or Path(mount_path).name
            if ignore_re and ignore_re.search(volume_name):
                continue
            if mount_path in seen_mount_paths:
                continue

            try:
                mounted_at = Path(mount_path).stat().st_mtime
            except FileNotFoundError:
                continue
            if not isinstance(mounted_at, (int, float)) or mounted_at <= 0:
                mounted_at = time.time()

            mounts.append(
                {
                    "mount_path": mount_path,
                    "volume_name": volume_name,
                    "volume_uuid": info.get("VolumeUUID"),
                    "mounted_at": mounted_at,
                }
            )
            seen_mount_paths.add(mount_path)

    mounts.sort(key=lambda m: m["mounted_at"], reverse=True)
    return mounts


def choose_location(config: Dict[str, Any], requested_location: Optional[str], volume_name: Optional[str]) -> str:
    if requested_location:
        return requested_location
    mapping = config.get("location_by_volume")
    if isinstance(mapping, dict) and volume_name and volume_name in mapping:
        return str(mapping[volume_name])
    return str(config.get("default_location", "TODO"))


def make_photo_dest_dir(photos_base: Path, capture_date: str, location: str) -> Path:
    safe_location = location.strip() or "TODO"
    return photos_base / f"{capture_date} {safe_location}"


def make_video_dest_dir(videos_base: Path, capture_date: str) -> Path:
    return videos_base / f"tmp-{capture_date}-videos"


def write_report(report_path: Path, summary: Dict[str, Any], files: List[Dict[str, Any]]) -> None:
    ensure_dir(report_path.parent)
    payload = {"summary": summary, "files": files}
    report_json = report_path.with_suffix(".json")
    report_md = report_path.with_suffix(".md")

    report_json.write_text(json.dumps(payload, indent=2))

    lines = [
        f"# SD Import Report {summary['job_id']}",
        "",
        f"- mount: `{summary['mount_path']}`",
        f"- volume: `{summary.get('volume_name') or ''}`",
        f"- location: `{summary.get('location') or ''}`",
        f"- scanned: `{summary['scanned_files']}`",
        f"- new: `{summary['new_files']}`",
        f"- known: `{summary['known_files']}`",
        f"- unsupported: `{summary['unsupported_files']}`",
        f"- conflicts: `{summary['conflict_files']}`",
        "",
        "## New Files",
        "",
    ]

    for row in files:
        if row["decision"] != "NEW":
            continue
        lines.append(f"- `{row['src_path']}` -> `{row.get('dest_path') or row.get('dest_dir')}`")

    lines.append("")
    lines.append("## Conflicts")
    lines.append("")
    any_conflict = False
    for row in files:
        if row["decision"] != "CONFLICT":
            continue
        any_conflict = True
        lines.append(f"- `{row['src_path']}` ({row.get('error') or 'conflict'})")
    if not any_conflict:
        lines.append("- none")

    report_md.write_text("\n".join(lines))


def existing_hash_matches(path: Path, expected_hash: str, expected_size: int) -> bool:
    try:
        st = path.stat()
    except FileNotFoundError:
        return False
    if st.st_size != expected_size:
        return False
    existing_mtime = dt.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds")
    return metadata_fingerprint(st.st_size, existing_mtime) == expected_hash


def resolve_destination_path(candidate: Path, expected_hash: str, expected_size: int) -> Tuple[Optional[Path], Optional[str]]:
    if not candidate.exists():
        return candidate, None

    if existing_hash_matches(candidate, expected_hash, expected_size):
        return None, "already_exists_same_hash"

    stem = candidate.stem
    suffix = candidate.suffix
    parent = candidate.parent
    counter = 1

    while True:
        nxt = parent / f"{stem}-copy-{counter}{suffix}"
        if not nxt.exists():
            return nxt, None
        if existing_hash_matches(nxt, expected_hash, expected_size):
            return None, "already_exists_same_hash"
        counter += 1


def copy_file_with_progress(
    src: Path,
    dst: Path,
    chunk_size: int = 16 * 1024 * 1024,
    on_chunk: Optional[Callable[[int], None]] = None,
) -> None:
    with src.open("rb") as src_f, dst.open("wb") as dst_f:
        while True:
            chunk = src_f.read(chunk_size)
            if not chunk:
                break
            dst_f.write(chunk)
            if on_chunk:
                on_chunk(len(chunk))
    shutil.copystat(src, dst)


def show_prompt_notification(
    title: str,
    message: str,
    actions: Optional[str] = None,
    close_label: str = "Skip",
    timeout_seconds: int = 120,
    close_first: bool = True,
    prefer_swiftdialog: bool = True,
    allow_legacy_fallback: bool = True,
) -> str:
    def _run_swiftdialog_prompt(primary_action: str, secondary_action: str) -> str:
        dialog_bin = detect_swiftdialog_binary()
        if not dialog_bin:
            return ""
        button1 = secondary_action if close_first else primary_action
        button2 = primary_action if close_first else secondary_action
        cmd = [
            dialog_bin,
            "--title",
            title,
            "--message",
            message,
            "--button1text",
            button1,
            "--button2text",
            button2,
            "--timer",
            str(max(1, int(timeout_seconds))),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        rc = proc.returncode
        if rc == 0:
            return button1
        if rc == 2:
            return button2
        if rc in (4, 20):
            return "@TIMEOUT"
        if rc in (5, 10):
            return "@CLOSED"
        if rc != 0 and (proc.stderr or "").strip():
            print(f"swiftDialog prompt failed (rc={rc}): {proc.stderr.strip()}", file=sys.stderr)
        return ""

    def _run_swiftdialog_info() -> bool:
        dialog_bin = detect_swiftdialog_binary()
        if not dialog_bin:
            return False
        proc = subprocess.run(
            [dialog_bin, "--notification", "--title", title, "--message", message],
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            return True
        if (proc.stderr or "").strip():
            print(f"swiftDialog notification failed: {proc.stderr.strip()}", file=sys.stderr)
        return False

    def _run_dialog_prompt(primary_action: str, secondary_action: str) -> str:
        safe_message = message.replace("\\", "\\\\").replace('"', '\\"')
        safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
        safe_primary = primary_action.replace("\\", "\\\\").replace('"', '\\"')
        safe_secondary = secondary_action.replace("\\", "\\\\").replace('"', '\\"')
        button_left = safe_secondary if close_first else safe_primary
        button_right = safe_primary if close_first else safe_secondary
        default_button = button_left if close_first else button_right
        script = [
            f'display dialog "{safe_message}" with title "{safe_title}" buttons {{"{button_left}", "{button_right}"}} default button "{default_button}" giving up after {int(timeout_seconds)}',
        ]
        proc = subprocess.run(["osascript", "-e", script[0]], capture_output=True, text=True)
        if proc.returncode != 0:
            err = (proc.stderr or "").strip()
            if err:
                print(f"dialog prompt failed: {err}", file=sys.stderr)
            return ""
        out = (proc.stdout or "").strip()
        if f"button returned:{primary_action}" in out:
            return primary_action
        if f"button returned:{secondary_action}" in out:
            return secondary_action
        if "gave up:true" in out:
            return "@TIMEOUT"
        return ""

    if actions:
        primary_action = actions.split(",")[0].strip()
        if prefer_swiftdialog:
            swift_choice = _run_swiftdialog_prompt(primary_action, close_label)
            if swift_choice:
                return swift_choice
            if not allow_legacy_fallback:
                return ""

        dialog_choice = _run_dialog_prompt(primary_action, close_label)
        if dialog_choice:
            return dialog_choice
        if not allow_legacy_fallback:
            return ""
    else:
        if prefer_swiftdialog and _run_swiftdialog_info():
            return ""
        if prefer_swiftdialog and not allow_legacy_fallback:
            return ""

    if not allow_legacy_fallback:
        return ""

    if has_command("alerter"):
        cmd = [
            "alerter",
            "--title",
            title,
            "--message",
            message,
            "--timeout",
            str(timeout_seconds),
            "--ignore-dnd",
        ]
        if actions:
            cmd.extend(["--actions", actions, "--close-label", close_label])
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"alerter failed: {proc.stderr.strip()}", file=sys.stderr)
        else:
            choice = (proc.stdout or "").strip()
            if actions:
                primary_action = actions.split(",")[0].strip()
                if choice in ("", "@TIMEOUT", "@CLOSED"):
                    return choice
            return choice

    # Fallback to informational notification only.
    safe_message = message.replace("\\", "\\\\").replace('"', '\\"')
    safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
    script = f'display notification "{safe_message}" with title "{safe_title}"'
    subprocess.run(["osascript", "-e", script], check=False)
    return ""


def show_info_notification(title: str, message: str, timeout_seconds: int = 5) -> None:
    show_prompt_notification(
        title=title,
        message=message,
        actions=None,
        close_label="",
        timeout_seconds=timeout_seconds,
    )


def show_import_preview_decision(
    summary: Dict[str, Any],
    report_md: Path,
    timeout_seconds: int = 120,
    use_swiftdialog: bool = True,
    allow_legacy_fallback: bool = True,
) -> str:
    title = "SD Import Preview"
    overview = (
        f"Volume: {summary.get('volume_name') or '-'}\n"
        f"New: {summary.get('new_files', 0)}\n"
        f"Known: {summary.get('known_files', 0)}\n"
        f"Conflicts: {summary.get('conflict_files', 0)}\n"
        f"Unsupported: {summary.get('unsupported_files', 0)}\n\n"
        "Choose Import New to continue, or Open Report for full details."
    )

    dialog_bin = detect_swiftdialog_binary() if use_swiftdialog else None
    if dialog_bin:
        while True:
            proc = subprocess.run(
                [
                    dialog_bin,
                    "--title",
                    title,
                    "--message",
                    overview,
                    "--button1text",
                    "Skip",
                    "--button2text",
                    "Import New",
                    "--infobuttontext",
                    "Open Report",
                    "--timer",
                    str(max(1, int(timeout_seconds))),
                ],
                capture_output=True,
                text=True,
            )
            rc = proc.returncode
            if rc == 0:
                return "Skip"
            if rc == 2:
                return "Import New"
            if rc == 3:
                subprocess.run(["open", str(report_md)], check=False)
                continue
            if rc in (4, 20):
                return "@TIMEOUT"
            if rc in (5, 10):
                return "Skip"
            err = (proc.stderr or "").strip()
            if err:
                print(f"swiftDialog preview failed (rc={rc}): {err}", file=sys.stderr)
            break
        if not allow_legacy_fallback:
            return "@CLOSED"

    if not allow_legacy_fallback:
        return "@CLOSED"

    while True:
        safe_message = overview.replace("\\", "\\\\").replace('"', '\\"')
        safe_title = title.replace("\\", "\\\\").replace('"', '\\"')
        script = (
            f'display dialog "{safe_message}" with title "{safe_title}" '
            f'buttons {{"Skip", "Open Report", "Import New"}} '
            f'default button "Skip" giving up after {int(timeout_seconds)}'
        )
        proc = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        if proc.returncode == 0:
            out = (proc.stdout or "").strip()
            if "button returned:Import New" in out:
                return "Import New"
            if "button returned:Open Report" in out:
                subprocess.run(["open", str(report_md)], check=False)
                continue
            if "button returned:Skip" in out:
                return "Skip"
            if "gave up:true" in out:
                return "@TIMEOUT"
        else:
            err = (proc.stderr or "").strip()
            if err:
                print(f"preview dialog failed: {err}", file=sys.stderr)
            break

    while True:
        choice = show_prompt_notification(
            title=title,
            message=overview,
            actions="Import New,Open Report",
            close_label="Skip",
            timeout_seconds=timeout_seconds,
            close_first=True,
            prefer_swiftdialog=False,
        )
        if choice == "Open Report":
            subprocess.run(["open", str(report_md)], check=False)
            continue
        return choice


def begin_job(
    conn: sqlite3.Connection,
    job_id: str,
    mount_path: str,
    volume_name: Optional[str],
    volume_uuid: Optional[str],
    location: str,
) -> None:
    conn.execute(
        """
        INSERT INTO jobs (job_id, created_at, mount_path, volume_name, volume_uuid, location, status)
        VALUES (?, ?, ?, ?, ?, ?, 'SCANNED')
        """,
        (job_id, now_local_iso(), mount_path, volume_name, volume_uuid, location),
    )


def finalize_job_scan(conn: sqlite3.Connection, job_id: str, summary: Dict[str, Any], report_path: Path) -> None:
    conn.execute(
        """
        UPDATE jobs
        SET scanned_files=?, new_files=?, known_files=?, unsupported_files=?, conflict_files=?, report_path=?
        WHERE job_id=?
        """,
        (
            summary["scanned_files"],
            summary["new_files"],
            summary["known_files"],
            summary["unsupported_files"],
            summary["conflict_files"],
            str(report_path.with_suffix(".md")),
            job_id,
        ),
    )


def get_state_dir_from_conn(conn: sqlite3.Connection) -> Path:
    return Path(conn.execute("PRAGMA database_list").fetchone()[2]).parent


def progress_path_for_job(state_dir: Path, job_id: str) -> Path:
    return state_dir / "progress" / f"{job_id}.json"


def latest_progress_path(state_dir: Path) -> Optional[Path]:
    progress_dir = state_dir / "progress"
    if not progress_dir.exists():
        return None
    candidates = [p for p in progress_dir.glob("*.json") if p.is_file()]
    if not candidates:
        return None
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


def format_progress_line(payload: Dict[str, Any]) -> str:
    status = str(payload.get("status") or "unknown")
    percent = float(payload.get("percent") or 0.0)
    done_files = int(payload.get("done_files") or 0)
    total_files = int(payload.get("total_files") or 0)
    processed_bytes = float(payload.get("processed_bytes") or 0.0)
    total_bytes = float(payload.get("total_bytes") or 0.0)
    throughput_bps = float(payload.get("throughput_bps") or 0.0)
    eta_seconds = payload.get("eta_seconds")
    eta_text = format_duration(float(eta_seconds)) if eta_seconds is not None else "?"
    current_file = payload.get("current_file") or "-"
    return (
        f"[{status}] {percent:.1f}% "
        f"{done_files}/{total_files} files "
        f"{format_bytes(processed_bytes)}/{format_bytes(total_bytes)} "
        f"{format_bytes(throughput_bps)}/s ETA {eta_text} "
        f"current={current_file}"
    )


def detect_swiftdialog_binary() -> Optional[str]:
    candidates: List[str] = []
    in_path = shutil.which("dialog")
    if in_path:
        candidates.append(in_path)
    candidates.extend(["/usr/local/bin/dialog", "/opt/homebrew/bin/dialog"])

    seen = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        p = Path(candidate)
        if not p.exists() or not os.access(p, os.X_OK):
            continue
        try:
            proc = subprocess.run(
                [candidate, "--version"],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
            )
        except Exception:
            continue
        output = f"{proc.stdout}\n{proc.stderr}".lower()
        if "swiftdialog" in output or "dialog-" in output:
            return candidate
        try:
            help_proc = subprocess.run(
                [candidate, "--help"],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
            )
        except Exception:
            continue
        help_output = f"{help_proc.stdout}\n{help_proc.stderr}".lower()
        if "swiftdialog" in help_output:
            return candidate
    return None


class SwiftDialogProgressWindow:
    def __init__(self, dialog_bin: str, command_file: Path) -> None:
        self.dialog_bin = dialog_bin
        self.command_file = command_file
        self.proc: Optional[subprocess.Popen[Any]] = None

    def start(self, title: str, message: str) -> bool:
        ensure_dir(self.command_file.parent)
        self.command_file.write_text("")
        cmd = [
            self.dialog_bin,
            "--title",
            title,
            "--message",
            message,
            "--progress",
            "0",
            "--progresstext",
            "Preparing import...",
            "--button1text",
            "Dismiss",
            "--ontop",
            "--moveable",
            "--commandfile",
            str(self.command_file),
        ]
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return True
        except Exception:
            self.proc = None
            return False

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def _send(self, line: str) -> None:
        if not self.is_alive():
            return
        try:
            with self.command_file.open("a") as f:
                f.write(line.replace("\n", " ").strip() + "\n")
        except Exception:
            pass

    def set_dismiss_enabled(self, enabled: bool) -> None:
        self._send("button1: enable" if enabled else "button1: disable")

    def activate(self) -> None:
        self._send("activate:")

    def update(self, percent: float, progress_text: str, message: Optional[str] = None) -> None:
        pct = max(0, min(100, int(percent)))
        self._send(f"progress: {pct}")
        if progress_text:
            self._send(f"progresstext: {progress_text}")
        if message:
            self._send(f"message: {message}")

    def close(self, final_message: str) -> None:
        self._send("progress: 100")
        self._send("progresstext: Completed")
        if final_message:
            self._send(f"message: {final_message}")
        self.set_dismiss_enabled(True)
        self.activate()

    def quit(self, wait_seconds: float = 1.0) -> None:
        if not self.is_alive():
            self.proc = None
            return
        self._send("quit:")
        if self.proc is None:
            return
        timeout = max(0.1, float(wait_seconds))
        try:
            self.proc.wait(timeout=timeout)
        except Exception:
            try:
                self.proc.terminate()
            except Exception:
                pass
            try:
                self.proc.wait(timeout=0.5)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        self.proc = None


def start_persistent_status_window(
    state_dir: Path,
    title: str,
    message: str,
    progress_text: str,
) -> Optional[SwiftDialogProgressWindow]:
    dialog_bin = detect_swiftdialog_binary()
    if not dialog_bin:
        return None

    session_id = make_job_id()
    command_file = state_dir / "progress" / f"{session_id}.dialog.log"
    win = SwiftDialogProgressWindow(dialog_bin, command_file)
    if not win.start(title=title, message=message):
        return None
    win.set_dismiss_enabled(False)
    win.update(percent=0, progress_text=progress_text, message=message)
    return win


def should_debounce_mount(conn: sqlite3.Connection, mount_path: str, debounce_seconds: float) -> bool:
    if debounce_seconds <= 0:
        return False
    state_dir = get_state_dir_from_conn(conn)
    ensure_dir(state_dir)
    debounce_file = state_dir / "mount_debounce.json"
    now_ts = time.time()

    payload: Dict[str, Any] = {}
    if debounce_file.exists():
        try:
            payload = json.loads(debounce_file.read_text())
        except Exception:
            payload = {}

    last_mount = payload.get("mount_path")
    last_ts = float(payload.get("last_ts") or 0.0)
    if last_mount == mount_path and (now_ts - last_ts) < debounce_seconds:
        return True

    payload = {"mount_path": mount_path, "last_ts": now_ts}
    debounce_file.write_text(json.dumps(payload))
    return False


def scan_mount(
    conn: sqlite3.Connection,
    mount_path: Path,
    location: str,
    photos_base: Path,
    videos_base: Path,
    job_id: Optional[str] = None,
    scan_progress: Optional[Callable[[str, Optional[float]], None]] = None,
) -> Dict[str, Any]:
    if not mount_path.exists() or not mount_path.is_dir():
        raise RuntimeError(f"mount path is not a directory: {mount_path}")

    vol_info = get_diskutil_info(str(mount_path))
    volume_name = vol_info.get("VolumeName") or mount_path.name
    volume_uuid = vol_info.get("VolumeUUID")

    job_id = job_id or make_job_id()
    begin_job(conn, job_id, str(mount_path), volume_name, volume_uuid, location)

    scanned_files = 0
    new_files = 0
    known_files = 0
    unsupported_files = 0
    conflict_files = 0

    rows_for_report: List[Dict[str, Any]] = []
    indexed_files: List[Tuple[Path, os.stat_result, str, Optional[str], str, str, str]] = []
    media_for_batch: List[Tuple[Path, str]] = []

    file_paths = list(iter_files(mount_path))
    total_to_index = len(file_paths)
    for idx, file_path in enumerate(file_paths, start=1):
        scanned_files = idx
        if scan_progress and (idx % 250 == 0 or idx == total_to_index):
            pct = 35.0 if total_to_index == 0 else (idx / total_to_index) * 35.0
            scan_progress(f"Indexed {idx}/{total_to_index} files...", pct)
        try:
            st = file_path.stat()
        except FileNotFoundError:
            continue

        ext = file_path.suffix.lower()
        media_type = classify_ext(ext)
        rel_path = str(file_path.relative_to(mount_path))
        filename = file_path.name
        mtime = dt.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds")

        indexed_files.append((file_path, st, ext, media_type, rel_path, filename, mtime))
        if media_type:
            media_for_batch.append((file_path, media_type))

    if scan_progress:
        scan_progress(f"Indexed {len(indexed_files)} files. Reading capture dates...", 40.0)
    capture_date_map = capture_dates_from_exiftool_batch(
        media_for_batch,
        progress_cb=(
            (lambda done, total: scan_progress(
                f"Reading capture dates {done}/{total}...",
                40.0 + ((done / total) * 25.0 if total > 0 else 25.0),
            ))
            if scan_progress
            else None
        ),
    )
    if scan_progress:
        scan_progress(
            f"Capture-date metadata ready for {len(capture_date_map)}/{len(media_for_batch)} media files.",
            65.0,
        )

    for idx, (file_path, st, ext, media_type, rel_path, filename, mtime) in enumerate(indexed_files, start=1):
        if scan_progress and (idx % 250 == 0 or idx == len(indexed_files)):
            pct = 100.0 if len(indexed_files) == 0 else 65.0 + (idx / len(indexed_files)) * 35.0
            scan_progress(f"Analyzing {idx}/{len(indexed_files)} files...", pct)
        if media_type is None:
            unsupported_files += 1
            conn.execute(
                """
                INSERT INTO job_files (
                    job_id, src_path, rel_path, filename, ext, size, mtime, media_type, decision, copy_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'UNSUPPORTED', 'SKIPPED')
                """,
                (job_id, str(file_path), rel_path, filename, ext, st.st_size, mtime, "unsupported"),
            )
            continue

        content_hash = metadata_fingerprint(st.st_size, mtime)
        exists = conn.execute(
            "SELECT 1 FROM items WHERE hash=? AND size=? LIMIT 1",
            (content_hash, st.st_size),
        ).fetchone()

        capture_date = capture_date_map.get(str(file_path))
        if not capture_date:
            # KNOWN files already have dedupe identity; avoid expensive fallback lookups.
            if exists:
                capture_date = capture_date_from_mtime(st)
            else:
                capture_date = capture_date_fallback_without_exiftool(file_path, st)

        if media_type == "photo":
            dest_dir = make_photo_dest_dir(photos_base, capture_date, location)
        else:
            dest_dir = make_video_dest_dir(videos_base, capture_date)

        decision = "KNOWN" if exists else "NEW"
        copy_status = "SKIPPED" if exists else "PENDING"
        dest_path = str(dest_dir / filename)

        # Early conflict signal: destination file exists with different metadata fingerprint.
        if decision == "NEW" and Path(dest_path).exists():
            if not existing_hash_matches(Path(dest_path), content_hash, st.st_size):
                decision = "CONFLICT"
                conflict_files += 1
                copy_status = "PENDING"
            else:
                decision = "KNOWN"
                copy_status = "SKIPPED"

        if decision == "NEW":
            new_files += 1
        elif decision == "KNOWN":
            known_files += 1

        error = None
        if decision == "CONFLICT":
            error = "destination file exists with different content"

        conn.execute(
            """
            INSERT INTO job_files (
                job_id, src_path, rel_path, filename, ext, size, mtime, media_type, hash,
                decision, dest_dir, dest_path, copy_status, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                job_id,
                str(file_path),
                rel_path,
                filename,
                ext,
                st.st_size,
                mtime,
                media_type,
                content_hash,
                decision,
                str(dest_dir),
                dest_path,
                copy_status,
                error,
            ),
        )

        rows_for_report.append(
            {
                "src_path": str(file_path),
                "rel_path": rel_path,
                "filename": filename,
                "size": st.st_size,
                "media_type": media_type,
                "hash": content_hash,
                "decision": decision,
                "capture_date": capture_date,
                "dest_dir": str(dest_dir),
                "dest_path": dest_path,
                "error": error,
            }
        )

    summary = {
        "job_id": job_id,
        "mount_path": str(mount_path),
        "volume_name": volume_name,
        "volume_uuid": volume_uuid,
        "location": location,
        "scanned_files": scanned_files,
        "new_files": new_files,
        "known_files": known_files,
        "unsupported_files": unsupported_files,
        "conflict_files": conflict_files,
    }

    # By convention, reports live under ~/.sd-import/reports/<job_id>.{json,md}
    state_dir = Path(conn.execute("PRAGMA database_list").fetchone()[2]).parent
    final_report_path = state_dir / "reports" / job_id
    write_report(final_report_path, summary, rows_for_report)

    finalize_job_scan(conn, job_id, summary, final_report_path)
    conn.commit()
    if scan_progress:
        scan_progress("Scan complete.", 100.0)

    return summary


def import_new_files(
    conn: sqlite3.Connection,
    job_id: str,
    show_progress_ui: bool = False,
    progress_window: Optional[SwiftDialogProgressWindow] = None,
) -> Dict[str, Any]:
    job_row = conn.execute(
        "SELECT job_id, volume_name, report_path FROM jobs WHERE job_id=? LIMIT 1",
        (job_id,),
    ).fetchone()
    if not job_row:
        raise RuntimeError(f"job not found: {job_id}")

    rows = conn.execute(
        """
        SELECT id, src_path, rel_path, filename, size, mtime, media_type, hash, dest_dir, decision, copy_status
        FROM job_files
        WHERE job_id=?
          AND decision IN ('NEW', 'CONFLICT')
          AND (copy_status IS NULL OR copy_status IN ('PENDING', 'FAILED'))
        ORDER BY id
        """,
        (job_id,),
    ).fetchall()

    imported_files = 0
    skipped_files = 0
    failed_files = 0

    total_files = len(rows)
    total_bytes = sum(int(r["size"] or 0) for r in rows)
    done_files = 0
    processed_bytes_done = 0
    copied_bytes_done = 0
    active_file_bytes = 0
    current_file: Optional[str] = None
    current_source_path: Optional[str] = None

    started_at = now_local_iso()
    started_epoch = time.time()
    progress_status = "copying"
    last_progress_emit_epoch = 0.0

    state_dir = get_state_dir_from_conn(conn)
    progress_path = progress_path_for_job(state_dir, job_id)
    progress_cmd_path = state_dir / "progress" / f"{job_id}.dialog.log"
    dialog_window: Optional[SwiftDialogProgressWindow] = progress_window
    if dialog_window:
        dialog_window.set_dismiss_enabled(False)
        dialog_window.update(percent=0, progress_text="Starting copy...", message=f"Job {job_id}\nPreparing files...")
    elif show_progress_ui:
        dialog_bin = detect_swiftdialog_binary()
        if dialog_bin:
            candidate_window = SwiftDialogProgressWindow(dialog_bin, progress_cmd_path)
            dialog_title = "SD Import Progress"
            dialog_message = f"{job_row['volume_name'] or 'SD Card'}\n{job_id}"
            if candidate_window.start(dialog_title, dialog_message):
                dialog_window = candidate_window
                dialog_window.set_dismiss_enabled(False)

    def emit_progress(force: bool = False) -> None:
        nonlocal last_progress_emit_epoch
        now_epoch = time.time()
        if not force and (now_epoch - last_progress_emit_epoch) < 0.75:
            return

        display_processed_bytes = min(total_bytes, processed_bytes_done + active_file_bytes)
        display_copied_bytes = copied_bytes_done + active_file_bytes
        elapsed_seconds = max(0.0, now_epoch - started_epoch)
        throughput_bps = (display_processed_bytes / elapsed_seconds) if elapsed_seconds > 0 else 0.0
        remaining_bytes = max(0, total_bytes - display_processed_bytes)
        eta_seconds: Optional[float]
        if remaining_bytes == 0:
            eta_seconds = 0.0
        elif throughput_bps > 1:
            eta_seconds = remaining_bytes / throughput_bps
        else:
            eta_seconds = None

        if total_bytes > 0:
            percent = (display_processed_bytes / total_bytes) * 100.0
        elif total_files > 0:
            percent = (done_files / total_files) * 100.0
        else:
            percent = 100.0

        payload: Dict[str, Any] = {
            "job_id": job_id,
            "volume_name": job_row["volume_name"],
            "status": progress_status,
            "started_at": started_at,
            "updated_at": now_local_iso(),
            "elapsed_seconds": round(elapsed_seconds, 3),
            "total_files": total_files,
            "done_files": done_files,
            "imported_files": imported_files,
            "skipped_files": skipped_files,
            "failed_files": failed_files,
            "total_bytes": int(total_bytes),
            "processed_bytes": int(display_processed_bytes),
            "copied_bytes": int(display_copied_bytes),
            "throughput_bps": round(throughput_bps, 2),
            "eta_seconds": round(float(eta_seconds), 1) if eta_seconds is not None else None,
            "percent": round(percent, 2),
            "current_file": current_file,
            "current_source_path": current_source_path,
            "report_path": job_row["report_path"],
        }
        write_json_atomic(progress_path, payload)

        if dialog_window:
            dialog_line = (
                f"{percent:.1f}% • {done_files}/{total_files} files • "
                f"{format_bytes(display_processed_bytes)}/{format_bytes(total_bytes)} • "
                f"{format_bytes(throughput_bps)}/s • ETA {format_duration(eta_seconds)}"
            )
            dialog_message = f"Job {job_id}"
            if current_file:
                dialog_message += f"\nCurrent: {current_file}"
            dialog_window.update(percent=percent, progress_text=dialog_line, message=dialog_message)

        last_progress_emit_epoch = now_epoch

    emit_progress(force=True)

    for row in rows:
        src = Path(row["src_path"])
        filename = row["filename"]
        expected_size = int(row["size"])
        if not src.exists():
            current_file = filename
            current_source_path = str(src)
            active_file_bytes = 0
            emit_progress(force=True)
            failed_files += 1
            done_files += 1
            processed_bytes_done += expected_size
            conn.execute(
                "UPDATE job_files SET copy_status='FAILED', error=? WHERE id=?",
                ("source file missing", row["id"]),
            )
            current_file = None
            current_source_path = None
            active_file_bytes = 0
            emit_progress(force=True)
            continue

        mtime = row["mtime"]
        if not mtime:
            mtime = dt.datetime.fromtimestamp(src.stat().st_mtime).isoformat(timespec="seconds")
        expected_hash = row["hash"]
        dest_dir = Path(row["dest_dir"])

        current_file = filename
        current_source_path = str(src)
        active_file_bytes = 0
        emit_progress(force=True)

        if not expected_hash:
            src_st = src.stat()
            mtime = dt.datetime.fromtimestamp(src_st.st_mtime).isoformat(timespec="seconds")
            expected_size = int(src_st.st_size)
            expected_hash = metadata_fingerprint(expected_size, mtime)
            conn.execute(
                "UPDATE job_files SET hash=?, size=?, mtime=? WHERE id=?",
                (expected_hash, expected_size, mtime, row["id"]),
            )

        already_imported = conn.execute(
            "SELECT 1 FROM items WHERE hash=? AND size=? LIMIT 1",
            (expected_hash, expected_size),
        ).fetchone()
        if already_imported:
            skipped_files += 1
            done_files += 1
            processed_bytes_done += expected_size
            conn.execute(
                "UPDATE job_files SET copy_status='SKIPPED', error=? WHERE id=?",
                ("already_imported_hash", row["id"]),
            )
            current_file = None
            current_source_path = None
            active_file_bytes = 0
            emit_progress(force=True)
            continue

        ensure_dir(dest_dir)
        candidate = dest_dir / filename
        target, skip_reason = resolve_destination_path(candidate, expected_hash, expected_size)

        if target is None:
            skipped_files += 1
            done_files += 1
            processed_bytes_done += expected_size
            conn.execute(
                "UPDATE job_files SET copy_status='SKIPPED', error=? WHERE id=?",
                (skip_reason, row["id"]),
            )
            conn.execute(
                "INSERT OR IGNORE INTO items (hash, size, first_seen_at, first_job_id, first_source_path) VALUES (?, ?, ?, ?, ?)",
                (expected_hash, expected_size, now_local_iso(), job_id, str(src)),
            )
            current_file = None
            current_source_path = None
            active_file_bytes = 0
            emit_progress(force=True)
            continue

        tmp_target = target.with_suffix(target.suffix + ".part")
        try:
            def on_chunk(chunk_size: int) -> None:
                nonlocal active_file_bytes
                active_file_bytes = min(expected_size, active_file_bytes + chunk_size)
                emit_progress(force=False)

            copy_file_with_progress(src, tmp_target, on_chunk=on_chunk)
            copied_size = tmp_target.stat().st_size
            if copied_size != expected_size:
                raise RuntimeError("size mismatch after copy")
            os.replace(tmp_target, target)
        except Exception as exc:
            failed_files += 1
            done_files += 1
            processed_bytes_done += expected_size
            if tmp_target.exists():
                tmp_target.unlink(missing_ok=True)
            conn.execute(
                "UPDATE job_files SET copy_status='FAILED', error=? WHERE id=?",
                (str(exc), row["id"]),
            )
            current_file = None
            current_source_path = None
            active_file_bytes = 0
            emit_progress(force=True)
            continue

        imported_files += 1
        done_files += 1
        processed_bytes_done += expected_size
        copied_bytes_done += expected_size
        conn.execute(
            "UPDATE job_files SET copy_status='COPIED', dest_path=?, error=NULL WHERE id=?",
            (str(target), row["id"]),
        )
        conn.execute(
            "INSERT OR IGNORE INTO items (hash, size, first_seen_at, first_job_id, first_source_path) VALUES (?, ?, ?, ?, ?)",
            (expected_hash, expected_size, now_local_iso(), job_id, str(src)),
        )
        current_file = None
        current_source_path = None
        active_file_bytes = 0
        emit_progress(force=True)

    conn.execute(
        """
        UPDATE jobs
        SET imported_files = imported_files + ?,
            skipped_files = skipped_files + ?,
            failed_files = failed_files + ?,
            status = CASE WHEN ? > 0 THEN 'IMPORTED_WITH_ERRORS' ELSE 'IMPORTED' END
        WHERE job_id=?
        """,
        (imported_files, skipped_files, failed_files, failed_files, job_id),
    )
    conn.commit()

    if total_files == 0:
        progress_status = "idle"
    elif failed_files > 0:
        progress_status = "completed_with_errors"
    else:
        progress_status = "completed"
    emit_progress(force=True)

    if dialog_window:
        dialog_window.close(
            f"Done: {imported_files} imported, {skipped_files} skipped, {failed_files} failed"
        )

    return {
        "job_id": job_id,
        "imported_files": imported_files,
        "skipped_files": skipped_files,
        "failed_files": failed_files,
        "progress_path": str(progress_path),
    }


def list_jobs(conn: sqlite3.Connection, limit: int) -> List[sqlite3.Row]:
    return conn.execute(
        """
        SELECT job_id, created_at, mount_path, volume_name, status,
               scanned_files, new_files, known_files, conflict_files,
               imported_files, failed_files, report_path
        FROM jobs
        ORDER BY created_at DESC
        LIMIT ?
        """,
        (limit,),
    ).fetchall()


def print_table(rows: Iterable[sqlite3.Row]) -> None:
    rows = list(rows)
    if not rows:
        print("No rows.")
        return
    headers = rows[0].keys()
    widths = {h: len(h) for h in headers}
    for row in rows:
        for h in headers:
            widths[h] = max(widths[h], len(str(row[h] if row[h] is not None else "")))
    fmt = " | ".join(f"{{:{widths[h]}}}" for h in headers)
    print(fmt.format(*headers))
    print("-+-".join("-" * widths[h] for h in headers))
    for row in rows:
        print(fmt.format(*[str(row[h] if row[h] is not None else "") for h in headers]))


def acquire_lock(lock_path: Path) -> Optional[int]:
    ensure_dir(lock_path.parent)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode("utf-8"))
    return fd


def release_lock(fd: int) -> None:
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def command_scan(args: argparse.Namespace, conn: sqlite3.Connection, config: Dict[str, Any]) -> int:
    mount_path = Path(args.input).expanduser().resolve()
    vol_info = get_diskutil_info(str(mount_path))
    location = choose_location(config, args.location, vol_info.get("VolumeName"))

    summary = scan_mount(
        conn=conn,
        mount_path=mount_path,
        location=location,
        photos_base=Path(args.photos_base).expanduser(),
        videos_base=Path(args.videos_base).expanduser(),
        job_id=args.job_id,
    )
    print(json.dumps(summary, indent=2))
    return 0


def command_import(args: argparse.Namespace, conn: sqlite3.Connection) -> int:
    result = import_new_files(conn, args.job_id, show_progress_ui=args.progress_ui)
    print(json.dumps(result, indent=2))
    return 0


def command_retry(args: argparse.Namespace, conn: sqlite3.Connection) -> int:
    result = import_new_files(conn, args.job_id, show_progress_ui=args.progress_ui)
    print(json.dumps(result, indent=2))
    return 0


def command_run(args: argparse.Namespace, conn: sqlite3.Connection, config: Dict[str, Any]) -> int:
    mount_path = Path(args.input).expanduser().resolve()
    vol_info = get_diskutil_info(str(mount_path))
    location = choose_location(config, args.location, vol_info.get("VolumeName"))
    state_dir = get_state_dir_from_conn(conn)
    persistent_window = getattr(args, "progress_window", None)

    if args.notify and persistent_window is None:
        persistent_window = start_persistent_status_window(
            state_dir=state_dir,
            title="SD Import",
            message=f"{mount_path.name}\nStarting scan...",
            progress_text="Waiting for scan...",
        )
    if persistent_window:
        persistent_window.set_dismiss_enabled(False)
        persistent_window.update(percent=0, progress_text="Scanning files...", message=f"{mount_path.name}\nScanning...")

    def scan_progress_update(text: str, percent: Optional[float] = None) -> None:
        if persistent_window:
            persistent_window.update(
                percent=(percent if percent is not None else 0),
                progress_text=text,
                message=f"{mount_path.name}\n{text}",
            )

    summary = scan_mount(
        conn=conn,
        mount_path=mount_path,
        location=location,
        photos_base=Path(args.photos_base).expanduser(),
        videos_base=Path(args.videos_base).expanduser(),
        scan_progress=scan_progress_update if persistent_window else None,
    )

    report_md = Path(conn.execute("SELECT report_path FROM jobs WHERE job_id=?", (summary["job_id"],)).fetchone()[0])

    message = (
        f"{summary['volume_name']}: {summary['new_files']} new, "
        f"{summary['known_files']} known, {summary['conflict_files']} conflicts"
    )
    if persistent_window:
        persistent_window.update(
            percent=0,
            progress_text="Scan complete, waiting for confirmation",
            message=f"Job {summary['job_id']}\n{message}",
        )

    action = "none"
    if args.notify:
        if persistent_window:
            persistent_window.quit()
            persistent_window = None
        choice = show_import_preview_decision(
            summary=summary,
            report_md=report_md,
            timeout_seconds=120,
            use_swiftdialog=True,
            allow_legacy_fallback=False,
        )
        if choice == "Import New":
            action = "import_confirmed"
        elif choice == "Skip":
            action = "skipped_by_user"
        elif choice in ("@TIMEOUT", "@CLOSED", ""):
            action = "no_response_or_timeout"
        else:
            action = choice
    else:
        choice = ""

    if args.auto_import or choice == "Import New":
        if args.notify and persistent_window is None:
            persistent_window = start_persistent_status_window(
                state_dir=state_dir,
                title="SD Import",
                message=f"{summary['volume_name']}\nPreparing files...",
                progress_text="Starting copy...",
            )
        result = import_new_files(
            conn,
            summary["job_id"],
            show_progress_ui=(args.notify and persistent_window is None),
            progress_window=persistent_window,
        )
        print(json.dumps({"summary": summary, "import": result}, indent=2))
        return 0

    if persistent_window:
        persistent_window.close(
            f"No import started.\nAction: {action}\n{message}\nClick Dismiss to close."
        )

    print(json.dumps({"summary": summary, "action": action}, indent=2))
    return 0


def command_auto(args: argparse.Namespace, conn: sqlite3.Connection, config: Dict[str, Any]) -> int:
    mounts: List[Dict[str, Any]]
    if args.input:
        m = Path(args.input).expanduser().resolve()
        mounts = [{"mount_path": str(m), "volume_name": m.name, "volume_uuid": None, "mounted_at": m.stat().st_mtime}]
    else:
        mounts = []
        deadline = time.time() + max(0.0, args.mount_wait_seconds)
        poll_seconds = max(0.1, args.mount_poll_seconds)
        while True:
            mounts = discover_removable_mounts(config.get("ignore_volume_regex"))
            if mounts:
                break
            if time.time() >= deadline:
                break
            time.sleep(poll_seconds)

    if not mounts:
        print("No removable mounted volumes found.")
        return 0

    selected = mounts if args.all_mounts else mounts[:1]
    exit_code = 0
    for m in selected:
        state_dir = get_state_dir_from_conn(conn)
        persistent_window: Optional[SwiftDialogProgressWindow] = None
        if args.notify and args.auto_import:
            persistent_window = start_persistent_status_window(
                state_dir=state_dir,
                title="SD Import",
                message=f"{m['volume_name']} mounted",
                progress_text="Starting scan...",
            )

        if should_debounce_mount(conn, m["mount_path"], args.debounce_seconds):
            print(
                json.dumps(
                    {
                        "mount_path": m["mount_path"],
                        "volume_name": m["volume_name"],
                        "action": "debounced_duplicate_mount_event",
                    },
                    indent=2,
                )
            )
            if persistent_window:
                persistent_window.close(
                    f"Duplicate mount event debounced for {m['volume_name']}.\nClick Dismiss to close."
                )
            continue

        if args.notify and not args.auto_import:
            continue_choice = show_prompt_notification(
                title="SD Card Inserted",
                message=f"{m['volume_name']} mounted. Continue import flow?",
                actions="Continue",
                close_label="Skip",
                timeout_seconds=120,
                prefer_swiftdialog=True,
                allow_legacy_fallback=False,
            )
            if continue_choice == "Continue":
                pass
            elif continue_choice == "Skip":
                print(
                    json.dumps(
                        {
                            "mount_path": m["mount_path"],
                            "volume_name": m["volume_name"],
                            "action": "skipped_by_user",
                            "choice": continue_choice,
                        },
                        indent=2,
                    )
                )
                if persistent_window:
                    persistent_window.close(
                        f"Skipped by user for {m['volume_name']}.\nClick Dismiss to close."
                    )
                continue
            else:
                print(
                    json.dumps(
                        {
                            "mount_path": m["mount_path"],
                            "volume_name": m["volume_name"],
                            "action": "no_response_or_timeout",
                            "choice": continue_choice or "",
                        },
                        indent=2,
                    )
                )
                if persistent_window:
                    persistent_window.close(
                        f"No response/timeout for {m['volume_name']}.\nClick Dismiss to close."
                )
                continue

            if args.notify and persistent_window is None:
                persistent_window = start_persistent_status_window(
                    state_dir=state_dir,
                    title="SD Import",
                    message=f"{m['volume_name']} mounted",
                    progress_text="Continue clicked, starting scan...",
                )

            show_info_notification(
                title="SD Import",
                message=f"Scanning {m['volume_name']}...",
                timeout_seconds=4,
            )
            if persistent_window:
                persistent_window.update(
                    percent=0,
                    progress_text="Continue clicked, starting scan...",
                    message=f"{m['volume_name']}\nScanning...",
                )

        run_args = argparse.Namespace(
            input=m["mount_path"],
            location=args.location,
            photos_base=args.photos_base,
            videos_base=args.videos_base,
            notify=args.notify,
            auto_import=args.auto_import,
            progress_window=persistent_window,
        )
        code = command_run(run_args, conn, config)
        if code != 0:
            exit_code = code
    return exit_code


def command_status(args: argparse.Namespace, state_dir: Path) -> int:
    if args.job_id:
        progress_path = progress_path_for_job(state_dir, args.job_id)
    else:
        progress_path = latest_progress_path(state_dir)

    if not progress_path or not progress_path.exists():
        print("No progress file found.")
        return 1

    last_seen: Optional[str] = None
    while True:
        payload = read_json_file(progress_path)
        if payload is None:
            print(f"Could not parse progress file: {progress_path}", file=sys.stderr)
            return 1

        serialized = json.dumps(payload, sort_keys=True)
        if serialized != last_seen:
            if args.json_output:
                print(json.dumps(payload, indent=2))
            else:
                print(format_progress_line(payload))
            last_seen = serialized

        status = str(payload.get("status") or "")
        if not args.follow or status in TERMINAL_PROGRESS_STATES:
            return 0
        time.sleep(max(0.1, args.interval))


def command_list_mounts(args: argparse.Namespace, config: Dict[str, Any]) -> int:
    mounts = discover_removable_mounts(config.get("ignore_volume_regex"))
    payload: List[Dict[str, Any]] = []
    for m in mounts:
        mounted_at = m.get("mounted_at")
        mounted_at_iso = ""
        if isinstance(mounted_at, (int, float)):
            mounted_at_iso = dt.datetime.fromtimestamp(mounted_at).astimezone().isoformat(timespec="seconds")
        payload.append(
            {
                "mount_path": m.get("mount_path"),
                "volume_name": m.get("volume_name"),
                "volume_uuid": m.get("volume_uuid"),
                "mounted_at": mounted_at,
                "mounted_at_iso": mounted_at_iso,
            }
        )

    if args.json_output:
        print(json.dumps(payload, indent=2))
        return 0

    if not payload:
        print("No removable mounted volumes found.")
        return 0

    # Render simple text table for terminal debugging.
    headers = ["volume_name", "mount_path", "mounted_at_iso", "volume_uuid"]
    widths = {h: len(h) for h in headers}
    for row in payload:
        for h in headers:
            widths[h] = max(widths[h], len(str(row.get(h) or "")))
    fmt = " | ".join(f"{{:{widths[h]}}}" for h in headers)
    print(fmt.format(*headers))
    print("-+-".join("-" * widths[h] for h in headers))
    for row in payload:
        print(fmt.format(*[str(row.get(h) or "") for h in headers]))
    return 0


def command_list_jobs(args: argparse.Namespace, conn: sqlite3.Connection) -> int:
    rows = list_jobs(conn, args.limit)
    if args.json_output:
        print(json.dumps([dict(r) for r in rows], indent=2))
        return 0
    print_table(rows)
    return 0


def command_show_job(args: argparse.Namespace, conn: sqlite3.Connection) -> int:
    job = conn.execute("SELECT * FROM jobs WHERE job_id=?", (args.job_id,)).fetchone()
    if not job:
        print(f"job not found: {args.job_id}")
        return 1
    rows = conn.execute(
        """
        SELECT decision, copy_status, COUNT(*) AS c
        FROM job_files
        WHERE job_id=?
        GROUP BY decision, copy_status
        ORDER BY decision, copy_status
        """,
        (args.job_id,),
    ).fetchall()
    if args.json_output:
        print(json.dumps({"job": dict(job), "breakdown": [dict(r) for r in rows]}, indent=2))
        return 0
    print(json.dumps(dict(job), indent=2))
    print("\nBreakdown:")
    print_table(rows)
    return 0


def prune_history(conn: sqlite3.Connection, cutoff_date: str, vacuum: bool, dry_run: bool) -> Dict[str, Any]:
    job_rows = conn.execute(
        """
        SELECT job_id, report_path
        FROM jobs
        WHERE substr(created_at, 1, 10) < ?
        """,
        (cutoff_date,),
    ).fetchall()

    jobs_matched = len(job_rows)
    job_files_matched = conn.execute(
        """
        SELECT COUNT(*) AS c
        FROM job_files
        WHERE job_id IN (
            SELECT job_id FROM jobs WHERE substr(created_at, 1, 10) < ?
        )
        """,
        (cutoff_date,),
    ).fetchone()["c"]

    deleted_reports = 0
    missing_reports = 0
    report_delete_errors: List[str] = []

    if not dry_run and jobs_matched > 0:
        conn.execute(
            """
            DELETE FROM jobs
            WHERE substr(created_at, 1, 10) < ?
            """,
            (cutoff_date,),
        )
        conn.commit()

        for row in job_rows:
            report_md = row["report_path"]
            if not report_md:
                continue
            md_path = Path(report_md)
            json_path = md_path.with_suffix(".json")
            for p in (md_path, json_path):
                try:
                    if p.exists():
                        p.unlink()
                        deleted_reports += 1
                    else:
                        missing_reports += 1
                except Exception as exc:
                    report_delete_errors.append(f"{p}: {exc}")

        if vacuum:
            conn.execute("VACUUM")
            conn.commit()

    result: Dict[str, Any] = {
        "cutoff_date": cutoff_date,
        "jobs_matched": jobs_matched,
        "job_files_matched": int(job_files_matched),
        "deleted_reports": deleted_reports,
        "missing_reports": missing_reports,
        "report_delete_errors": report_delete_errors,
        "vacuum_requested": vacuum,
        "dry_run": dry_run,
    }
    if dry_run:
        result["status"] = "DRY_RUN"
    elif jobs_matched == 0:
        result["status"] = "NOTHING_TO_PRUNE"
    else:
        result["status"] = "PRUNED"
    return result


def command_prune(args: argparse.Namespace, conn: sqlite3.Connection) -> int:
    if args.days < 0:
        print("--days must be >= 0", file=sys.stderr)
        return 2

    cutoff_date = (dt.date.today() - dt.timedelta(days=args.days)).isoformat()
    result = prune_history(conn, cutoff_date=cutoff_date, vacuum=args.vacuum, dry_run=args.dry_run)
    result["days"] = args.days

    if args.json_output:
        print(json.dumps(result, indent=2))
        return 0

    print(json.dumps(result, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    default_state_dir = Path(os.environ.get("SD_IMPORT_STATE_DIR", "~/.sd-import")).expanduser()

    p = argparse.ArgumentParser(description="SD card importer with dedupe and interactive notifications")
    p.add_argument("--state-dir", default=str(default_state_dir), help="State directory (db, reports, lock)")
    p.add_argument("--db-path", default=None, help="SQLite DB path (defaults to <state-dir>/state.db)")
    p.add_argument("--config", default=None, help="Config JSON path (defaults to <state-dir>/config.json)")

    sub = p.add_subparsers(dest="command", required=True)

    def add_common_io(cmd: argparse.ArgumentParser) -> None:
        cmd.add_argument("--photos-base", default="~/Pictures/Photos")
        cmd.add_argument("--videos-base", default="~/Downloads")
        cmd.add_argument("--location", default=None)

    p_scan = sub.add_parser("scan", help="Scan a mounted card and create a preview job")
    p_scan.add_argument("--input", required=True, help="Mounted SD card path, e.g. /Volumes/CARD")
    p_scan.add_argument("--job-id", default=None)
    add_common_io(p_scan)

    p_import = sub.add_parser("import", help="Import NEW/CONFLICT files from a job")
    p_import.add_argument("--job-id", required=True)
    p_import.add_argument("--progress-ui", action="store_true", default=False, help="Show swiftDialog progress window")

    p_retry = sub.add_parser("retry", help="Retry failed/pending copies for a job")
    p_retry.add_argument("--job-id", required=True)
    p_retry.add_argument("--progress-ui", action="store_true", default=False, help="Show swiftDialog progress window")

    p_run = sub.add_parser("run", help="Scan then optionally notify and import")
    p_run.add_argument("--input", required=True)
    p_run.add_argument("--notify", action="store_true", default=True)
    p_run.add_argument("--no-notify", dest="notify", action="store_false")
    p_run.add_argument("--auto-import", action="store_true", default=False)
    add_common_io(p_run)

    p_auto = sub.add_parser("auto", help="Pick removable mount(s) and run the same flow")
    p_auto.add_argument("--input", default=None, help="Optional explicit mount path (for debug)")
    p_auto.add_argument("--all-mounts", action="store_true", default=False)
    p_auto.add_argument(
        "--mount-wait-seconds",
        type=float,
        default=12.0,
        help="When auto-detecting mount path, wait up to N seconds for removable mount to appear",
    )
    p_auto.add_argument(
        "--mount-poll-seconds",
        type=float,
        default=1.0,
        help="Polling interval while waiting for removable mount detection",
    )
    p_auto.add_argument(
        "--debounce-seconds",
        type=float,
        default=20.0,
        help="Ignore duplicate auto-trigger events for the same mount path within N seconds",
    )
    p_auto.add_argument("--notify", action="store_true", default=True)
    p_auto.add_argument("--no-notify", dest="notify", action="store_false")
    p_auto.add_argument("--auto-import", action="store_true", default=False)
    add_common_io(p_auto)

    p_mounts = sub.add_parser("list-mounts", help="List currently mounted removable volumes")
    p_mounts.add_argument("--json", dest="json_output", action="store_true", default=False)

    p_status = sub.add_parser("status", help="Show import progress from progress JSON")
    p_status.add_argument("--job-id", default=None, help="Job ID (default: latest progress file)")
    p_status.add_argument("--follow", action="store_true", default=False, help="Refresh until import reaches terminal status")
    p_status.add_argument("--interval", type=float, default=1.0, help="Follow polling interval in seconds")
    p_status.add_argument("--json", dest="json_output", action="store_true", default=False)

    p_list = sub.add_parser("list-jobs", help="List recent jobs")
    p_list.add_argument("--limit", type=int, default=15)
    p_list.add_argument("--json", dest="json_output", action="store_true", default=False)

    p_show = sub.add_parser("show-job", help="Show one job in detail")
    p_show.add_argument("--job-id", required=True)
    p_show.add_argument("--json", dest="json_output", action="store_true", default=False)

    p_prune = sub.add_parser("prune", help="Prune old job/job_file history and optional report files")
    p_prune.add_argument("--days", type=int, default=180, help="Prune jobs older than N days (default: 180)")
    p_prune.add_argument("--dry-run", action="store_true", default=False, help="Show what would be deleted")
    p_prune.add_argument("--vacuum", action="store_true", default=False, help="Run VACUUM after pruning")
    p_prune.add_argument("--json", dest="json_output", action="store_true", default=False)

    return p


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    state_dir = Path(args.state_dir).expanduser()
    db_path = Path(args.db_path).expanduser() if args.db_path else state_dir / "state.db"
    config_path = Path(args.config).expanduser() if args.config else state_dir / "config.json"
    lock_path = state_dir / "run.lock"

    ensure_dir(state_dir)
    config = load_json(config_path)

    lock_fd: Optional[int] = None
    lock_required_commands = {"scan", "import", "retry", "run", "auto", "prune"}
    if args.command in lock_required_commands:
        lock_fd = acquire_lock(lock_path)
        if lock_fd is None:
            print("Another sd_import process is running; skipping.", file=sys.stderr)
            return 2

    conn = connect_db(db_path)
    try:
        if args.command == "scan":
            return command_scan(args, conn, config)
        if args.command == "import":
            return command_import(args, conn)
        if args.command == "retry":
            return command_retry(args, conn)
        if args.command == "run":
            return command_run(args, conn, config)
        if args.command == "auto":
            return command_auto(args, conn, config)
        if args.command == "list-mounts":
            return command_list_mounts(args, config)
        if args.command == "status":
            return command_status(args, state_dir)
        if args.command == "list-jobs":
            return command_list_jobs(args, conn)
        if args.command == "show-job":
            return command_show_job(args, conn)
        if args.command == "prune":
            return command_prune(args, conn)
        parser.error(f"unknown command: {args.command}")
        return 1
    finally:
        conn.close()
        if lock_fd is not None:
            release_lock(lock_fd)


if __name__ == "__main__":
    raise SystemExit(main())
