from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Optional

from .common import ensure_dir, has_command, make_job_id


def detect_swiftdialog_binary() -> Optional[str]:
    candidates = []
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
        ]
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=max(1, int(timeout_seconds)),
            )
        except subprocess.TimeoutExpired:
            return "@TIMEOUT"
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
                if choice in ("", "@TIMEOUT", "@CLOSED"):
                    return choice
            return choice

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
    summary: dict[str, Any],
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
            try:
                proc = subprocess.run(
                    [
                        dialog_bin,
                        "--title",
                        title,
                        "--message",
                        overview,
                        "--button1text",
                        "Import New",
                        "--button2text",
                        "Skip",
                        "--infobuttontext",
                        "Open Report",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=max(1, int(timeout_seconds)),
                )
            except subprocess.TimeoutExpired:
                return "@TIMEOUT"

            rc = proc.returncode
            if rc == 4:
                return "@TIMEOUT"
            if rc == 20:
                return "@TIMEOUT"
            if rc in (5, 10):
                return "Skip"
            if rc == 3:
                subprocess.run(["open", str(report_md)], check=False)
                continue
            if rc == 0:
                return "Import New"
            if rc == 2:
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
            f'default button "Import New" giving up after {int(timeout_seconds)}'
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
            close_first=False,
            prefer_swiftdialog=False,
        )
        if choice == "Open Report":
            subprocess.run(["open", str(report_md)], check=False)
            continue
        return choice


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
