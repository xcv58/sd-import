#!/usr/bin/env python3
"""
Deterministic SD card importer for macOS.

Features:
- Auto/mount trigger entrypoint for launchd.
- SQLite-backed dedupe by content hash and size.
- Interactive actionable notifications via alerter.
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
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

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


def now_local_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def today_iso() -> str:
    return dt.date.today().isoformat()


def make_job_id() -> str:
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def has_command(name: str) -> bool:
    if shutil.which(name) is not None:
        return True
    fallback_paths = [
        Path.home() / ".local" / "bin" / name,
        Path.home() / "bin" / name,
    ]
    return any(p.exists() and os.access(p, os.X_OK) for p in fallback_paths)


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def classify_ext(ext: str) -> Optional[str]:
    ext = ext.lower()
    if ext in VIDEO_EXTENSIONS:
        return "video"
    if ext in PHOTO_EXTENSIONS:
        return "photo"
    return None


def capture_date_from_mtime(stat_result: os.stat_result) -> str:
    return dt.datetime.fromtimestamp(stat_result.st_mtime).date().isoformat()


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

    disk_ids = plist.get("AllDisksAndPartitions", [])
    ignore_re = re.compile(ignore_volume_regex) if ignore_volume_regex else None

    for disk in disk_ids:
        dev = disk.get("DeviceIdentifier")
        if not dev:
            continue
        info = get_diskutil_info(f"/dev/{dev}")
        mount_path = info.get("MountPoint")
        if not mount_path:
            continue
        if info.get("RemovableMedia") is not True:
            continue

        volume_name = info.get("VolumeName") or Path(mount_path).name
        if ignore_re and ignore_re.search(volume_name):
            continue

        try:
            mounted_at = Path(mount_path).stat().st_mtime
        except FileNotFoundError:
            continue

        mounts.append(
            {
                "mount_path": mount_path,
                "volume_name": volume_name,
                "volume_uuid": info.get("VolumeUUID"),
                "mounted_at": mounted_at,
            }
        )

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


def make_video_dest_dir(videos_base: Path) -> Path:
    return videos_base / f"tmp-{today_iso()}-videos"


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
    return sha256_file(path) == expected_hash


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


def show_action_notification(title: str, message: str, report_path: Path) -> str:
    if has_command("alerter"):
        cmd = [
            "alerter",
            "--title",
            title,
            "--message",
            message,
            "--actions",
            "Review,Import New",
            "--closeLabel",
            "Skip",
            "--timeout",
            "120",
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        choice = (proc.stdout or "").strip()
        if choice == "Review":
            subprocess.run(["open", str(report_path)], check=False)
        return choice

    # Fallback to informational notification only.
    script = f'display notification "{message}" with title "{title}"'
    subprocess.run(["osascript", "-e", script], check=False)
    return ""


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


def scan_mount(
    conn: sqlite3.Connection,
    mount_path: Path,
    location: str,
    photos_base: Path,
    videos_base: Path,
    job_id: Optional[str] = None,
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

    for file_path in iter_files(mount_path):
        scanned_files += 1

        try:
            st = file_path.stat()
        except FileNotFoundError:
            continue

        ext = file_path.suffix.lower()
        media_type = classify_ext(ext)
        rel_path = str(file_path.relative_to(mount_path))
        filename = file_path.name
        mtime = dt.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds")

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

        content_hash = sha256_file(file_path)
        exists = conn.execute(
            "SELECT 1 FROM items WHERE hash=? AND size=? LIMIT 1",
            (content_hash, st.st_size),
        ).fetchone()

        if media_type == "photo":
            capture_date = capture_date_from_mtime(st)
            dest_dir = make_photo_dest_dir(photos_base, capture_date, location)
        else:
            dest_dir = make_video_dest_dir(videos_base)

        decision = "KNOWN" if exists else "NEW"
        copy_status = "SKIPPED" if exists else "PENDING"
        dest_path = str(dest_dir / filename)

        # Early conflict signal: destination file exists with different hash.
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

    return summary


def import_new_files(conn: sqlite3.Connection, job_id: str) -> Dict[str, Any]:
    rows = conn.execute(
        """
        SELECT id, src_path, filename, size, hash, dest_dir, decision, copy_status
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

    for row in rows:
        src = Path(row["src_path"])
        filename = row["filename"]
        expected_size = int(row["size"])
        expected_hash = row["hash"]
        dest_dir = Path(row["dest_dir"])

        if not src.exists():
            failed_files += 1
            conn.execute(
                "UPDATE job_files SET copy_status='FAILED', error=? WHERE id=?",
                ("source file missing", row["id"]),
            )
            continue

        ensure_dir(dest_dir)
        candidate = dest_dir / filename
        target, skip_reason = resolve_destination_path(candidate, expected_hash, expected_size)

        if target is None:
            skipped_files += 1
            conn.execute(
                "UPDATE job_files SET copy_status='SKIPPED', error=? WHERE id=?",
                (skip_reason, row["id"]),
            )
            conn.execute(
                "INSERT OR IGNORE INTO items (hash, size, first_seen_at, first_job_id, first_source_path) VALUES (?, ?, ?, ?, ?)",
                (expected_hash, expected_size, now_local_iso(), job_id, str(src)),
            )
            continue

        tmp_target = target.with_suffix(target.suffix + ".part")
        try:
            shutil.copy2(src, tmp_target)
            copied_hash = sha256_file(tmp_target)
            if copied_hash != expected_hash:
                raise RuntimeError("hash mismatch after copy")
            os.replace(tmp_target, target)
        except Exception as exc:
            failed_files += 1
            if tmp_target.exists():
                tmp_target.unlink(missing_ok=True)
            conn.execute(
                "UPDATE job_files SET copy_status='FAILED', error=? WHERE id=?",
                (str(exc), row["id"]),
            )
            continue

        imported_files += 1
        conn.execute(
            "UPDATE job_files SET copy_status='COPIED', dest_path=?, error=NULL WHERE id=?",
            (str(target), row["id"]),
        )
        conn.execute(
            "INSERT OR IGNORE INTO items (hash, size, first_seen_at, first_job_id, first_source_path) VALUES (?, ?, ?, ?, ?)",
            (expected_hash, expected_size, now_local_iso(), job_id, str(src)),
        )

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

    return {
        "job_id": job_id,
        "imported_files": imported_files,
        "skipped_files": skipped_files,
        "failed_files": failed_files,
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
    result = import_new_files(conn, args.job_id)
    print(json.dumps(result, indent=2))
    return 0


def command_retry(args: argparse.Namespace, conn: sqlite3.Connection) -> int:
    result = import_new_files(conn, args.job_id)
    print(json.dumps(result, indent=2))
    return 0


def command_run(args: argparse.Namespace, conn: sqlite3.Connection, config: Dict[str, Any]) -> int:
    mount_path = Path(args.input).expanduser().resolve()
    vol_info = get_diskutil_info(str(mount_path))
    location = choose_location(config, args.location, vol_info.get("VolumeName"))

    summary = scan_mount(
        conn=conn,
        mount_path=mount_path,
        location=location,
        photos_base=Path(args.photos_base).expanduser(),
        videos_base=Path(args.videos_base).expanduser(),
    )

    report_md = Path(conn.execute("SELECT report_path FROM jobs WHERE job_id=?", (summary["job_id"],)).fetchone()[0])

    message = (
        f"{summary['volume_name']}: {summary['new_files']} new, "
        f"{summary['known_files']} known, {summary['conflict_files']} conflicts"
    )

    choice = ""
    if args.notify:
        choice = show_action_notification("SD Import", message, report_md)

    if args.auto_import or choice == "Import New":
        result = import_new_files(conn, summary["job_id"])
        print(json.dumps({"summary": summary, "import": result}, indent=2))
        return 0

    if choice == "Review":
        # report already opened in notifier callback
        pass

    print(json.dumps({"summary": summary, "action": choice or "none"}, indent=2))
    return 0


def command_auto(args: argparse.Namespace, conn: sqlite3.Connection, config: Dict[str, Any]) -> int:
    mounts: List[Dict[str, Any]]
    if args.input:
        m = Path(args.input).expanduser().resolve()
        mounts = [{"mount_path": str(m), "volume_name": m.name, "volume_uuid": None, "mounted_at": m.stat().st_mtime}]
    else:
        mounts = discover_removable_mounts(config.get("ignore_volume_regex"))

    if not mounts:
        print("No removable mounted volumes found.")
        return 0

    selected = mounts if args.all_mounts else mounts[:1]
    exit_code = 0
    for m in selected:
        run_args = argparse.Namespace(
            input=m["mount_path"],
            location=args.location,
            photos_base=args.photos_base,
            videos_base=args.videos_base,
            notify=args.notify,
            auto_import=args.auto_import,
        )
        code = command_run(run_args, conn, config)
        if code != 0:
            exit_code = code
    return exit_code


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

    p_retry = sub.add_parser("retry", help="Retry failed/pending copies for a job")
    p_retry.add_argument("--job-id", required=True)

    p_run = sub.add_parser("run", help="Scan then optionally notify and import")
    p_run.add_argument("--input", required=True)
    p_run.add_argument("--notify", action="store_true", default=True)
    p_run.add_argument("--no-notify", dest="notify", action="store_false")
    p_run.add_argument("--auto-import", action="store_true", default=False)
    add_common_io(p_run)

    p_auto = sub.add_parser("auto", help="Pick removable mount(s) and run the same flow")
    p_auto.add_argument("--input", default=None, help="Optional explicit mount path (for debug)")
    p_auto.add_argument("--all-mounts", action="store_true", default=False)
    p_auto.add_argument("--notify", action="store_true", default=True)
    p_auto.add_argument("--no-notify", dest="notify", action="store_false")
    p_auto.add_argument("--auto-import", action="store_true", default=False)
    add_common_io(p_auto)

    p_mounts = sub.add_parser("list-mounts", help="List currently mounted removable volumes")
    p_mounts.add_argument("--json", dest="json_output", action="store_true", default=False)

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
        release_lock(lock_fd)


if __name__ == "__main__":
    raise SystemExit(main())
