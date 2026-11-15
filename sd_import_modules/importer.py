from __future__ import annotations

import ctypes
import datetime as dt
import errno
import hashlib
import os
import re
import shutil
import sqlite3
import stat
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Set, Tuple

from .common import (
    destination_key,
    ensure_dir,
    format_bytes,
    format_duration,
    metadata_fingerprint,
    now_local_iso,
    planned_media_dest_dir,
    write_json_atomic,
)
from .db import get_diskutil_info, get_state_dir_from_conn
from .ui import SwiftDialogProgressWindow, detect_swiftdialog_binary

TERMINAL_PROGRESS_STATES = {"completed", "completed_with_errors", "failed", "aborted", "idle"}
# Darwin provides an exclusive rename on the destination volume.
_RENAME_EXCL = 0x00000004
_darwin_rename = None
if sys.platform == "darwin":
    _darwin_rename = ctypes.CDLL(None, use_errno=True).renamex_np
    _darwin_rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    _darwin_rename.restype = ctypes.c_int

DATE_PATTERN = re.compile(r"(\d{4}-\d{2}-\d{2})")


def existing_hash_matches(path: Path, expected_hash: str, expected_size: int) -> bool:
    try:
        st = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(st.st_mode) or st.st_size != expected_size:
        return False
    existing_mtime = dt.datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds")
    return metadata_fingerprint(st.st_size, existing_mtime) == expected_hash


def unverified_destination_paths(conn: sqlite3.Connection) -> Set[str]:
    rejected = {row[0] for row in conn.execute("SELECT key FROM unverified_copy_paths")}
    rejected.update(destination_key(Path(row[0])) for row in conn.execute("SELECT target FROM exclusive_copy_attempts"))
    return rejected


def resolve_destination_path(
    candidate: Path, expected_hash: str, expected_size: int, unverified_paths: Optional[Set[str]] = None
) -> Tuple[Optional[Path], Optional[str]]:
    path, reason = destination_resolution(
        candidate, expected_hash, expected_size, lambda path: destination_key(path) in (unverified_paths or set())
    )
    return (None if reason else path), reason


def destination_resolution(
    candidate: Path, expected_hash: str, expected_size: int, reject_match: Callable[[Path], bool]
) -> Tuple[Path, Optional[str]]:
    if not os.path.lexists(candidate):
        return candidate, None

    if existing_hash_matches(candidate, expected_hash, expected_size) and not reject_match(candidate):
        return candidate, "already_exists_same_hash"

    stem = candidate.stem
    suffix = candidate.suffix
    parent = candidate.parent
    counter = 1

    while True:
        nxt = parent / f"{stem}-copy-{counter}{suffix}"
        if not os.path.lexists(nxt):
            return nxt, None
        if existing_hash_matches(nxt, expected_hash, expected_size) and not reject_match(nxt):
            return nxt, "already_exists_same_hash"
        counter += 1


def replan_pending_destinations(
    conn: sqlite3.Connection,
    job_id: str,
    photos_base: Path,
    videos_base: Path,
    location: Optional[str] = None,
) -> int:
    job_row = conn.execute(
        "SELECT location FROM jobs WHERE job_id=? LIMIT 1",
        (job_id,),
    ).fetchone()
    if not job_row:
        raise RuntimeError(f"job not found: {job_id}")

    shoot_location = (location or job_row["location"] or "Untitled").strip() or "Untitled"
    rows = conn.execute(
        """
        SELECT id, filename, media_type, mtime, dest_dir, dest_path
        FROM job_files
        WHERE job_id=?
          AND decision IN ('NEW', 'CONFLICT')
          AND (copy_status IS NULL OR copy_status IN ('PENDING', 'FAILED'))
        ORDER BY id
        """,
        (job_id,),
    ).fetchall()

    replanned = 0
    for row in rows:
        media_type = row["media_type"]
        if media_type not in ("photo", "video"):
            continue

        capture_date = capture_date_for_replan(row)
        dest_dir = planned_media_dest_dir(
            media_type,
            capture_date,
            shoot_location,
            photos_base,
            videos_base,
        )

        dest_path = dest_dir / row["filename"]
        conn.execute(
            """
            UPDATE job_files
            SET dest_dir=?,
                dest_path=?,
                copy_status='PENDING',
                error=NULL
            WHERE id=?
            """,
            (str(dest_dir), str(dest_path), row["id"]),
        )
        replanned += 1

    conn.commit()
    return replanned


