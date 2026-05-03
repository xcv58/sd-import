from __future__ import annotations

import json
import plistlib
import re
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from .common import detect_diskutil_binary, ensure_dir, now_local_iso

IMPORTABLE_EXTENSIONS = {
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
    ".mp4",
    ".mov",
    ".avi",
    ".mkv",
}

IGNORED_VOLUME_FRAGMENTS = (
    "time machine",
    "backup",
    "recovery",
    "preboot",
    "macintosh hd",
)


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
    diskutil_bin = detect_diskutil_binary()
    if not diskutil_bin:
        return {}
    try:
        proc = subprocess.run(
            [diskutil_bin, "info", "-plist", path],
            capture_output=True,
            text=False,
            check=True,
        )
        return plistlib.loads(proc.stdout)
    except Exception:
        return {}


def is_ignored_volume_name(volume_name: str) -> bool:
    lowercased = volume_name.lower()
    return any(fragment in lowercased for fragment in IGNORED_VOLUME_FRAGMENTS)


def mount_contains_importable_media(mount_path: str, max_files: int = 20_000) -> bool:
    inspected_files = 0
    try:
        for path in Path(mount_path).rglob("*"):
            if path.name.startswith("."):
                continue
            if not path.is_file():
                continue
            inspected_files += 1
            if path.suffix.lower() in IMPORTABLE_EXTENSIONS:
                return True
            if inspected_files >= max_files:
                return False
    except OSError:
        return False
    return False


def discover_removable_mounts(ignore_volume_regex: Optional[str]) -> List[Dict[str, Any]]:
    mounts: List[Dict[str, Any]] = []
    diskutil_bin = detect_diskutil_binary()
    if not diskutil_bin:
        return mounts
    try:
        proc = subprocess.run(
            [diskutil_bin, "list", "-plist"],
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

            bus_protocol = str(info.get("BusProtocol") or "")
            media_name = str(info.get("MediaName") or "")
            if bus_protocol == "Disk Image" or media_name == "Disk Image":
                continue

            volume_name = info.get("VolumeName") or Path(mount_path).name
            if is_ignored_volume_name(str(volume_name)):
                continue
            if ignore_re and ignore_re.search(volume_name):
                continue
            if not mount_contains_importable_media(mount_path):
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
