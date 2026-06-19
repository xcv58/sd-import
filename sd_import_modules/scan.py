from __future__ import annotations

import datetime as dt
import json
import os
import re
import shutil
import sqlite3
import subprocess
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

from .common import (
    make_job_id,
    metadata_fingerprint,
    planned_media_dest_dir,
    safe_destination_component,
)
from .db import begin_job, finalize_job_scan, get_diskutil_info, get_state_dir_from_conn
from .importer import existing_hash_matches

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


def choose_location(config: Dict[str, Any], requested_location: Optional[str], volume_name: Optional[str]) -> str:
    if requested_location:
        return requested_location
    mapping = config.get("location_by_volume")
    if isinstance(mapping, dict) and volume_name and volume_name in mapping:
        return str(mapping[volume_name])
    return str(config.get("default_location", "Untitled"))


def make_photo_dest_dir(
    photos_base: Path,
    capture_date: str,
    location: str,
    videos_base: Optional[Path] = None,
) -> Path:
    if videos_base is None:
        folder_name = f"{capture_date} {safe_destination_component(location, 'Untitled')}"
        return photos_base.expanduser() / folder_name
    return planned_media_dest_dir("photo", capture_date, location, photos_base, videos_base)


def make_video_dest_dir(
    videos_base: Path,
    capture_date: str,
    location: str = "Untitled",
    photos_base: Optional[Path] = None,
) -> Path:
    if photos_base is None:
        folder_name = f"{capture_date} {safe_destination_component(location, 'Untitled')}"
        return videos_base.expanduser() / folder_name
    return planned_media_dest_dir("video", capture_date, location, photos_base, videos_base)


def write_report(report_path: Path, summary: Dict[str, Any], files: List[Dict[str, Any]]) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
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
            if exists:
                capture_date = capture_date_from_mtime(st)
            else:
                capture_date = capture_date_fallback_without_exiftool(file_path, st)

        dest_dir = planned_media_dest_dir(media_type, capture_date, location, photos_base, videos_base)

        decision = "KNOWN" if exists else "NEW"
        copy_status = "SKIPPED" if exists else "PENDING"
        dest_path = str(dest_dir / filename)

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

    state_dir = get_state_dir_from_conn(conn)
    final_report_path = state_dir / "reports" / job_id
    write_report(final_report_path, summary, rows_for_report)

    finalize_job_scan(conn, job_id, summary, final_report_path)
    conn.commit()
    if scan_progress:
        scan_progress("Scan complete.", 100.0)

    return summary
