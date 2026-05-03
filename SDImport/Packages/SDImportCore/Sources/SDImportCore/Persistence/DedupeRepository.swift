import Foundation
import GRDB

public struct DedupeRepository {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func contains(_ fingerprint: FileFingerprint) throws -> Bool {
        try pool.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM items WHERE hash = ? AND size = ?",
                arguments: [fingerprint.value, fingerprint.size]
            ) ?? 0
            return count > 0
        }
    }

    public func recordImported(
        _ fingerprint: FileFingerprint,
        jobID: String,
        sourcePath: String,
        firstSeenAt: Date = Date()
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO items (
                    hash, size, first_seen_at, first_job_id, first_source_path
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    fingerprint.value,
                    fingerprint.size,
                    DateCoding.string(from: firstSeenAt),
                    jobID,
                    sourcePath
                ]
            )
        }
    }

    @discardableResult
    public func forgetImportedFiles(jobID: String) throws -> Int {
        try pool.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT hash, size
                FROM job_files
                WHERE job_id = ?
                    AND hash IS NOT NULL
                """,
                arguments: [jobID]
            )

            var deleted = 0
            for row in rows {
                try db.execute(
                    sql: "DELETE FROM items WHERE hash = ? AND size = ?",
                    arguments: [
                        row["hash"] as String,
                        row["size"] as Int64
                    ]
                )
                deleted += db.changesCount
            }

            return deleted
        }
    }
}
