import Foundation
import Testing

@testable import SDImportCore

@Suite("HistoryRetentionService")
struct HistoryRetentionServiceTests {
    @Test("prunes old jobs and reports without deleting dedupe items")
    func prunesOldJobsAndReportsWithoutDeletingDedupeItems() throws {
        let pool = try migratedPool()
        let repository = JobRepository(pool: pool)
        let dedupeRepository = DedupeRepository(pool: pool)
        let rootURL = try temporaryDirectory()
        let oldReportURL = rootURL.appendingPathComponent("old.md")
        let newReportURL = rootURL.appendingPathComponent("new.md")
        try Data("old".utf8).write(to: oldReportURL)
        try Data("new".utf8).write(to: newReportURL)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-40 * 24 * 60 * 60)
        let newDate = now.addingTimeInterval(-5 * 24 * 60 * 60)
        let fingerprint = FileFingerprint.compute(size: 10, modificationDateString: "2024-01-01T00:00:00")

        try repository.insertJob(
            job(id: "old-job", createdAt: oldDate, reportPath: oldReportURL.path)
        )
        try repository.insertJobFile(
            file(jobID: "old-job", fingerprint: fingerprint.value)
        )
        try repository.insertJob(
            job(id: "new-job", createdAt: newDate, reportPath: newReportURL.path)
        )
        try dedupeRepository.recordImported(
            fingerprint,
            jobID: "old-job",
            sourcePath: "/Volumes/CARD/OLD.JPG"
        )

        let service = HistoryRetentionService(pool: pool, now: { now })
        let dryRun = try service.prune(policy: .days(30), dryRun: true)

        #expect(dryRun.matchedJobs == 1)
        #expect(dryRun.deletedJobs == 0)
        #expect(try repository.fetchJob(id: "old-job") != nil)

        let summary = try service.prune(policy: .days(30), dryRun: false)

        #expect(summary.deletedJobs == 1)
        #expect(summary.deletedReports == 1)
        #expect(try repository.fetchJob(id: "old-job") == nil)
        #expect(try repository.fetchJob(id: "new-job") != nil)
        #expect(FileManager.default.fileExists(atPath: oldReportURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: newReportURL.path))
        #expect(try dedupeRepository.contains(fingerprint))
    }

    private func job(id: String, createdAt: Date, reportPath: String) -> ImportJob {
        ImportJob(
            id: id,
            createdAt: createdAt,
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            location: "TEST",
            photosRoot: "/tmp/photos",
            videosRoot: "/tmp/videos",
            status: .imported,
            scannedFiles: 1,
            newFiles: 1,
            importedFiles: 1,
            summaryMarkdownPath: reportPath
        )
    }

    private func file(jobID: String, fingerprint: String) -> JobFileRecord {
        JobFileRecord(
            jobID: jobID,
            sourcePath: "/Volumes/CARD/IMG.JPG",
            relativePath: "IMG.JPG",
            filename: "IMG.JPG",
            ext: ".jpg",
            size: 10,
            modificationDateString: "2024-01-01T00:00:00",
            mediaKind: .photo,
            fingerprint: fingerprint,
            captureDate: "2024-01-01",
            decision: .new,
            destinationDirectory: "/tmp/photos/2024-01-01 TEST",
            plannedDestinationPath: "/tmp/photos/2024-01-01 TEST/IMG.JPG",
            finalDestinationPath: "/tmp/photos/2024-01-01 TEST/IMG.JPG",
            copyStatus: .copied
        )
    }
}
