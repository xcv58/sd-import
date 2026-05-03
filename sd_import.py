#!/usr/bin/env python3
"""
Deterministic SD card importer for macOS.

This file now focuses on CLI orchestration and command routing.
Core logic is split into modules under sd_import_modules/:
- db.py
- scan.py
- importer.py
- ui.py
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional

from sd_import_modules.common import (
    atomic_write_text,
    detect_diskutil_binary,
    ensure_dir,
    format_bytes,
    format_duration,
    has_command,
    load_json,
    make_job_id,
    metadata_fingerprint,
    now_local_iso,
    read_json_file,
    today_iso,
    write_json_atomic,
)
from sd_import_modules.db import (
    begin_job,
    connect_db,
    discover_removable_mounts,
    finalize_job_scan,
    get_diskutil_info,
    get_state_dir_from_conn,
    list_jobs,
    prune_history,
    should_debounce_mount,
)
from sd_import_modules.importer import (
    TERMINAL_PROGRESS_STATES,
    copy_file_with_progress,
    existing_hash_matches,
    format_progress_line,
    import_new_files,
    latest_progress_path,
    progress_path_for_job,
    resolve_destination_path,
)
from sd_import_modules.scan import (
    _parse_date_from_text,
    capture_date_fallback_without_exiftool,
    capture_date_for_file,
    capture_date_from_exiftool,
    capture_date_from_mdls,
    capture_date_from_mtime,
    capture_dates_from_exiftool_batch,
    choose_location,
    classify_ext,
    iter_files,
    make_photo_dest_dir,
    make_video_dest_dir,
    scan_mount as core_scan_mount,
    write_report,
)
from sd_import_modules.ui import (
    SwiftDialogProgressWindow,
    detect_swiftdialog_binary,
    show_import_preview_decision,
    show_info_notification,
    show_prompt_notification,
    start_persistent_status_window,
)


def scan_mount(
    conn: sqlite3.Connection,
    mount_path: Path,
    location: str,
    photos_base: Path,
    videos_base: Path,
    job_id: Optional[str] = None,
    scan_progress: Optional[Callable[[str, Optional[float]], None]] = None,
) -> Dict[str, Any]:
    return core_scan_mount(
        conn=conn,
        mount_path=mount_path,
        location=location,
        photos_base=photos_base,
        videos_base=videos_base,
        job_id=job_id,
        scan_progress=scan_progress,
    )


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
    pending_copy_files = int(summary.get("new_files", 0)) + int(summary.get("conflict_files", 0))
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
        if args.notify and persistent_window is None and pending_copy_files > 0:
            persistent_window = start_persistent_status_window(
                state_dir=state_dir,
                title="SD Import",
                message=f"{summary['volume_name']}\nPreparing files...",
                progress_text="Starting copy...",
            )
        result = import_new_files(
            conn,
            summary["job_id"],
            show_progress_ui=(args.notify and persistent_window is None and pending_copy_files > 0),
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
                message=f"{m['volume_name']} mounted with supported media. Scan it now?",
                actions="Scan This Card",
                close_label="Skip",
                timeout_seconds=120,
                close_first=False,
                prefer_swiftdialog=True,
                allow_legacy_fallback=False,
            )
            if continue_choice == "Scan This Card":
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
