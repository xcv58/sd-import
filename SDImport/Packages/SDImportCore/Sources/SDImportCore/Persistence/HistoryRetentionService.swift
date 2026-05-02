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

        for path in reportPaths where fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }

        try pool.write { db in
            for candidate in candidates {
                try db.execute(
                    sql: "DELETE FROM jobs WHERE job_id = ?",
                    arguments: [candidate.jobID]
                )
            }
        }

        return RetentionPruneSummary(
            matchedJobs: candidates.count,
            deletedJobs: candidates.count,
            deletedReports: reportCount,
            dryRun: false
        )
    }

    private func candidates(olderThan cutoff: Date) throws -> [PruneCandidate] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT job_id, summary_json_path, summary_markdown_path
                FROM jobs
                WHERE created_at < ?
                ORDER BY created_at
                """,
                arguments: [DateCoding.string(from: cutoff)]
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
