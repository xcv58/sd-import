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

    func containsExactSource(
        _ fingerprint: FileFingerprint,
        sourcePath: String
    ) throws -> Bool {
        try pool.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM items
                WHERE hash = ? AND size = ? AND first_source_path = ?
                """,
                arguments: [fingerprint.value, fingerprint.size, sourcePath]
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
            try Self.recordImported(
                fingerprint, jobID: jobID, sourcePath: sourcePath, firstSeenAt: firstSeenAt, db: db
            )
        }
    }

    static func recordImported(
        _ fingerprint: FileFingerprint,
        jobID: String,
        sourcePath: String,
        firstSeenAt: Date = Date(),
        db: Database
    ) throws {
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

    @discardableResult
    public func forgetImportedFiles(jobID: String) throws -> Int {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM items WHERE first_job_id = ?",
                arguments: [jobID]
            )
            return db.changesCount
        }
    }
}