def capture_date_for_replan(row: sqlite3.Row) -> str:
    for value in (row["dest_dir"], row["dest_path"]):
        match = DATE_PATTERN.search(str(value or ""))
        if match:
            return match.group(1)

    mtime = str(row["mtime"] or "")
    try:
        return dt.datetime.fromisoformat(mtime).date().isoformat()
    except ValueError:
        return dt.datetime.now().date().isoformat()


def copy_file_with_progress(
    src: Path,
    dst: Path,
    chunk_size: int = 16 * 1024 * 1024,
    on_chunk: Optional[Callable[[int], None]] = None,
    descriptor: Optional[int] = None,
) -> None:
    output = dst.open("wb") if descriptor is None else os.fdopen(os.dup(descriptor), "wb")
    with src.open("rb") as src_f, output as dst_f:
        while True:
            chunk = src_f.read(chunk_size)
            if not chunk:
                break
            dst_f.write(chunk)
            if on_chunk:
                on_chunk(len(chunk))
        if descriptor is not None:
            dst_f.flush()
            set_copy_metadata(dst_f.fileno(), os.fstat(src_f.fileno()))
    if descriptor is None:
        shutil.copystat(src, dst)


def publish_without_replacing(staging: Path, target: Path) -> bool:
    if _darwin_rename is not None:
        if _darwin_rename(os.fsencode(staging), os.fsencode(target), _RENAME_EXCL) == 0:
            return True
        code = ctypes.get_errno()
        if code not in (errno.ENOTSUP, errno.EOPNOTSUPP):
            raise OSError(code, os.strerror(code), str(target))

    # The caller owns staging and removes its name after an exclusive link.
    try:
        os.link(staging, target)
    except OSError as exc:
        if exc.errno not in (errno.ENOTSUP, errno.EOPNOTSUPP):
            raise
        return False
    return True


def entry_inode(info: os.stat_result) -> str:
    return f"{info.st_dev}:{info.st_ino}"


def entry_identity(info: os.stat_result) -> str:
    return f"{info.st_ino}:{getattr(info, 'st_birthtime', '')}"


def parent_identity(path: Path) -> str:
    info = path.stat()
    volume = str(info.st_dev)
    if sys.platform == "darwin":
        root = path.resolve()
        while root.parent != root and root.parent.stat().st_dev == info.st_dev:
            root = root.parent
        uuid = get_diskutil_info(str(root)).get("VolumeUUID")
        if uuid:
            volume = str(uuid)
    return f"{volume}:{entry_identity(info)}"


