import Foundation
import GRDB

public struct RetentionPruneSummary: Hashable, Codable, Sendable {
    public let matchedJobs: Int
    public let deletedJobs: Int
    public let deletedReports: Int
    public let dryRun: Bool

    public init(matchedJobs: Int, deletedJobs: Int, deletedReports: Int, dryRun: Bool) {
        self.matchedJobs = matchedJobs
        self.deletedJobs = deletedJobs
        self.deletedReports = deletedReports
        self.dryRun = dryRun
    }
}

public struct HistoryRetentionService {
    private let pool: DatabasePool
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        pool: DatabasePool,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.pool = pool
        self.fileManager = fileManager
        self.now = now
    }

    @discardableResult
    public func prune(policy: RetentionPolicy, dryRun: Bool = false) throws -> RetentionPruneSummary {
        guard let dayCount = policy.dayCount else {
            return RetentionPruneSummary(matchedJobs: 0, deletedJobs: 0, deletedReports: 0, dryRun: dryRun)
        }

        let cutoff = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -dayCount, to: now()) ?? now()
        let candidates = try candidates(olderThan: cutoff)
        let reportPaths = candidates.flatMap { [$0.summaryJSONPath, $0.summaryMarkdownPath] }.compactMap { $0 }
        let reportCount = reportPaths.filter { fileManager.fileExists(atPath: $0) }.count

        guard !dryRun else {
            return RetentionPruneSummary(
                matchedJobs: candidates.count,
                deletedJobs: 0,
                deletedReports: reportCount,
                dryRun: true
            )
        }

        let repository = JobRepository(pool: pool)
        var deletedJobs = 0
        var deletedReports = 0
        for candidate in candidates {
            let removedReports = try repository.withImportLock(jobID: candidate.jobID) { () -> Int? in
                let deleted = try pool.write { db in
                    try db.execute(
                        sql: "DELETE FROM jobs WHERE job_id = ? AND " + Self.prunableJobSQL,
                        arguments: [candidate.jobID, ImportJobStatus.importing.databaseValue]
                    )
                    return db.changesCount == 1
                }
                guard deleted else { return nil }
                var removed = 0
                for path in [candidate.summaryJSONPath, candidate.summaryMarkdownPath].compactMap({ $0 }) {
                    if (try? fileManager.removeItem(atPath: path)) != nil {
                        removed += 1
                    }
                }
                return removed
            }
            if let removedReports = removedReports ?? nil {
                deletedJobs += 1
                deletedReports += removedReports
            }
        }

        return RetentionPruneSummary(
            matchedJobs: candidates.count,
            deletedJobs: deletedJobs,
            deletedReports: deletedReports,
            dryRun: false
        )
    }

    private static let prunableJobSQL = """
        status != ? AND NOT EXISTS (
            SELECT 1 FROM import_copy_attempts AS attempt
            JOIN job_files AS file ON file.id = attempt.file_id
            WHERE file.job_id = jobs.job_id
        )
        """

    private func candidates(olderThan cutoff: Date) throws -> [PruneCandidate] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT job_id, summary_json_path, summary_markdown_path
                FROM jobs
                WHERE created_at < ? AND \(Self.prunableJobSQL)
                ORDER BY created_at
                """,
                arguments: [DateCoding.string(from: cutoff), ImportJobStatus.importing.databaseValue]
            )
            return rows.map { row in
                PruneCandidate(
                    jobID: row["job_id"],
                    summaryJSONPath: row["summary_json_path"],
                    summaryMarkdownPath: row["summary_markdown_path"]
                )
            }
        }
    }
}

private struct PruneCandidate {
    let jobID: String
    let summaryJSONPath: String?
    let summaryMarkdownPath: String?
}
