import Foundation
import GRDB

public struct JobRepository {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public func insertScannedJob(_ job: ImportJob, files: [JobFileRecord]) throws {
        try pool.write { db in
            try insertJob(job, db: db)
            for file in files {
                try insertJobFile(file, db: db)
            }
        }
    }

    public func insertJob(_ job: ImportJob) throws {
        try pool.write { db in
            try insertJob(job, db: db)
        }
    }

    public func fetchJob(id: String) throws -> ImportJob? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM jobs WHERE job_id = ? LIMIT 1",
                arguments: [id]
            ) else {
                return nil
            }
            return try decodeJob(row)
        }
    }

    public func listJobs(limit: Int = 50) throws -> [ImportJob] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM jobs
                ORDER BY created_at DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return try rows.map(decodeJob)
        }
    }

    public func listImportHistoryJobs(limit: Int = 50) throws -> [ImportJob] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM jobs
                WHERE status != ?
                ORDER BY COALESCE(completed_at, started_at, created_at) DESC
                LIMIT ?
                """,
                arguments: [ImportJobStatus.scanned.databaseValue, limit]
            )
            return try rows.map(decodeJob)
        }
    }

    public func interruptedImportJobs() throws -> [ImportJob] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM jobs WHERE status = ? ORDER BY created_at DESC",
                arguments: [ImportJobStatus.importing.databaseValue]
            )
            return try rows.map(decodeJob)
        }
    }

    public func insertJobFile(_ file: JobFileRecord) throws {
        try pool.write { db in
            try insertJobFile(file, db: db)
        }
    }

    public func fetchJobFiles(jobID: String) throws -> [JobFileRecord] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM job_files WHERE job_id = ? ORDER BY id",
                arguments: [jobID]
            )
            return try rows.map(decodeJobFile)
        }
    }

    public func pendingFilesForImport(jobID: String) throws -> [JobFileRecord] {
        try fetchJobFiles(jobID: jobID).filter { file in
            (file.decision == .new || file.decision == .conflict)
                && (file.copyStatus == .pending || file.copyStatus == .failed)
        }
    }

    public func updateJobStatus(
        id: String,
        status: ImportJobStatus,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                UPDATE jobs
                SET status = ?,
                    started_at = COALESCE(?, started_at),
                    completed_at = COALESCE(?, completed_at)
                WHERE job_id = ?
                """,
                arguments: [
                    status.databaseValue,
                    DateCoding.optionalString(from: startedAt),
                    DateCoding.optionalString(from: completedAt),
                    id
                ]
            )
        }
    }

    public func addImportTotals(
        jobID: String,
        importedFiles: Int,
        skippedFiles: Int,
        failedFiles: Int,
        finalStatus: ImportJobStatus,
        completedAt: Date = Date()
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                UPDATE jobs
                SET imported_files = imported_files + ?,
                    skipped_files = skipped_files + ?,
                    failed_files = failed_files + ?,
                    status = ?,
                    completed_at = ?
                WHERE job_id = ?
                """,
                arguments: [
                    importedFiles,
                    skippedFiles,
                    failedFiles,
                    finalStatus.databaseValue,
                    DateCoding.string(from: completedAt),
                    jobID
                ]
            )
        }
    }

    public func refreshImportTotals(
        jobID: String,
        finalStatus: ImportJobStatus,
        completedAt: Date? = Date()
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                UPDATE jobs
                SET imported_files = (
                        SELECT COUNT(*) FROM job_files
                        WHERE job_id = ? AND copy_status = ?
                    ),
                    skipped_files = (
                        SELECT COUNT(*) FROM job_files
                        WHERE job_id = ? AND copy_status = ?
                    ),
                    failed_files = (
                        SELECT COUNT(*) FROM job_files
                        WHERE job_id = ? AND copy_status = ?
                    ),
                    status = ?,
                    completed_at = ?
                WHERE job_id = ?
                """,
                arguments: [
                    jobID,
                    CopyStatus.copied.databaseValue,
                    jobID,
                    CopyStatus.skipped.databaseValue,
                    jobID,
                    CopyStatus.failed.databaseValue,
                    finalStatus.databaseValue,
                    DateCoding.optionalString(from: completedAt),
                    jobID
                ]
            )
        }
    }

    public func resetPendingFilesAfterInterruption(jobID: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                UPDATE job_files
                SET copy_status = ?,
                    error = COALESCE(error, ?),
                    completed_at = NULL
                WHERE job_id = ?
                    AND decision IN (?, ?)
                    AND copy_status = ?
                """,
                arguments: [
                    CopyStatus.pending.databaseValue,
                    "interrupted import",
                    jobID,
                    FileDecision.new.databaseValue,
                    FileDecision.conflict.databaseValue,
                    CopyStatus.pending.databaseValue
                ]
            )
        }
    }

    public func updateFileCopyStatus(
        id: Int64,
        status: CopyStatus,
        finalDestinationPath: String? = nil,
        error: String? = nil,
        completedAt: Date? = Date()
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                UPDATE job_files
                SET copy_status = ?,
                    final_dest_path = COALESCE(?, final_dest_path),
                    error = ?,
                    completed_at = ?
                WHERE id = ?
                """,
                arguments: [
                    status.databaseValue,
                    finalDestinationPath,
                    error,
                    DateCoding.optionalString(from: completedAt),
                    id
                ]
            )
        }
    }

    public func updateJobFileImportPlan(
        jobID: String,
        updates: [JobFilePlanUpdate]
    ) throws {
        try pool.write { db in
            for update in updates {
                try db.execute(
                    sql: """
                    UPDATE job_files
                    SET decision = ?,
                        dest_dir = ?,
                        dest_path = ?,
                        final_dest_path = NULL,
                        copy_status = ?,
                        error = ?,
                        completed_at = NULL
                    WHERE job_id = ? AND id = ?
                    """,
                    arguments: [
                        update.decision.databaseValue,
                        update.destinationDirectory,
                        update.plannedDestinationPath,
                        update.copyStatus.databaseValue,
                        update.error,
                        jobID,
                        update.id
                    ]
                )
            }

            try db.execute(
                sql: """
                UPDATE jobs
                SET new_files = (
                        SELECT COUNT(*) FROM job_files
                        WHERE job_id = ? AND decision = ?
                    ),
                    known_files = (
                        SELECT COUNT(*) FROM job_files
                        WHERE job_id = ? AND decision = ?
                    ),
                    unsupported_files = (
                        SELECT COUNT(*) FROM job_files
                        WHERE job_id = ? AND decision = ?
                    ),
                    conflict_files = (
                        SELECT COUNT(*) FROM job_files
                        WHERE job_id = ? AND decision = ?
                    )
                WHERE job_id = ?
                """,
                arguments: [
                    jobID,
                    FileDecision.new.databaseValue,
                    jobID,
                    FileDecision.known.databaseValue,
                    jobID,
                    FileDecision.unsupported.databaseValue,
                    jobID,
                    FileDecision.conflict.databaseValue,
                    jobID
                ]
            )
        }
    }

    private func insertJob(_ job: ImportJob, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO jobs (
                job_id, created_at, started_at, completed_at, mount_path,
                volume_name, volume_uuid, location, photos_root, videos_root,
                status, scanned_files, new_files, known_files, unsupported_files,
                conflict_files, imported_files, skipped_files, failed_files,
                summary_json_path, summary_markdown_path, app_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                job.id,
                DateCoding.string(from: job.createdAt),
                DateCoding.optionalString(from: job.startedAt),
                DateCoding.optionalString(from: job.completedAt),
                job.mountPath,
                job.volumeName,
                job.volumeUUID,
                job.location,
                job.photosRoot,
                job.videosRoot,
                job.status.databaseValue,
                job.scannedFiles,
                job.newFiles,
                job.knownFiles,
                job.unsupportedFiles,
                job.conflictFiles,
                job.importedFiles,
                job.skippedFiles,
                job.failedFiles,
                job.summaryJSONPath,
                job.summaryMarkdownPath,
                job.appVersion
            ]
        )
    }

    private func insertJobFile(_ file: JobFileRecord, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO job_files (
                job_id, src_path, rel_path, filename, ext, size, mtime,
                media_type, hash, capture_date, decision, dest_dir, dest_path,
                final_dest_path, copy_status, error, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                file.jobID,
                file.sourcePath,
                file.relativePath,
                file.filename,
                file.ext,
                file.size,
                file.modificationDateString,
                file.mediaKind.rawValue,
                file.fingerprint,
                file.captureDate,
                file.decision.databaseValue,
                file.destinationDirectory,
                file.plannedDestinationPath,
                file.finalDestinationPath,
                file.copyStatus.databaseValue,
                file.error,
                DateCoding.optionalString(from: file.completedAt)
            ]
        )
    }

    private func decodeJob(_ row: Row) throws -> ImportJob {
        let statusValue: String = row["status"]
        guard let status = ImportJobStatus(databaseValue: statusValue) else {
            throw SDImportError.invalidDatabaseValue(column: "status", value: statusValue)
        }

        return ImportJob(
            id: row["job_id"],
            createdAt: DateCoding.date(from: row["created_at"]) ?? Date(timeIntervalSince1970: 0),
            startedAt: DateCoding.date(from: row["started_at"]),
            completedAt: DateCoding.date(from: row["completed_at"]),
            mountPath: row["mount_path"],
            volumeName: row["volume_name"],
            volumeUUID: row["volume_uuid"],
            location: row["location"],
            photosRoot: row["photos_root"],
            videosRoot: row["videos_root"],
            status: status,
            scannedFiles: row["scanned_files"],
            newFiles: row["new_files"],
            knownFiles: row["known_files"],
            unsupportedFiles: row["unsupported_files"],
            conflictFiles: row["conflict_files"],
            importedFiles: row["imported_files"],
            skippedFiles: row["skipped_files"],
            failedFiles: row["failed_files"],
            summaryJSONPath: row["summary_json_path"],
            summaryMarkdownPath: row["summary_markdown_path"],
            appVersion: row["app_version"]
        )
    }

    private func decodeJobFile(_ row: Row) throws -> JobFileRecord {
        let mediaValue: String = row["media_type"]
        let decisionValue: String = row["decision"]
        let copyStatusValue: String = row["copy_status"]

        guard let mediaKind = MediaKind(rawValue: mediaValue) else {
            throw SDImportError.invalidDatabaseValue(column: "media_type", value: mediaValue)
        }
        guard let decision = FileDecision(databaseValue: decisionValue) else {
            throw SDImportError.invalidDatabaseValue(column: "decision", value: decisionValue)
        }
        guard let copyStatus = CopyStatus(databaseValue: copyStatusValue) else {
            throw SDImportError.invalidDatabaseValue(column: "copy_status", value: copyStatusValue)
        }

        return JobFileRecord(
            id: row["id"],
            jobID: row["job_id"],
            sourcePath: row["src_path"],
            relativePath: row["rel_path"],
            filename: row["filename"],
            ext: row["ext"],
            size: row["size"],
            modificationDateString: row["mtime"],
            mediaKind: mediaKind,
            fingerprint: row["hash"],
            captureDate: row["capture_date"],
            decision: decision,
            destinationDirectory: row["dest_dir"],
            plannedDestinationPath: row["dest_path"],
            finalDestinationPath: row["final_dest_path"],
            copyStatus: copyStatus,
            error: row["error"],
            completedAt: DateCoding.date(from: row["completed_at"])
        )
    }
}
