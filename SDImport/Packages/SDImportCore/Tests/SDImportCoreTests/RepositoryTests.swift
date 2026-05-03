import Foundation
import GRDB
import Testing

@testable import SDImportCore

@Suite("Repositories")
struct RepositoryTests {
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
}

func migratedPool() throws -> DatabasePool {
    let directoryURL = try temporaryDirectory()
    let databaseURL = directoryURL.appendingPathComponent("state.sqlite")
    return try DatabasePoolFactory(databaseURL: databaseURL).makeMigratedPool()
}
