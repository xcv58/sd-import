import Foundation
import GRDB
import Testing

@testable import SDImportCore

@Suite("Repositories")
struct RepositoryTests {
    @Test("scan-only jobs are not import history entries")
    func scanOnlyJobsAreNotImportHistoryEntries() {
        let scannedJob = ImportJob(
            id: "scan-only",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            mountPath: "/Volumes/CARD",
            location: "TEST",
            photosRoot: "/tmp/photos",
            videosRoot: "/tmp/videos",
            status: .scanned
        )
        let importedJob = ImportJob(
            id: "imported",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            mountPath: "/Volumes/CARD",
            location: "TEST",
            photosRoot: "/tmp/photos",
            videosRoot: "/tmp/videos",
            status: .imported
        )

        #expect(scannedJob.isImportHistoryEntry == false)
        #expect(importedJob.isImportHistoryEntry)
    }

    @Test("stores and fetches jobs and job files")
    func storesAndFetchesJobsAndFiles() throws {
        let pool = try migratedPool()
        let repository = JobRepository(pool: pool)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let job = ImportJob(
            id: "job-1",
            createdAt: createdAt,
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            volumeUUID: "uuid-1",
            location: "TEST",
            photosRoot: "/tmp/photos",
            videosRoot: "/tmp/videos",
            status: .scanned,
            scannedFiles: 1,
            newFiles: 1
        )

        try repository.insertJob(job)
        try repository.insertJobFile(
            JobFileRecord(
                jobID: "job-1",
                sourcePath: "/Volumes/CARD/DCIM/IMG_0001.JPG",
                relativePath: "DCIM/IMG_0001.JPG",
                filename: "IMG_0001.JPG",
                ext: ".jpg",
                size: 17,
                modificationDateString: "2023-11-14T22:13:20",
                mediaKind: .photo,
                fingerprint: "abc",
                captureDate: "2024-07-15",
                decision: .new,
                destinationDirectory: "/tmp/photos/2024-07-15 TEST",
                plannedDestinationPath: "/tmp/photos/2024-07-15 TEST/IMG_0001.JPG",
                copyStatus: .pending
            )
        )

        let fetchedJob = try repository.fetchJob(id: "job-1")
        let files = try repository.fetchJobFiles(jobID: "job-1")

        #expect(fetchedJob?.id == "job-1")
        #expect(fetchedJob?.status == .scanned)
        #expect(fetchedJob?.photosRoot == "/tmp/photos")
        #expect(files.count == 1)
        #expect(files.first?.decision == .new)
        #expect(files.first?.copyStatus == .pending)
    }

    @Test("lists import history jobs before applying the limit")
    func listsImportHistoryJobsBeforeApplyingLimit() throws {
        let pool = try migratedPool()
        let repository = JobRepository(pool: pool)

        try repository.insertJob(
            ImportJob(
                id: "imported",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                mountPath: "/Volumes/CARD",
                location: "TEST",
                photosRoot: "/tmp/photos",
                videosRoot: "/tmp/videos",
                status: .imported
            )
        )
        try repository.insertJob(
            ImportJob(
                id: "scan-only",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                mountPath: "/Volumes/CARD",
                location: "TEST",
                photosRoot: "/tmp/photos",
                videosRoot: "/tmp/videos",
                status: .scanned
            )
        )

        let jobs = try repository.listImportHistoryJobs(limit: 1)

        #expect(jobs.map(\.id) == ["imported"])
    }

    @Test("lists import history jobs by displayed timestamp")
    func listsImportHistoryJobsByDisplayedTimestamp() throws {
        let pool = try migratedPool()
        let repository = JobRepository(pool: pool)

        try repository.insertJob(
            ImportJob(
                id: "old-created-new-completed",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                completedAt: Date(timeIntervalSince1970: 1_700_000_300),
                mountPath: "/Volumes/CARD",
                location: "TEST",
                photosRoot: "/tmp/photos",
                videosRoot: "/tmp/videos",
                status: .imported
            )
        )
        try repository.insertJob(
            ImportJob(
                id: "new-created-old-display",
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                startedAt: Date(timeIntervalSince1970: 1_700_000_200),
                mountPath: "/Volumes/CARD",
                location: "TEST",
                photosRoot: "/tmp/photos",
                videosRoot: "/tmp/videos",
                status: .failed
            )
        )

        let jobs = try repository.listImportHistoryJobs(limit: 2)

        #expect(jobs.map(\.id) == ["old-created-new-completed", "new-created-old-display"])
    }

