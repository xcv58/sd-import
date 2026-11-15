import CryptoKit
import Darwin
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
                sql: """
                SELECT * FROM jobs
                WHERE status = ? OR EXISTS (
                    SELECT 1 FROM import_copy_attempts AS attempt
                    JOIN job_files AS file ON file.id = attempt.file_id
                    WHERE file.job_id = jobs.job_id
                )
                ORDER BY created_at DESC
                """,
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

    public func hasUnresolvedCopies(jobID: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM import_copy_attempts AS attempt
                    JOIN job_files AS file ON file.id = attempt.file_id
                    WHERE file.job_id = ? AND attempt.copy_committed = 0
                )
                """,
                arguments: [jobID]
            ) ?? false
        }
    }

    public func hasUnresolvedReviewedCopy(jobID: String) throws -> Bool {
        try copyAttempts(jobID: jobID).contains { !$0.localCopyCommitted && $0.requiresDestinationReview }
    }

    public func needsDestinationReview(jobID: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT needs_destination_review FROM jobs WHERE job_id = ?",
                arguments: [jobID]
            ) ?? false
        }
    }

    public func pendingFilesForImport(jobID: String) throws -> [JobFileRecord] {
        try fetchJobFiles(jobID: jobID).filter(\.isPendingImport)
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
        completedAt: Date? = Date(),
        needsDestinationReview: Bool? = nil
    ) throws {
        try pool.write { db in
            let totals = try recordingAwareTotals(jobID: jobID, db: db)
            try db.execute(
                sql: """
                UPDATE jobs
                SET imported_files = ?,
                    skipped_files = ?,
                    failed_files = ?,
                    new_files = ?,
                    known_files = ?,
                    unsupported_files = ?,
                    conflict_files = ?,
                    status = ?,
                    completed_at = ?,
                    needs_destination_review = COALESCE(?, needs_destination_review)
                WHERE job_id = ?
                """,
                arguments: [
                    totals.importedFiles,
                    totals.skippedFiles,
                    totals.failedFiles,
                    totals.newFiles,
                    totals.knownFiles,
                    totals.unsupportedFiles,
                    totals.conflictFiles,
                    finalStatus.databaseValue,
                    DateCoding.optionalString(from: completedAt),
                    needsDestinationReview,
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
        decision: FileDecision? = nil,
        knownSource: KnownFileSource? = nil,
        completedAt: Date? = Date()
    ) throws {
        try pool.write { db in
            try Self.writeFileCopyStatus(
                id: id, status: status, finalDestinationPath: finalDestinationPath,
                error: error, decision: decision, knownSource: knownSource, completedAt: completedAt, db: db
            )
        }
    }

    private static func writeFileCopyStatus(
        id: Int64,
        status: CopyStatus,
        finalDestinationPath: String?,
        error: String?,
        decision: FileDecision?,
        knownSource: KnownFileSource?,
        completedAt: Date?,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE job_files
            SET copy_status = ?,
                final_dest_path = COALESCE(?, final_dest_path),
                error = ?,
                decision = COALESCE(?, decision),
                known_source = COALESCE(?, known_source),
                completed_at = ?
            WHERE id = ?
            """,
            arguments: [
                status.databaseValue,
                finalDestinationPath,
                error,
                decision?.databaseValue,
                knownSource?.rawValue,
                DateCoding.optionalString(from: completedAt),
                id
            ]
        )
    }

    // Keep the lock inode in place so every process opens the same lock.
    public func withImportLock<T>(jobID: String, _ operation: () throws -> T) throws -> T? {
        let database = URL(fileURLWithPath: pool.path).resolvingSymlinksInPath()
        let directory = database.appendingPathExtension("import-locks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(jobID.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent(key).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw SDImportError.fileSystemError(operation: "open import lock", path: path, code: errno)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK { return nil }
            throw SDImportError.fileSystemError(operation: "lock import job", path: path, code: code)
        }
        return try operation()
    }

    func beginCopyAttempt(_ attempt: ImportCopyAttempt) throws {
        let data = try JSONEncoder().encode(attempt)
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO import_copy_attempts (file_id, attempt_json) VALUES (?, ?)",
                arguments: [attempt.fileID, data]
            )
        }
    }

    func markCopyStaged(_ attempt: ImportCopyAttempt) throws {
        let data = try JSONEncoder().encode(attempt)
        try pool.write { db in
            try db.execute(
                sql: "UPDATE import_copy_attempts SET attempt_json = ? WHERE file_id = ?",
                arguments: [data, attempt.fileID]
            )
            guard db.changesCount == 1 else {
                throw SDImportError.invalidDatabaseValue(column: "import_copy_attempts.file_id", value: String(attempt.fileID))
            }
        }
    }

    func copyAttempts(jobID: String) throws -> [ImportCopyAttempt] {
        try pool.read { db in
            try Data.fetchAll(
                db,
                sql: """
                SELECT attempt.attempt_json
                FROM import_copy_attempts AS attempt
                JOIN job_files AS file ON file.id = attempt.file_id
                WHERE file.job_id = ?
                ORDER BY attempt.file_id
                """,
                arguments: [jobID]
            ).map { try JSONDecoder().decode(ImportCopyAttempt.self, from: $0) }
        }
    }

    func discardCopyAttempt(_ attempt: ImportCopyAttempt, needsDestinationReview: Bool = false) throws {
        try pool.write { db in
            if needsDestinationReview {
                try db.execute(
                    sql: "UPDATE jobs SET needs_destination_review = 1 WHERE job_id = ?",
                    arguments: [attempt.jobID]
                )
            }
            try Self.removeCopyAttempt(fileID: attempt.fileID, db: db)
        }
    }

    func rejectUnverifiedCopy(_ attempt: ImportCopyAttempt) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                UPDATE job_files
                SET unverified_destinations = json_insert(COALESCE(unverified_destinations, '[]'), '$[#]', ?)
                WHERE id = ?
                """,
                arguments: [attempt.destination.standardizedFileURL.path, attempt.fileID]
            )
            if attempt.requiresDestinationReview {
                try db.execute(
                    sql: "UPDATE jobs SET needs_destination_review = 1 WHERE job_id = ?",
                    arguments: [attempt.jobID]
                )
            }
            try Self.removeCopyAttempt(fileID: attempt.fileID, db: db)
        }
    }

    func commitCopyAttempt(_ attempt: ImportCopyAttempt) throws {
        try pool.write { db in
            try Self.writeFileCopyStatus(
                id: attempt.fileID, status: .copied, finalDestinationPath: attempt.destinationPath,
                error: nil, decision: nil, knownSource: nil, completedAt: Date(), db: db
            )
            try DedupeRepository.recordImported(
                attempt.fingerprint, jobID: attempt.jobID, sourcePath: attempt.sourcePath, db: db
            )
            if attempt.portableReceipt != nil {
                var pending = attempt
                pending.localCopyCommitted = true
                let data = try JSONEncoder().encode(pending)
                try db.execute(
                    sql: "UPDATE import_copy_attempts SET attempt_json = ?, copy_committed = 1 WHERE file_id = ?",
                    arguments: [data, attempt.fileID]
                )
            } else {
                try Self.removeCopyAttempt(fileID: attempt.fileID, db: db)
            }
        }
    }

    func recordDestinationSkip(
        fileID: Int64,
        jobID: String,
        sourcePath: String,
        fingerprint: FileFingerprint,
        reason: String
    ) throws {
        try pool.write { db in
            try Self.writeFileCopyStatus(
                id: fileID, status: .skipped, finalDestinationPath: nil, error: reason,
                decision: .known, knownSource: .destination, completedAt: Date(), db: db
            )
            try DedupeRepository.recordImported(fingerprint, jobID: jobID, sourcePath: sourcePath, db: db)
        }
    }

    private static func removeCopyAttempt(fileID: Int64, db: Database) throws {
        try db.execute(sql: "DELETE FROM import_copy_attempts WHERE file_id = ?", arguments: [fileID])
    }

    public func updateJobFileImportPlan(
        jobID: String,
        updates: [JobFilePlanUpdate]
    ) throws {
        try updateJobImportPlan(jobID: jobID, destinationRoots: nil, updates: updates)
    }

    public func updateJobImportPlan(
        jobID: String,
        destinationRoots: DestinationRoots?,
        updates: [JobFilePlanUpdate]
    ) throws {
        try pool.write { db in
            if let destinationRoots {
                try db.execute(
                    sql: """
                    UPDATE jobs
                    SET photos_root = ?,
                        videos_root = ?
                    WHERE job_id = ?
                    """,
                    arguments: [
                        destinationRoots.photosURL.path,
                        destinationRoots.videosURL.path,
                        jobID
                    ]
                )
            }

            for update in updates {
                try db.execute(
                    sql: """
                    UPDATE job_files
                    SET decision = ?,
                        known_source = CASE
                            WHEN ? != ? AND known_source = ? THEN NULL
                            ELSE COALESCE(?, known_source)
                        END,
                        dest_dir = ?,
                        dest_path = ?,
                        final_dest_path = NULL,
                        copy_status = ?,
                        error = ?,
                        portable_receipt_override = COALESCE(?, portable_receipt_override),
                        completed_at = NULL
                    WHERE job_id = ? AND id = ?
                    """,
                    arguments: [
                        update.decision.databaseValue,
                        update.decision.databaseValue,
                        FileDecision.known.databaseValue,
                        KnownFileSource.destination.rawValue,
                        update.knownSource?.rawValue,
                        update.destinationDirectory,
                        update.plannedDestinationPath,
                        update.copyStatus.databaseValue,
                        update.error,
                        update.portableReceiptOverride,
                        jobID,
                        update.id
                    ]
                )
            }

            let totals = try recordingAwareTotals(jobID: jobID, db: db)
            try db.execute(
                sql: """
                UPDATE jobs
                SET new_files = ?,
                    known_files = ?,
                    unsupported_files = ?,
                    conflict_files = ?
                WHERE job_id = ?
                """,
                arguments: [
                    totals.newFiles,
                    totals.knownFiles,
                    totals.unsupportedFiles,
                    totals.conflictFiles,
                    jobID
                ]
            )
        }
    }

    private func recordingAwareTotals(
        jobID: String,
        db: Database
    ) throws -> RecordingAwareScanCounts {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM job_files WHERE job_id = ? ORDER BY id",
            arguments: [jobID]
        )
        return RecordingAwareScanSummary.counts(files: try rows.map(decodeJobFile))
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
                job_id, src_path, rel_path, filename, ext, size, mtime, mtime_epoch_seconds,
                media_type, hash, capture_date, decision, known_source, dest_dir,
                dest_path, final_dest_path, copy_status, error, portable_receipt_override, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                file.jobID,
                file.sourcePath,
                file.relativePath,
                file.filename,
                file.ext,
                file.size,
                file.modificationDateString,
                file.modificationTimeEpochSeconds,
                file.mediaKind.rawValue,
                file.fingerprint,
                file.captureDate,
                file.decision.databaseValue,
                file.knownSource?.rawValue,
                file.destinationDirectory,
                file.plannedDestinationPath,
                file.finalDestinationPath,
                file.copyStatus.databaseValue,
                file.error,
                file.portableReceiptOverride ?? false,
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

        let unverifiedJSON: String? = row["unverified_destinations"]
        let unverifiedDestinationPaths = try unverifiedJSON.map {
            try JSONDecoder().decode([String].self, from: Data($0.utf8))
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
            modificationTimeEpochSeconds: row["mtime_epoch_seconds"],
            mediaKind: mediaKind,
            fingerprint: row["hash"],
            captureDate: row["capture_date"],
            decision: decision,
            knownSource: (row["known_source"] as String?).flatMap(KnownFileSource.init(rawValue:)),
            destinationDirectory: row["dest_dir"],
            plannedDestinationPath: row["dest_path"],
            finalDestinationPath: row["final_dest_path"],
            copyStatus: copyStatus,
            error: row["error"],
            portableReceiptOverride: row["portable_receipt_override"],
            completedAt: DateCoding.date(from: row["completed_at"]),
            unverifiedDestinationPaths: unverifiedDestinationPaths
        )
    }
}
