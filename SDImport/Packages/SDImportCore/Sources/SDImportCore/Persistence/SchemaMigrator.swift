import Foundation
import GRDB

public enum SchemaMigrator {
    public static let currentUserVersion: Int32 = 10
    public static let initialMigrationIdentifier = "v1_initial_schema"
    public static let identityScopedFingerprintMigrationIdentifier = "v2_identity_scoped_fingerprints"
    public static let knownFileSourceMigrationIdentifier = "v3_known_file_source"
    public static let portableReceiptIdentityMigrationIdentifier = "v4_portable_receipt_identity"
    public static let destinationReviewMigrationIdentifier = "v5_destination_review"
    public static let copyAttemptMigrationIdentifier = "v6_copy_attempts"
    private static let unverifiedPathsMigrationIdentifier = "v7_unverified_copy_paths"

    private static let copyAttemptStateMigrationIdentifier = "v8_copy_attempt_state"
    private static let rescanOriginMigrationIdentifier = "v9_rescan_origin"
    private static let importHistoryActionsMigrationIdentifier = "v10_import_history_actions"

    public static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration(initialMigrationIdentifier) { db in
            try db.execute(sql: Self.initialSchemaSQL)
        }

        migrator.registerMigration(identityScopedFingerprintMigrationIdentifier) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT job_id, src_path, rel_path, filename, size, mtime
                FROM job_files
                WHERE copy_status = ?
                    AND hash IS NOT NULL
                """,
                arguments: [CopyStatus.copied.databaseValue]
            )

            let now = DateCoding.string(from: Date())
            for row in rows {
                let relativePath: String? = row["rel_path"]
                let filename: String = row["filename"]
                let size: Int64 = row["size"]
                let modificationDateString: String = row["mtime"]
                let fingerprint = FileFingerprint.compute(
                    size: size,
                    modificationDateString: modificationDateString,
                    identityHint: relativePath ?? filename
                )

                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO items (
                        hash, size, first_seen_at, first_job_id, first_source_path
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        fingerprint.value,
                        fingerprint.size,
                        now,
                        row["job_id"] as String,
                        row["src_path"] as String
                    ]
                )
            }

            try db.execute(sql: "PRAGMA user_version = 2")
        }

        migrator.registerMigration(knownFileSourceMigrationIdentifier) { db in
            try db.alter(table: "job_files") { table in
                table.add(column: "known_source", .text)
            }
            try db.execute(sql: "PRAGMA user_version = 3")
        }

        migrator.registerMigration(portableReceiptIdentityMigrationIdentifier) { db in
            try db.alter(table: "job_files") { table in
                table.add(column: "mtime_epoch_seconds", .integer)
                table.add(column: "portable_receipt_override", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
            try db.execute(sql: "PRAGMA user_version = 4")
        }

        migrator.registerMigration(destinationReviewMigrationIdentifier) { db in
            try db.alter(table: "jobs") { table in
                table.add(column: "needs_destination_review", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
            try db.execute(sql: "PRAGMA user_version = 5")
        }

        migrator.registerMigration(copyAttemptMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE import_copy_attempts (
                    file_id INTEGER PRIMARY KEY NOT NULL REFERENCES job_files(id) ON DELETE CASCADE,
                    attempt_json BLOB NOT NULL,
                    copy_committed BOOLEAN NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: "PRAGMA user_version = 6")
        }

        migrator.registerMigration(unverifiedPathsMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE unverified_copy_paths (key TEXT PRIMARY KEY NOT NULL);
                ALTER TABLE import_copy_attempts ADD COLUMN destination_key TEXT NOT NULL DEFAULT ''
                """)
            for row in try Row.fetchAll(db, sql: "SELECT file_id, attempt_json FROM import_copy_attempts") {
                let data: Data = row["attempt_json"]
                let attempt = try JSONDecoder().decode(ImportCopyAttempt.self, from: data)
                try db.execute(
                    sql: "UPDATE import_copy_attempts SET destination_key = ? WHERE file_id = ?",
                    arguments: [ConflictResolver.destinationKey(attempt.destination), attempt.fileID]
                )
            }
            // Earlier development builds scoped the same evidence to a job-file row.
            if try db.columns(in: "job_files").contains(where: { $0.name == "unverified_destinations" }) {
                for path in try String.fetchAll(db, sql: """
                    SELECT DISTINCT value FROM job_files, json_each(job_files.unverified_destinations)
                    """) {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO unverified_copy_paths VALUES (?)",
                        arguments: [ConflictResolver.destinationKey(URL(fileURLWithPath: path))]
                    )
                }
            }
            try db.execute(sql: "PRAGMA user_version = 7")
        }

        migrator.registerMigration(copyAttemptStateMigrationIdentifier) { db in
            // Restore the state column for a database opened by an earlier development build.
            if try !db.columns(in: "import_copy_attempts").contains(where: { $0.name == "copy_committed" }) {
                try db.execute(sql: """
                    ALTER TABLE import_copy_attempts ADD COLUMN copy_committed BOOLEAN NOT NULL DEFAULT 0;
                    UPDATE import_copy_attempts
                    SET copy_committed = COALESCE(json_extract(CAST(attempt_json AS TEXT), '$.localCopyCommitted'), 0)
                    """)
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_copy_attempts_uncommitted_destination
                ON import_copy_attempts(destination_key) WHERE copy_committed = 0
                """)
            try db.execute(sql: "PRAGMA user_version = 8")
        }

        migrator.registerMigration(rescanOriginMigrationIdentifier) { db in
            try db.execute(sql: """
                ALTER TABLE jobs ADD COLUMN volume_mount_path TEXT;
                ALTER TABLE jobs ADD COLUMN rescan_of_job_id TEXT;
                """)
            try db.execute(sql: "PRAGMA user_version = 9")
        }

        migrator.registerMigration(importHistoryActionsMigrationIdentifier) { db in
            try db.execute(sql: """
                ALTER TABLE jobs ADD COLUMN local_history_forgotten BOOLEAN NOT NULL DEFAULT 0;
                CREATE INDEX idx_items_first_job ON items(first_job_id);
                ALTER TABLE job_files ADD COLUMN reimport_requested BOOLEAN NOT NULL DEFAULT 0;
                """)
            try db.execute(sql: "PRAGMA user_version = \(Self.currentUserVersion)")
        }

        return migrator
    }

    public static func migrate(_ writer: any DatabaseWriter) throws {
        try makeMigrator().migrate(writer)
    }

    private static let initialSchemaSQL = """
    PRAGMA foreign_keys = ON;

    CREATE TABLE IF NOT EXISTS schema_migrations (
        identifier TEXT PRIMARY KEY NOT NULL,
        applied_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY NOT NULL,
        value_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS bookmarks (
        id TEXT PRIMARY KEY NOT NULL,
        purpose TEXT NOT NULL,
        bookmark_data BLOB NOT NULL,
        url TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS items (
        hash TEXT NOT NULL,
        size INTEGER NOT NULL,
        first_seen_at TEXT NOT NULL,
        first_job_id TEXT,
        first_source_path TEXT,
        PRIMARY KEY (hash, size)
    );

    CREATE TABLE IF NOT EXISTS jobs (
        job_id TEXT PRIMARY KEY NOT NULL,
        created_at TEXT NOT NULL,
        started_at TEXT,
        completed_at TEXT,
        mount_path TEXT NOT NULL,
        volume_name TEXT,
        volume_uuid TEXT,
        location TEXT NOT NULL,
        photos_root TEXT NOT NULL,
        videos_root TEXT NOT NULL,
        status TEXT NOT NULL,
        scanned_files INTEGER NOT NULL DEFAULT 0,
        new_files INTEGER NOT NULL DEFAULT 0,
        known_files INTEGER NOT NULL DEFAULT 0,
        unsupported_files INTEGER NOT NULL DEFAULT 0,
        conflict_files INTEGER NOT NULL DEFAULT 0,
        imported_files INTEGER NOT NULL DEFAULT 0,
        skipped_files INTEGER NOT NULL DEFAULT 0,
        failed_files INTEGER NOT NULL DEFAULT 0,
        summary_json_path TEXT,
        summary_markdown_path TEXT,
        app_version TEXT
    );

    CREATE TABLE IF NOT EXISTS job_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        job_id TEXT NOT NULL,
        src_path TEXT NOT NULL,
        rel_path TEXT,
        filename TEXT NOT NULL,
        ext TEXT NOT NULL,
        size INTEGER NOT NULL,
        mtime TEXT NOT NULL,
        media_type TEXT NOT NULL,
        hash TEXT,
        capture_date TEXT,
        decision TEXT NOT NULL,
        dest_dir TEXT,
        dest_path TEXT,
        final_dest_path TEXT,
        copy_status TEXT NOT NULL,
        error TEXT,
        completed_at TEXT,
        UNIQUE(job_id, src_path),
        FOREIGN KEY(job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_job_files_job_decision
        ON job_files(job_id, decision, copy_status);

    CREATE INDEX IF NOT EXISTS idx_job_files_hash_size
        ON job_files(hash, size);

    CREATE INDEX IF NOT EXISTS idx_jobs_created_at
        ON jobs(created_at);

    INSERT OR IGNORE INTO schema_migrations (identifier, applied_at)
    VALUES ('v1_initial_schema', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));

    PRAGMA user_version = 1;
    """
}
