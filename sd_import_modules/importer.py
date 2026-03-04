from __future__ import annotations

import datetime as dt
import os
import shutil
import sqlite3
import time
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Tuple

from .common import (
    ensure_dir,
    format_bytes,
    format_duration,
    metadata_fingerprint,
    now_local_iso,
    write_json_atomic,
)
from .db import get_state_dir_from_conn
from .ui import SwiftDialogProgressWindow, detect_swiftdialog_binary

TERMINAL_PROGRESS_STATES = {"completed", "completed_with_errors", "failed", "aborted", "idle"}


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
