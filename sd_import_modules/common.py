from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import shutil
import uuid
from pathlib import Path
from typing import Any, Dict, Optional


def now_local_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def today_iso() -> str:
    return dt.date.today().isoformat()


def make_job_id() -> str:
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def safe_destination_component(value: Optional[str], fallback: str) -> str:
    source = (value or "").strip() or fallback
    return source.replace("/", "-").replace(":", "-")


def destination_roots_match(photos_base: Path, videos_base: Path) -> bool:
    photos_path = os.path.abspath(os.path.expanduser(str(photos_base)))
    videos_path = os.path.abspath(os.path.expanduser(str(videos_base)))
    return os.path.normcase(photos_path) == os.path.normcase(videos_path)


def planned_media_dest_dir(
    media_type: str,
    capture_date: str,
    location: str,
    photos_base: Path,
    videos_base: Path,
) -> Path:
    if media_type not in ("photo", "video"):
        raise ValueError(f"unsupported media type for destination planning: {media_type}")

    folder_name = f"{capture_date} {safe_destination_component(location, 'Untitled')}"
    if destination_roots_match(photos_base, videos_base):
        folder_name += "-Photos" if media_type == "photo" else "-Video"

    root = photos_base if media_type == "photo" else videos_base
    return root.expanduser() / folder_name


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


def load_json(path: Path) -> Dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def has_command(name: str) -> bool:
    if shutil.which(name) is not None:
        return True
    fallback_paths = [
        Path.home() / ".local" / "bin" / name,
        Path.home() / "bin" / name,
    ]
    return any(p.exists() and os.access(p, os.X_OK) for p in fallback_paths)


def detect_diskutil_binary() -> Optional[str]:
    candidates = []
    in_path = shutil.which("diskutil")
    if in_path:
        candidates.append(in_path)
    candidates.extend(["/usr/sbin/diskutil", "/usr/bin/diskutil"])

    seen = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        p = Path(candidate)
        if p.exists() and os.access(p, os.X_OK):
            return candidate
    return None


def metadata_fingerprint(file_size: int, mtime_iso: str) -> str:
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
