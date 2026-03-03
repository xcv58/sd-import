import tempfile
import unittest
from pathlib import Path
import os
import sys
import json
import io
import argparse
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import sd_import  # noqa: E402


class PruneHistoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self.tmp.name)
        self.db_path = self.state_dir / "state.db"
        self.reports_dir = self.state_dir / "reports"
        self.reports_dir.mkdir(parents=True, exist_ok=True)
        self.conn = sd_import.connect_db(self.db_path)

        self.old_job_id = "old-job"
        self.new_job_id = "new-job"
        self.old_report_md = self.reports_dir / f"{self.old_job_id}.md"
        self.old_report_json = self.reports_dir / f"{self.old_job_id}.json"
        self.old_report_md.write_text("# old")
        self.old_report_json.write_text("{}")

        self._insert_job(
            job_id=self.old_job_id,
            created_at="2025-01-01T08:00:00-05:00",
            mount_path="/Volumes/OLD",
            report_path=str(self.old_report_md),
        )
        self._insert_job_file(job_id=self.old_job_id, src_path="/Volumes/OLD/DCIM/0001.JPG")

        self._insert_job(
            job_id=self.new_job_id,
            created_at="2026-03-01T08:00:00-05:00",
            mount_path="/Volumes/NEW",
            report_path=str(self.reports_dir / f"{self.new_job_id}.md"),
        )
        self._insert_job_file(job_id=self.new_job_id, src_path="/Volumes/NEW/DCIM/1001.JPG")

        self.conn.execute(
            """
            INSERT INTO items (hash, size, first_seen_at, first_job_id, first_source_path)
            VALUES (?, ?, ?, ?, ?)
            """,
            ("abcd", 1234, "2026-03-01T09:00:00-05:00", self.new_job_id, "/Volumes/NEW/DCIM/1001.JPG"),
        )
        self.conn.commit()

    def tearDown(self) -> None:
        self.conn.close()
        self.tmp.cleanup()

    def _insert_job(self, job_id: str, created_at: str, mount_path: str, report_path: str) -> None:
        self.conn.execute(
            """
            INSERT INTO jobs (job_id, created_at, mount_path, status, report_path)
            VALUES (?, ?, ?, 'SCANNED', ?)
            """,
            (job_id, created_at, mount_path, report_path),
        )

    def _insert_job_file(self, job_id: str, src_path: str) -> None:
        self.conn.execute(
            """
            INSERT INTO job_files (
                job_id, src_path, filename, ext, size, mtime, media_type, hash, decision, copy_status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                job_id,
                src_path,
                Path(src_path).name,
                ".jpg",
                1234,
                "2026-03-01T09:00:00-05:00",
                "photo",
                "abcd",
                "KNOWN",
                "SKIPPED",
            ),
        )

    def test_prune_dry_run_keeps_rows_and_reports(self) -> None:
        result = sd_import.prune_history(
            self.conn,
            cutoff_date="2025-06-01",
            vacuum=False,
            dry_run=True,
        )

        self.assertEqual(result["status"], "DRY_RUN")
        self.assertEqual(result["jobs_matched"], 1)
        self.assertEqual(result["job_files_matched"], 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 2)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM job_files").fetchone()[0], 2)
        self.assertTrue(self.old_report_md.exists())
        self.assertTrue(self.old_report_json.exists())

    def test_prune_deletes_old_jobs_job_files_and_reports(self) -> None:
        result = sd_import.prune_history(
            self.conn,
            cutoff_date="2025-06-01",
            vacuum=False,
            dry_run=False,
        )

        self.assertEqual(result["status"], "PRUNED")
        self.assertEqual(result["jobs_matched"], 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM job_files").fetchone()[0], 1)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM items").fetchone()[0], 1)

        old_exists = self.conn.execute("SELECT 1 FROM jobs WHERE job_id=?", (self.old_job_id,)).fetchone()
        new_exists = self.conn.execute("SELECT 1 FROM jobs WHERE job_id=?", (self.new_job_id,)).fetchone()
        self.assertIsNone(old_exists)
        self.assertIsNotNone(new_exists)

        self.assertFalse(self.old_report_md.exists())
        self.assertFalse(self.old_report_json.exists())

    def test_prune_with_no_matches_reports_nothing_to_prune(self) -> None:
        result = sd_import.prune_history(
            self.conn,
            cutoff_date="2024-01-01",
            vacuum=False,
            dry_run=False,
        )

        self.assertEqual(result["status"], "NOTHING_TO_PRUNE")
        self.assertEqual(result["jobs_matched"], 0)
        self.assertEqual(result["job_files_matched"], 0)
        self.assertEqual(self.conn.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 2)


class MetadataDedupeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.mount = self.root / "mount"
        self.photos = self.root / "photos"
        self.videos = self.root / "videos"
        self.mount.mkdir(parents=True, exist_ok=True)
        self.photos.mkdir(parents=True, exist_ok=True)
        self.videos.mkdir(parents=True, exist_ok=True)
        self.db_path = self.root / "state.db"
        self.conn = sd_import.connect_db(self.db_path)

    def tearDown(self) -> None:
        self.conn.close()
        self.tmp.cleanup()

    def test_scan_import_rescan_uses_metadata_fingerprint(self) -> None:
        file_path = self.mount / "IMG_0001.JPG"
        file_path.write_bytes(b"sample-image-bytes")
        fixed_mtime = 1_700_000_000
        os.utime(file_path, (fixed_mtime, fixed_mtime))

        summary1 = sd_import.scan_mount(
            conn=self.conn,
            mount_path=self.mount,
            location="TEST",
            photos_base=self.photos,
            videos_base=self.videos,
        )
        self.assertEqual(summary1["new_files"], 1)
        self.assertEqual(summary1["known_files"], 0)

        row = self.conn.execute(
            "SELECT hash, size, mtime FROM job_files WHERE job_id=? AND media_type='photo' LIMIT 1",
            (summary1["job_id"],),
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(
            row["hash"],
            sd_import.metadata_fingerprint(int(row["size"]), str(row["mtime"])),
        )

        import_result = sd_import.import_new_files(self.conn, summary1["job_id"])
        self.assertEqual(import_result["imported_files"], 1)
        self.assertEqual(import_result["failed_files"], 0)
        progress_path = Path(import_result["progress_path"])
        self.assertTrue(progress_path.exists())
        progress = json.loads(progress_path.read_text())
        self.assertEqual(progress["job_id"], summary1["job_id"])
        self.assertEqual(progress["status"], "completed")
        self.assertEqual(progress["total_files"], 1)
        self.assertEqual(progress["done_files"], 1)
        self.assertEqual(progress["imported_files"], 1)

        summary2 = sd_import.scan_mount(
            conn=self.conn,
            mount_path=self.mount,
            location="TEST",
            photos_base=self.photos,
            videos_base=self.videos,
        )
        self.assertEqual(summary2["new_files"], 0)
        self.assertEqual(summary2["known_files"], 1)


class CaptureDateTests(unittest.TestCase):
    def test_parse_date_from_text_supports_common_formats(self) -> None:
        self.assertEqual(sd_import._parse_date_from_text("2026-03-03"), "2026-03-03")
        self.assertEqual(sd_import._parse_date_from_text("2026:03:03 08:12:44"), "2026-03-03")
        self.assertIsNone(sd_import._parse_date_from_text("(null)"))

    def test_scan_mount_uses_capture_date_for_photo_and_video_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mount = root / "mount"
            photos = root / "photos"
            videos = root / "videos"
            db_path = root / "state.db"
            mount.mkdir(parents=True, exist_ok=True)
            photos.mkdir(parents=True, exist_ok=True)
            videos.mkdir(parents=True, exist_ok=True)

            (mount / "IMG_0001.JPG").write_bytes(b"photo-bytes")
            (mount / "VID_0001.MP4").write_bytes(b"video-bytes")
            capture_map = {
                str(mount / "IMG_0001.JPG"): "2024-07-15",
                str(mount / "VID_0001.MP4"): "2024-07-15",
            }

            conn = sd_import.connect_db(db_path)
            try:
                with mock.patch("sd_import.capture_dates_from_exiftool_batch", return_value=capture_map):
                    summary = sd_import.scan_mount(
                        conn=conn,
                        mount_path=mount,
                        location="TEST",
                        photos_base=photos,
                        videos_base=videos,
                    )

                rows = conn.execute(
                    "SELECT media_type, dest_dir FROM job_files WHERE job_id=? ORDER BY media_type",
                    (summary["job_id"],),
                ).fetchall()
            finally:
                conn.close()

            by_type = {row["media_type"]: row["dest_dir"] for row in rows}
            self.assertEqual(by_type["photo"], str(photos / "2024-07-15 TEST"))
            self.assertEqual(by_type["video"], str(videos / "tmp-2024-07-15-videos"))


class ExifBatchTests(unittest.TestCase):
    def test_capture_dates_from_exiftool_batch(self) -> None:
        files = [(Path("/tmp/A.JPG"), "photo"), (Path("/tmp/B.MP4"), "video")]
        payload = [
            {"SourceFile": "/tmp/A.JPG", "DateTimeOriginal": "2024:07:15 10:00:00"},
            {"SourceFile": "/tmp/B.MP4", "MediaCreateDate": "2025:01:02 03:04:05"},
        ]
        with mock.patch("sd_import.shutil.which", return_value="/opt/homebrew/bin/exiftool"):
            with mock.patch("sd_import.subprocess.run", return_value=mock.Mock(stdout=json.dumps(payload), returncode=0)):
                result = sd_import.capture_dates_from_exiftool_batch(files, batch_size=10)

        self.assertEqual(result["/tmp/A.JPG"], "2024-07-15")
        self.assertEqual(result["/tmp/B.MP4"], "2025-01-02")


class StatusCommandTests(unittest.TestCase):
    def test_status_reads_latest_progress_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp)
            progress_dir = state_dir / "progress"
            progress_dir.mkdir(parents=True, exist_ok=True)
            payload = {
                "job_id": "job-1",
                "status": "copying",
                "percent": 42.5,
                "done_files": 3,
                "total_files": 10,
                "processed_bytes": 1234,
                "total_bytes": 9999,
                "throughput_bps": 1000,
                "eta_seconds": 8.0,
                "current_file": "VID_0001.MP4",
            }
            (progress_dir / "job-1.json").write_text(json.dumps(payload))

            args = argparse.Namespace(job_id=None, follow=False, interval=0.1, json_output=True)
            fake_stdout = io.StringIO()
            with mock.patch("sys.stdout", new=fake_stdout):
                exit_code = sd_import.command_status(args, state_dir)

            self.assertEqual(exit_code, 0)
            out_payload = json.loads(fake_stdout.getvalue())
            self.assertEqual(out_payload["job_id"], "job-1")
            self.assertEqual(out_payload["status"], "copying")


class PreviewDialogTests(unittest.TestCase):
    def test_swiftdialog_open_report_then_import(self) -> None:
        summary = {
            "volume_name": "CARD",
            "new_files": 2,
            "known_files": 10,
            "conflict_files": 1,
            "unsupported_files": 5,
        }
        report_md = Path("/tmp/fake-report.md")

        with mock.patch("sd_import.detect_swiftdialog_binary", return_value="/usr/local/bin/dialog"):
            with mock.patch("sd_import.subprocess.run") as mocked_run:
                dialog_calls = {"count": 0}

                def run_side_effect(cmd, *args, **kwargs):
                    if cmd and cmd[0] == "open":
                        return mock.Mock(returncode=0, stderr="")
                    if cmd and cmd[0] == "/usr/local/bin/dialog":
                        dialog_calls["count"] += 1
                        if dialog_calls["count"] == 1:
                            return mock.Mock(returncode=3, stderr="")  # Open Report (info button)
                        return mock.Mock(returncode=2, stderr="")  # Import New
                    return mock.Mock(returncode=0, stderr="")

                mocked_run.side_effect = run_side_effect
                choice = sd_import.show_import_preview_decision(summary, report_md, timeout_seconds=60)

        self.assertEqual(choice, "Import New")
        open_calls = [c for c in mocked_run.call_args_list if c.args and c.args[0] and c.args[0][0] == "open"]
        self.assertEqual(len(open_calls), 1)
        self.assertEqual(open_calls[0].args[0][1], str(report_md))

    def test_preview_no_legacy_fallback_returns_closed(self) -> None:
        summary = {
            "volume_name": "CARD",
            "new_files": 0,
            "known_files": 0,
            "conflict_files": 0,
            "unsupported_files": 0,
        }
        report_md = Path("/tmp/fake-report.md")

        with mock.patch("sd_import.detect_swiftdialog_binary", return_value=None):
            with mock.patch("sd_import.subprocess.run") as mocked_run:
                choice = sd_import.show_import_preview_decision(
                    summary,
                    report_md,
                    timeout_seconds=60,
                    use_swiftdialog=True,
                    allow_legacy_fallback=False,
                )

        self.assertEqual(choice, "@CLOSED")
        self.assertEqual(mocked_run.call_count, 0)


class PromptNotificationTests(unittest.TestCase):
    def test_prompt_no_legacy_fallback_returns_empty_when_swiftdialog_missing(self) -> None:
        with mock.patch("sd_import.detect_swiftdialog_binary", return_value=None):
            with mock.patch("sd_import.subprocess.run") as mocked_run:
                choice = sd_import.show_prompt_notification(
                    title="SD Card Inserted",
                    message="Continue?",
                    actions="Continue",
                    close_label="Skip",
                    timeout_seconds=30,
                    prefer_swiftdialog=True,
                    allow_legacy_fallback=False,
                )

        self.assertEqual(choice, "")
        self.assertEqual(mocked_run.call_count, 0)


class ProgressWindowTests(unittest.TestCase):
    def test_close_does_not_quit_window(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            command_file = Path(tmp) / "dialog-command.log"
            win = sd_import.SwiftDialogProgressWindow("/usr/local/bin/dialog", command_file)
            win.proc = mock.Mock()
            win.proc.poll.return_value = None

            win.close("Done")

            content = command_file.read_text()
            self.assertIn("progress: 100", content)
            self.assertIn("progresstext: Completed", content)
            self.assertIn("message: Done", content)
            self.assertNotIn("quit:", content)

    def test_quit_writes_quit_and_clears_proc(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            command_file = Path(tmp) / "dialog-command.log"
            win = sd_import.SwiftDialogProgressWindow("/usr/local/bin/dialog", command_file)
            proc = mock.Mock()
            proc.poll.return_value = None
            proc.wait.return_value = None
            win.proc = proc

            win.quit(wait_seconds=0.1)

            content = command_file.read_text()
            self.assertIn("quit:", content)
            self.assertIsNone(win.proc)

    def test_update_writes_even_if_proc_not_alive(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            command_file = Path(tmp) / "dialog-command.log"
            win = sd_import.SwiftDialogProgressWindow("/usr/local/bin/dialog", command_file)
            proc = mock.Mock()
            proc.poll.return_value = 0
            win.proc = proc

            win.update(percent=12.5, progress_text="Preparing...", message="Test message")

            content = command_file.read_text()
            self.assertIn("progress: 12", content)
            self.assertIn("progresstext: Preparing...", content)
            self.assertIn("message: Test message", content)


if __name__ == "__main__":
    unittest.main()