    @Test("records and checks dedupe items")
    func recordsAndChecksDedupeItems() throws {
        let pool = try migratedPool()
        let repository = DedupeRepository(pool: pool)
        let fingerprint = FileFingerprint.compute(
            size: 17,
            modificationDateString: "2023-11-14T22:13:20"
        )

        #expect(try repository.contains(fingerprint) == false)

        try repository.recordImported(
            fingerprint,
            jobID: "job-1",
            sourcePath: "/Volumes/CARD/DCIM/IMG_0001.JPG",
            firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(try repository.contains(fingerprint))
    }

    @Test("forgets imported fingerprints for a job")
    func forgetsImportedFingerprintsForJob() throws {
        let pool = try migratedPool()
        let jobRepository = JobRepository(pool: pool)
        let dedupeRepository = DedupeRepository(pool: pool)
        let fingerprint = FileFingerprint.compute(
            size: 17,
            modificationDateString: "2023-11-14T22:13:20",
            identityHint: "DCIM/IMG_0001.JPG"
        )

        try jobRepository.insertJob(
            ImportJob(
                id: "job-1",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                mountPath: "/Volumes/CARD",
                location: "TEST",
                photosRoot: "/tmp/photos",
                videosRoot: "/tmp/videos",
                status: .imported
            )
        )
        try jobRepository.insertJobFile(
            JobFileRecord(
                jobID: "job-1",
                sourcePath: "/Volumes/CARD/DCIM/IMG_0001.JPG",
                relativePath: "DCIM/IMG_0001.JPG",
                filename: "IMG_0001.JPG",
                ext: ".jpg",
                size: 17,
                modificationDateString: "2023-11-14T22:13:20",
                mediaKind: .photo,
                fingerprint: fingerprint.value,
                captureDate: "2024-07-15",
                decision: .new,
                destinationDirectory: "/tmp/photos/2024-07-15 TEST",
                plannedDestinationPath: "/tmp/photos/2024-07-15 TEST/IMG_0001.JPG",
                copyStatus: .copied
            )
        )

        try dedupeRepository.recordImported(
            fingerprint,
            jobID: "job-1",
            sourcePath: "/Volumes/CARD/DCIM/IMG_0001.JPG"
        )

        #expect(try dedupeRepository.contains(fingerprint))
        #expect(try dedupeRepository.forgetImportedFiles(jobID: "job-1") == 1)
        #expect(try dedupeRepository.contains(fingerprint) == false)
    }

    @Test("forgetting a job keeps fingerprints first imported by other jobs")
    func forgettingJobKeepsOtherJobFingerprints() throws {
        let pool = try migratedPool()
        let repository = DedupeRepository(pool: pool)
        let firstFingerprint = FileFingerprint.compute(
            size: 17,
            modificationDateString: "2023-11-14T22:13:20",
            identityHint: "DCIM/IMG_0001.JPG"
        )
        let secondFingerprint = FileFingerprint.compute(
            size: 19,
            modificationDateString: "2023-11-14T22:13:21",
            identityHint: "DCIM/IMG_0002.JPG"
        )

        try repository.recordImported(
            firstFingerprint,
            jobID: "job-1",
            sourcePath: "/Volumes/CARD/DCIM/IMG_0001.JPG"
        )
        try repository.recordImported(
            secondFingerprint,
            jobID: "job-2",
            sourcePath: "/Volumes/CARD/DCIM/IMG_0002.JPG"
        )

        #expect(try repository.forgetImportedFiles(jobID: "job-1") == 1)
        #expect(try repository.contains(firstFingerprint) == false)
        #expect(try repository.contains(secondFingerprint))
    }
}

func migratedPool() throws -> DatabasePool {
    let directoryURL = try temporaryDirectory()
    let databaseURL = directoryURL.appendingPathComponent("state.sqlite")
    return try DatabasePoolFactory(databaseURL: databaseURL).makeMigratedPool()
}