def file_digest(path: Path, descriptor: Optional[int] = None) -> str:
    digest = hashlib.sha256()
    handle = path.open("rb") if descriptor is None else os.fdopen(os.dup(descriptor), "rb")
    with handle:
        handle.seek(0)
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verified_destination_digest(path: Path, descriptor: int) -> Optional[str]:
    before = os.fstat(descriptor)
    digest = file_digest(path, descriptor)
    after = os.fstat(descriptor)
    try:
        named = path.lstat()
    except FileNotFoundError:
        return None
    if entry_inode(named) != entry_inode(after):
        return None
    original_state = (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
    if any((info.st_size, info.st_mtime_ns, info.st_ctime_ns) != original_state for info in (after, named)):
        return None
    return digest


def set_copy_metadata(descriptor: int, source: os.stat_result) -> None:
    os.utime(descriptor, ns=(source.st_atime_ns, source.st_mtime_ns))
    os.fchmod(descriptor, stat.S_IMODE(source.st_mode))


def copy_to_exclusive_destination(
    source: Path,
    target: Path,
    expected_size: int,
    did_create: Optional[Callable[[os.stat_result], None]] = None,
    expected_digest: Optional[str] = None,
) -> None:
    # ExFAT and similar volumes may lack both exclusive rename and hard links.
    with source.open("rb") as input_file, target.open("x+b") as output:
        owned = os.fstat(output.fileno())
        if did_create:
            did_create(owned)
        digest = hashlib.sha256()
        has_allocated_data = False
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            output.write(chunk)
            digest.update(chunk)
            if did_create and not has_allocated_data:
                output.flush()
                allocated = os.fstat(output.fileno())
                if entry_identity(allocated) != entry_identity(owned):
                    did_create(allocated)
                has_allocated_data = True
        output.flush()
        if os.fstat(output.fileno()).st_size != expected_size:
            raise RuntimeError("size mismatch after copy")
        if expected_digest is not None and digest.hexdigest() != expected_digest:
            raise RuntimeError("source changed during import")
        original = os.fstat(input_file.fileno())
        set_copy_metadata(output.fileno(), original)
        # On macOS setting an older modification time can adjust birth time.
        completed = os.fstat(output.fileno())
        if verified_destination_digest(target, output.fileno()) != digest.hexdigest():
            raise RuntimeError("destination changed during import")
        if did_create and entry_identity(completed) != entry_identity(owned):
            did_create(completed)


def recover_exclusive_destination(
    conn: sqlite3.Connection, file_id: int, expected_size: int, replanned_directory: Optional[Path]
) -> Optional[Path]:
    attempt = conn.execute(
        "SELECT * FROM exclusive_copy_attempts WHERE file_id=?", (file_id,)
    ).fetchone()
    if not attempt:
        return None
    target = Path(attempt["target"])
    try:
        same_parent = parent_identity(target.parent) == attempt["parent_identity"]
    except FileNotFoundError:
        same_parent = False
    if not same_parent:
        if replanned_directory is None or os.path.abspath(replanned_directory) == os.path.abspath(target.parent):
            raise OSError(errno.ENODEV, "The original destination directory is unavailable", str(target.parent))
        reject_unverified_destination(conn, file_id, target)
        return None

    try:
        descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        conn.execute("DELETE FROM exclusive_copy_attempts WHERE file_id=?", (file_id,))
        return None
    except OSError as exc:
        if exc.errno != errno.ELOOP:
            raise
        reject_unverified_destination(conn, file_id, target)
        return None
    try:
        info = os.fstat(descriptor)
        expected_inode = attempt["file_identity"].split(":", 1)[0]
        if stat.S_ISREG(info.st_mode) and str(info.st_ino) == expected_inode and info.st_size == expected_size:
            if verified_destination_digest(target, descriptor) == attempt["content_digest"]:
                os.utime(descriptor, ns=(attempt["atime_ns"], attempt["mtime_ns"]))
                os.fchmod(descriptor, attempt["mode"])
                if entry_inode(target.lstat()) == entry_inode(info):
                    return target
    finally:
        os.close(descriptor)
    reject_unverified_destination(conn, file_id, target)
    return None


def reject_unverified_destination(conn: sqlite3.Connection, file_id: int, target: Path) -> None:
    conn.execute(
        "INSERT OR IGNORE INTO unverified_copy_paths VALUES (?)", (destination_key(target),)
    )
    conn.execute("DELETE FROM exclusive_copy_attempts WHERE file_id=?", (file_id,))
    conn.commit()


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


def import_new_files(
    conn: sqlite3.Connection,
    job_id: str,
    show_progress_ui: bool = False,
    progress_window: Optional[SwiftDialogProgressWindow] = None,
    photos_base: Optional[Path] = None,
    videos_base: Optional[Path] = None,
    location: Optional[str] = None,
) -> Dict[str, Any]:
    if photos_base is not None or videos_base is not None:
        if photos_base is None or videos_base is None:
            raise RuntimeError("both photos_base and videos_base are required to replan destinations")
        replan_pending_destinations(conn, job_id, photos_base, videos_base, location=location)

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

    def record_copy(file_id: int, source: Path, target: Path, fingerprint: str, size: int) -> None:
        nonlocal imported_files, done_files, processed_bytes_done, copied_bytes_done
        nonlocal current_file, current_source_path, active_file_bytes
        conn.execute(
            "UPDATE job_files SET copy_status='COPIED', dest_dir=?, dest_path=?, error=NULL WHERE id=?",
            (str(target.parent), str(target), file_id),
        )
        conn.execute(
            "INSERT OR IGNORE INTO items (hash, size, first_seen_at, first_job_id, first_source_path) VALUES (?, ?, ?, ?, ?)",
            (fingerprint, size, now_local_iso(), job_id, str(source)),
        )
        conn.execute("DELETE FROM exclusive_copy_attempts WHERE file_id=?", (file_id,))
        imported_files += 1
        done_files += 1
        processed_bytes_done += size
        copied_bytes_done += size
        current_file = None
        current_source_path = None
        active_file_bytes = 0
        emit_progress(force=True)

    emit_progress(force=True)

    for row in rows:
        src = Path(row["src_path"])
        filename = row["filename"]
        expected_size = int(row["size"])
        try:
            replanned_directory = Path(row["dest_dir"]) if photos_base is not None and row["dest_dir"] else None
            recovered = recover_exclusive_destination(conn, row["id"], expected_size, replanned_directory)
        except OSError as exc:
            failed_files += 1
            done_files += 1
            processed_bytes_done += expected_size
            conn.execute("UPDATE job_files SET copy_status='FAILED', error=? WHERE id=?", (str(exc), row["id"]))
            emit_progress(force=True)
            continue
        if recovered is not None:
            record_copy(row["id"], src, recovered, row["hash"], expected_size)
            continue
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
        target, skip_reason = destination_resolution(
            candidate, expected_hash, expected_size,
            lambda path: destination_key(path) in unverified_destination_paths(conn),
        )

        if skip_reason:
            skipped_files += 1
            done_files += 1
            processed_bytes_done += expected_size
            conn.execute(
                "UPDATE job_files SET copy_status='SKIPPED', dest_dir=?, dest_path=?, error=? WHERE id=?",
                (str(target.parent), str(target), skip_reason, row["id"]),
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

        tmp_target: Optional[Path] = None
        descriptor: Optional[int] = None
        try:
            descriptor, tmp_path = tempfile.mkstemp(prefix=".sdimport-", suffix=".part", dir=target.parent)
            tmp_target = Path(tmp_path)

            def on_chunk(chunk_size: int) -> None:
                nonlocal active_file_bytes
                active_file_bytes = min(expected_size, active_file_bytes + chunk_size)
                emit_progress(force=False)

            copy_file_with_progress(src, tmp_target, on_chunk=on_chunk, descriptor=descriptor)
            staged = os.fstat(descriptor)
            if entry_inode(tmp_target.lstat()) != entry_inode(staged):
                raise RuntimeError("staging path changed during import")
            copied_size = staged.st_size
            if copied_size != expected_size:
                raise RuntimeError("size mismatch after copy")
            if not publish_without_replacing(tmp_target, target):
                expected_digest = file_digest(tmp_target, descriptor)
                tmp_target.unlink()
                os.close(descriptor)
                descriptor = None
                original = src.stat()
                target = target.parent.resolve() / target.name
                destination_parent = parent_identity(target.parent)

                def record_reservation(info: os.stat_result) -> None:
                    conn.execute(
                        "INSERT OR REPLACE INTO exclusive_copy_attempts VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        (row["id"], str(target), entry_identity(info),
                         destination_parent, expected_digest,
                         original.st_mtime_ns, original.st_atime_ns, stat.S_IMODE(original.st_mode)),
                    )
                    conn.commit()

                copy_to_exclusive_destination(src, target, expected_size, record_reservation, expected_digest)
            elif entry_inode(target.lstat()) != entry_inode(staged):
                raise RuntimeError("destination changed during publication")
        except Exception as exc:
            failed_files += 1
            done_files += 1
            processed_bytes_done += expected_size
            conn.execute(
                "UPDATE job_files SET copy_status='FAILED', error=? WHERE id=?",
                (str(exc), row["id"]),
            )
            current_file = None
            current_source_path = None
            active_file_bytes = 0
            emit_progress(force=True)
            continue
        finally:
            if descriptor is not None:
                try:
                    if tmp_target is not None and entry_inode(tmp_target.lstat()) == entry_inode(os.fstat(descriptor)):
                        tmp_target.unlink()
                except FileNotFoundError:
                    pass
                finally:
                    os.close(descriptor)

        record_copy(row["id"], src, target, expected_hash, expected_size)

    totals = conn.execute(
        """
        SELECT
          SUM(CASE WHEN copy_status='COPIED' THEN 1 ELSE 0 END) AS imported_files,
          SUM(CASE WHEN copy_status='SKIPPED' THEN 1 ELSE 0 END) AS skipped_files,
          SUM(CASE WHEN copy_status='FAILED' THEN 1 ELSE 0 END) AS failed_files
        FROM job_files
        WHERE job_id=?
        """,
        (job_id,),
    ).fetchone()
    job_imported_files = int(totals["imported_files"] or 0) if totals else 0
    job_skipped_files = int(totals["skipped_files"] or 0) if totals else 0
    job_failed_files = int(totals["failed_files"] or 0) if totals else 0

    conn.execute(
        """
        UPDATE jobs
        SET imported_files = ?,
            skipped_files = ?,
            failed_files = ?,
            status = CASE WHEN ? > 0 THEN 'IMPORTED_WITH_ERRORS' ELSE 'IMPORTED' END
        WHERE job_id=?
        """,
        (job_imported_files, job_skipped_files, job_failed_files, job_failed_files, job_id),
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
