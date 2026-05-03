import Foundation
import Testing

@testable import SDImportCore

@Suite("MediaScanner and ImportEngine")
struct MediaScannerImportTests {
    @Test("scan import and rescan marks the same source as known")
    func scanImportAndRescanUsesDedupe() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_0001.JPG")
        try fixture.writeFile(source, bytes: Data("sample-image-bytes".utf8))

        let summary1 = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-1")
        )

        #expect(summary1.scannedFiles == 1)
        #expect(summary1.newFiles == 1)
        #expect(summary1.knownFiles == 0)

        let result = try fixture.importEngine.importFiles(jobID: "job-1")

        #expect(result.importedFiles == 1)
        #expect(result.failedFiles == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.photosURL
                    .appendingPathComponent("2024-07-15 TEST", isDirectory: true)
                    .appendingPathComponent("IMG_0001.JPG")
                    .path
            )
        )

        let summary2 = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-2")
        )

        #expect(summary2.newFiles == 0)
        #expect(summary2.knownFiles == 1)
    }

    @Test("same size and mtime camera neighbors both import")
    func sameSizeAndMtimeNeighborsBothImport() throws {
        let fixture = try Fixture()
        let first = fixture.mountURL.appendingPathComponent("DCIM/100MSDCF/DSC03912.ARW")
        let second = fixture.mountURL.appendingPathComponent("DCIM/100MSDCF/DSC03913.ARW")
        try fixture.writeFile(first, bytes: Data(repeating: 1, count: 1024))
        try fixture.writeFile(second, bytes: Data(repeating: 2, count: 1024))

        let summary1 = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-neighbor-collision")
        )
        let result = try fixture.importEngine.importFiles(jobID: "job-neighbor-collision")

        #expect(summary1.newFiles == 2)
        #expect(summary1.knownFiles == 0)
        #expect(result.importedFiles == 2)
        #expect(result.skippedFiles == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.photosURL
                    .appendingPathComponent("2024-07-15 TEST", isDirectory: true)
                    .appendingPathComponent("DSC03912.ARW")
                    .path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.photosURL
                    .appendingPathComponent("2024-07-15 TEST", isDirectory: true)
                    .appendingPathComponent("DSC03913.ARW")
                    .path
            )
        )

        let summary2 = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-neighbor-rescan")
        )

        #expect(summary2.newFiles == 0)
        #expect(summary2.knownFiles == 2)
    }

    @Test("scanner classifies existing different destination as conflict and import copies with suffix")
    func conflictDestinationCopiesWithSuffix() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_0001.JPG")
        try fixture.writeFile(source, bytes: Data("sample-image-bytes".utf8))

        let destinationDirectory = fixture.photosURL.appendingPathComponent("2024-07-15 TEST", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let existingDestination = destinationDirectory.appendingPathComponent("IMG_0001.JPG")
        try Data("different-existing-file".utf8).write(to: existingDestination)

        let summary = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-conflict")
        )
        let result = try fixture.importEngine.importFiles(jobID: "job-conflict")

        #expect(summary.conflictFiles == 1)
        #expect(result.importedFiles == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: destinationDirectory
                    .appendingPathComponent("IMG_0001-copy-1.JPG")
                    .path
            )
        )
    }

    @Test("missing source after scan records a failed file")
    func missingSourceRecordsFailedFile() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_0001.JPG")
        try fixture.writeFile(source, bytes: Data("sample-image-bytes".utf8))

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-missing-source")
        )
        try FileManager.default.removeItem(at: source)

        let result = try fixture.importEngine.importFiles(jobID: "job-missing-source")
        let files = try fixture.jobRepository.fetchJobFiles(jobID: "job-missing-source")

        #expect(result.failedFiles == 1)
        #expect(files.first?.copyStatus == .failed)
        #expect(files.first?.error == "source file missing")
    }

    @Test("import emits byte progress speed and current file")
    func importEmitsProgressDetails() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_0002.JPG")
        try fixture.writeFile(source, bytes: Data(repeating: 7, count: 3 * 1024 * 1024))

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-progress")
        )

        var progressEvents: [ImportProgress] = []
        let result = try fixture.importEngine.importFiles(jobID: "job-progress") { progress in
            progressEvents.append(progress)
        }

        let finalProgress = try #require(progressEvents.last)
        #expect(result.importedFiles == 1)
        #expect(progressEvents.count >= 3)
        #expect(progressEvents.contains { $0.currentFilename == "IMG_0002.JPG" })
        #expect(progressEvents.contains { $0.currentDestinationPath?.hasSuffix("IMG_0002.JPG") == true })
        #expect(finalProgress.status == "completed")
        #expect(finalProgress.percent == 100)
        #expect(finalProgress.processedBytes == finalProgress.totalBytes)
        #expect(finalProgress.throughputBytesPerSecond > 0)
        #expect(
            finalProgress.recentFiles.contains {
                $0.filename == "IMG_0002.JPG" && $0.status == .copied && $0.detail == "Verified"
            }
        )

        let report = try String(contentsOf: fixture.reportsURL.appendingPathComponent("job-progress.md"))
        #expect(report.contains("## Copied Files"))
        #expect(report.contains("Verified"))
    }

    @Test("import checks destination space before copying")
    func importChecksDestinationSpaceBeforeCopying() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_FULL.JPG")
        try fixture.writeFile(source, bytes: Data(repeating: 7, count: 1_024))

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-no-space")
        )

        let photosPath = fixture.photosURL.path
        let constrainedEngine = ImportEngine(
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository,
            destinationSpaceChecker: DestinationSpaceChecker { _ in
                VolumeCapacity(
                    volumeID: "photos-volume",
                    displayPath: photosPath,
                    availableBytes: 512,
                    totalBytes: 1_024
                )
            }
        )

        do {
            _ = try constrainedEngine.importFiles(jobID: "job-no-space")
            Issue.record("import should have failed before copying")
        } catch SDImportError.insufficientDestinationSpace(let path, let requiredBytes, let availableBytes) {
            #expect(path == fixture.photosURL.path)
            #expect(requiredBytes == 1_024)
            #expect(availableBytes == 512)
        }

        let maybeJob = try fixture.jobRepository.fetchJob(id: "job-no-space")
        let job = try #require(maybeJob)
        #expect(job.status == .scanned)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.photosURL
                    .appendingPathComponent("2024-07-15 TEST", isDirectory: true)
                    .appendingPathComponent("IMG_FULL.JPG")
                    .path
            ) == false
        )
    }

    @Test("planned footage backup sidecars import as flat files")
    func plannedFootageBackupSidecarsImport() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.XML")
        try fixture.writeFile(source, bytes: Data("<clip>metadata</clip>".utf8))

        let summary = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-sidecar")
        )
        let scannedFiles = try fixture.jobRepository.fetchJobFiles(jobID: "job-sidecar")
        let sidecar = try #require(scannedFiles.first)
        let fileID = try #require(sidecar.id)
        let destinationURL = fixture.videosURL
            .appendingPathComponent("2024-07-15 TEST", isDirectory: true)
            .appendingPathComponent("Card CARD", isDirectory: true)
            .appendingPathComponent("C0001.XML", isDirectory: false)

        try fixture.jobRepository.updateJobFileImportPlan(
            jobID: "job-sidecar",
            updates: [
                JobFilePlanUpdate(
                    id: fileID,
                    decision: .new,
                    destinationDirectory: destinationURL.deletingLastPathComponent().path,
                    plannedDestinationPath: destinationURL.path,
                    copyStatus: .pending,
                    error: nil
                )
            ]
        )

        let result = try fixture.importEngine.importFiles(jobID: "job-sidecar")

        #expect(summary.unsupportedFiles == 1)
        #expect(sidecar.mediaKind == .unsupported)
        #expect(result.importedFiles == 1)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test("retry imports failed file and refreshes job totals")
    func retryImportsFailedFileAndRefreshesTotals() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_RETRY.JPG")
        let bytes = Data("retry-image-bytes".utf8)
        try fixture.writeFile(source, bytes: bytes)

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-retry")
        )
        try FileManager.default.removeItem(at: source)

        _ = try fixture.importEngine.importFiles(jobID: "job-retry")
        var maybeJob = try fixture.jobRepository.fetchJob(id: "job-retry")
        var job = try #require(maybeJob)
        #expect(job.failedFiles == 1)

        try fixture.writeFile(source, bytes: bytes)
        let retryResult = try fixture.importEngine.importFiles(jobID: "job-retry")
        let files = try fixture.jobRepository.fetchJobFiles(jobID: "job-retry")
        maybeJob = try fixture.jobRepository.fetchJob(id: "job-retry")
        job = try #require(maybeJob)

        #expect(retryResult.importedFiles == 1)
        #expect(job.importedFiles == 1)
        #expect(job.failedFiles == 0)
        #expect(job.status == .imported)
        #expect(files.first?.copyStatus == .copied)
    }

    @Test("retry preserves copied file history when another file failed")
    func retryPreservesCopiedFileHistory() throws {
        let fixture = try Fixture()
        let copiedSource = fixture.mountURL.appendingPathComponent("IMG_COPIED.JPG")
        let failedSource = fixture.mountURL.appendingPathComponent("IMG_FAILED.JPG")
        let copiedBytes = Data("copied-image-bytes".utf8)
        let failedBytes = Data("failed-image-bytes".utf8)
        try fixture.writeFile(copiedSource, bytes: copiedBytes)
        try fixture.writeFile(failedSource, bytes: failedBytes)

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-partial-retry")
        )
        try FileManager.default.removeItem(at: failedSource)

        let firstResult = try fixture.importEngine.importFiles(jobID: "job-partial-retry")
        let filesAfterFirstImport = try fixture.jobRepository.fetchJobFiles(jobID: "job-partial-retry")
        let copiedBeforeRetry = try #require(filesAfterFirstImport.first { $0.filename == "IMG_COPIED.JPG" })
        let copiedDestinationBeforeRetry = try #require(copiedBeforeRetry.finalDestinationPath)
        let copiedCompletedAtBeforeRetry = try #require(copiedBeforeRetry.completedAt)

        #expect(firstResult.importedFiles == 1)
        #expect(firstResult.failedFiles == 1)
        #expect(copiedBeforeRetry.copyStatus == .copied)

        try fixture.writeFile(failedSource, bytes: failedBytes)
        let retryResult = try fixture.importEngine.importFiles(jobID: "job-partial-retry")
        let filesAfterRetry = try fixture.jobRepository.fetchJobFiles(jobID: "job-partial-retry")
        let copiedAfterRetry = try #require(filesAfterRetry.first { $0.filename == "IMG_COPIED.JPG" })
        let failedAfterRetry = try #require(filesAfterRetry.first { $0.filename == "IMG_FAILED.JPG" })
        let maybeJob = try fixture.jobRepository.fetchJob(id: "job-partial-retry")
        let job = try #require(maybeJob)

        #expect(retryResult.importedFiles == 1)
        #expect(copiedAfterRetry.copyStatus == .copied)
        #expect(copiedAfterRetry.finalDestinationPath == copiedDestinationBeforeRetry)
        #expect(copiedAfterRetry.completedAt == copiedCompletedAtBeforeRetry)
        #expect(failedAfterRetry.copyStatus == .copied)
        #expect(job.importedFiles == 2)
        #expect(job.failedFiles == 0)
        #expect(job.status == .imported)
    }

    @Test("cancel during copy removes active part file and keeps file retryable")
    func cancelDuringCopyRemovesPartFile() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_CANCEL.JPG")
        try fixture.writeFile(source, bytes: Data(repeating: 3, count: 3 * 1024 * 1024))

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-cancel")
        )

        var shouldCancel = false
        do {
            _ = try fixture.importEngine.importFiles(
                jobID: "job-cancel",
                onProgress: { progress in
                    if progress.processedBytes > 0 {
                        shouldCancel = true
                    }
                },
                shouldCancel: {
                    shouldCancel
                }
            )
            Issue.record("import should have been cancelled")
        } catch SDImportError.cancelled {
        }

        let files = try fixture.jobRepository.fetchJobFiles(jobID: "job-cancel")
        let file = try #require(files.first)
        let maybeJob = try fixture.jobRepository.fetchJob(id: "job-cancel")
        let job = try #require(maybeJob)
        let partPath = try #require(file.plannedDestinationPath) + ".part"

        #expect(job.status == .cancelled)
        #expect(file.copyStatus == .pending)
        #expect(FileManager.default.fileExists(atPath: partPath) == false)
    }

    @Test("recovery marks interrupted import failed and removes known part files")
    func recoveryMarksInterruptedImportFailed() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_RECOVER.JPG")
        try fixture.writeFile(source, bytes: Data("recover-image-bytes".utf8))

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-recover")
        )
        let scannedFiles = try fixture.jobRepository.fetchJobFiles(jobID: "job-recover")
        let file = try #require(scannedFiles.first)
        let plannedPath = try #require(file.plannedDestinationPath)
        let partURL = URL(fileURLWithPath: plannedPath + ".part")
        try FileManager.default.createDirectory(
            at: partURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(to: partURL)
        try fixture.jobRepository.updateJobStatus(
            id: "job-recover",
            status: .importing,
            startedAt: Date()
        )

        let summary = try RecoveryService(jobRepository: fixture.jobRepository)
            .recoverInterruptedImports()
        let maybeRecoveredJob = try fixture.jobRepository.fetchJob(id: "job-recover")
        let recoveredJob = try #require(maybeRecoveredJob)
        let recoveredFiles = try fixture.jobRepository.fetchJobFiles(jobID: "job-recover")
        let recoveredFile = try #require(recoveredFiles.first)

        #expect(summary.recoveredJobs == 1)
        #expect(summary.removedPartFiles == 1)
        #expect(FileManager.default.fileExists(atPath: partURL.path) == false)
        #expect(recoveredJob.status == .failed)
        #expect(recoveredFile.copyStatus == .pending)
        #expect(recoveredFile.error == "interrupted import")
    }
}

