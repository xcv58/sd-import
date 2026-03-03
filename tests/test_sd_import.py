import tempfile
import unittest
from pathlib import Path
import sys


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


if __name__ == "__main__":
    unittest.main()