private struct Fixture {
    let rootURL: URL
    let mountURL: URL
    let photosURL: URL
    let videosURL: URL
    let reportsURL: URL
    let jobRepository: JobRepository
    let dedupeRepository: DedupeRepository
    let scanner: MediaScanner
    let importEngine: ImportEngine

    init() throws {
        rootURL = try temporaryDirectory()
        mountURL = rootURL.appendingPathComponent("mount", isDirectory: true)
        photosURL = rootURL.appendingPathComponent("photos", isDirectory: true)
        videosURL = rootURL.appendingPathComponent("videos", isDirectory: true)
        reportsURL = rootURL.appendingPathComponent("reports", isDirectory: true)

        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photosURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videosURL, withIntermediateDirectories: true)

        let pool = try migratedPool()
        jobRepository = JobRepository(pool: pool)
        dedupeRepository = DedupeRepository(pool: pool)
        scanner = MediaScanner(
            captureDateReader: FixedCaptureDateReader(fixedDate: "2024-07-15"),
            jobRepository: jobRepository,
            dedupeRepository: dedupeRepository
        )
        importEngine = ImportEngine(
            jobRepository: jobRepository,
            dedupeRepository: dedupeRepository
        )
    }

    func scanRequest(jobID: String) -> ScanRequest {
        ScanRequest(
            mountURL: mountURL,
            volumeName: "CARD",
            location: "TEST",
            roots: DestinationRoots(photosURL: photosURL, videosURL: videosURL),
            reportsDirectoryURL: reportsURL,
            jobID: jobID
        )
    }

    func writeFile(_ url: URL, bytes: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

private struct FixedCaptureDateReader: CaptureDateReading {
    let fixedDate: String

    func captureDate(
        for fileURL: URL,
        mediaKind: MediaKind,
        attributes: FileAttributes
    ) -> String {
        fixedDate
    }
}
