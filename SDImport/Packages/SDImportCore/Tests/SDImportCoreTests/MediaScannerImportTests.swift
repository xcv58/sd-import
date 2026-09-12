import Darwin
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

    @Test("portable receipts prevent duplicate imports on another Mac")
    func portableReceiptsWorkAcrossLocalDatabases() throws {
        let first = try Fixture()
        let source = first.mountURL.appendingPathComponent("DCIM/IMG_PORTABLE.JPG")
        try first.writeFile(source, bytes: Data("portable-image-bytes".utf8))

        let firstScanner = MediaScanner(
            captureDateReader: FixedCaptureDateReader(fixedDate: "2024-07-15"),
            jobRepository: first.jobRepository,
            dedupeRepository: first.dedupeRepository
        )
        let firstEngine = ImportEngine(
            jobRepository: first.jobRepository,
            dedupeRepository: first.dedupeRepository,
            portableReceiptsEnabled: true
        )
        _ = try firstScanner.scan(
            ScanRequest(
                mountURL: first.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: first.photosURL, videosURL: first.videosURL),
                reportsDirectoryURL: first.reportsURL,
                jobID: "job-portable-first",
                portableReceiptsEnabled: true
            )
        )
        let firstResult = try firstEngine.importFiles(jobID: "job-portable-first")
        #expect(firstResult.importedFiles == 1)
        #expect(firstResult.portableReceiptWarning == nil)

        let secondPool = try migratedPool()
        let secondJobRepository = JobRepository(pool: secondPool)
        let secondDedupeRepository = DedupeRepository(pool: secondPool)
        let secondPhotosURL = first.rootURL.appendingPathComponent("second-photos", isDirectory: true)
        let secondVideosURL = first.rootURL.appendingPathComponent("second-videos", isDirectory: true)
        let secondScanner = MediaScanner(
            captureDateReader: FixedCaptureDateReader(fixedDate: "2024-07-15"),
            jobRepository: secondJobRepository,
            dedupeRepository: secondDedupeRepository
        )

        let secondSummary = try secondScanner.scan(
            ScanRequest(
                mountURL: first.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: secondPhotosURL, videosURL: secondVideosURL),
                jobID: "job-portable-second",
                portableReceiptsEnabled: true
            )
        )
        let secondFiles = try secondJobRepository.fetchJobFiles(jobID: "job-portable-second")

        #expect(secondSummary.newFiles == 0)
        #expect(secondSummary.knownFiles == 1)
        #expect(secondSummary.portableKnownFiles == 1)
        #expect(secondFiles.first?.knownSource == .portableLedger)
    }

    @Test("import rechecks portable receipts added after scanning")
    func importRechecksPortableReceiptsAfterScan() throws {
        let fixture = try Fixture()
        let bytes = Data("stale-scan-image-bytes".utf8)
        let source = fixture.mountURL.appendingPathComponent("DCIM/IMG_STALE.JPG")
        try fixture.writeFile(source, bytes: bytes)
        _ = try fixture.scanner.scan(
            ScanRequest(
                mountURL: fixture.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: fixture.photosURL, videosURL: fixture.videosURL),
                jobID: "job-portable-stale",
                portableReceiptsEnabled: true
            )
        )

        let modificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        )
        let identity = PortableFileIdentity(
            size: Int64(bytes.count),
            modificationDate: modificationDate,
            relativePath: "DCIM/IMG_STALE.JPG"
        )
        try PortableImportReceiptLedger(sourceRootURL: fixture.mountURL).append(
            identity: identity
        )

        let photosPath = fixture.photosURL.path
        let engine = ImportEngine(
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository,
            destinationSpaceChecker: DestinationSpaceChecker { _ in
                VolumeCapacity(
                    volumeID: "no-space-needed",
                    displayPath: photosPath,
                    availableBytes: 0,
                    totalBytes: 0
                )
            },
            portableReceiptsEnabled: true
        )
        let result = try engine.importFiles(jobID: "job-portable-stale")
        let file = try #require(fixture.jobRepository.fetchJobFiles(jobID: "job-portable-stale").first)
        let maybeJob = try fixture.jobRepository.fetchJob(id: "job-portable-stale")
        let job = try #require(maybeJob)

        #expect(result.importedFiles == 0)
        #expect(result.skippedFiles == 1)
        #expect(file.copyStatus == .skipped)
        #expect(file.decision == .known)
        #expect(file.error == "already_imported_portable_receipt")
        #expect(file.knownSource == .portableLedger)
        let plan = ImportPlanBuilder(
            sessions: [],
            organizationPreset: .shootSessionsByDate,
            roots: DestinationRoots(
                photosURL: fixture.photosURL,
                videosURL: fixture.videosURL
            ),
            fallbackLocation: "TEST",
            volumeName: "CARD"
        ).plan(file: file)
        #expect(plan.status == "Other Mac")
        #expect(plan.willCopy == false)
        #expect(job.newFiles == 0)
        #expect(job.knownFiles == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.photosURL
                    .appendingPathComponent("2024-07-15 TEST", isDirectory: true)
                    .appendingPathComponent("IMG_STALE.JPG")
                    .path
            ) == false
        )
    }

    @Test("import preserves receipts appended before its own ledger write")
    func importReloadsAfterInterveningPortableAppend() throws {
        let fixture = try Fixture()
        let firstSource = fixture.mountURL.appendingPathComponent("DCIM/IMG_INTERLEAVE_A.JPG")
        let secondSource = fixture.mountURL.appendingPathComponent("DCIM/IMG_INTERLEAVE_B.JPG")
        try fixture.writeFile(firstSource, bytes: Data("first-interleaved-image".utf8))
        try fixture.writeFile(secondSource, bytes: Data("second-interleaved-image".utf8))

        _ = try fixture.scanner.scan(
            ScanRequest(
                mountURL: fixture.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: fixture.photosURL, videosURL: fixture.videosURL),
                reportsDirectoryURL: fixture.reportsURL,
                jobID: "job-portable-interleaved",
                portableReceiptsEnabled: true
            )
        )
        let scannedFiles = try fixture.jobRepository.fetchJobFiles(jobID: "job-portable-interleaved")
        let firstFile = try #require(scannedFiles.first)
        let secondFile = try #require(scannedFiles.dropFirst().first)
        let secondIdentity = PortableFileIdentity(
            size: secondFile.size,
            modificationTimeEpochSeconds: try #require(secondFile.modificationTimeEpochSeconds),
            relativePath: try #require(secondFile.relativePath)
        )
        let externalLedger = PortableImportReceiptLedger(sourceRootURL: fixture.mountURL)
        var firstFileProgressCount = 0
        var externalAppendError: Error?

        let result = try ImportEngine(
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository,
            portableReceiptsEnabled: true
        ).importFiles(jobID: "job-portable-interleaved") { progress in
            guard progress.currentSourcePath == firstFile.sourcePath else {
                return
            }
            firstFileProgressCount += 1
            guard firstFileProgressCount == 2 else {
                return
            }
            do {
                try externalLedger.append(identity: secondIdentity)
            } catch {
                externalAppendError = error
            }
        }

        if let externalAppendError {
            throw externalAppendError
        }
        let importedFiles = try fixture.jobRepository.fetchJobFiles(jobID: "job-portable-interleaved")
        let importedFirst = try #require(importedFiles.first { $0.id == firstFile.id })
        let importedSecond = try #require(importedFiles.first { $0.id == secondFile.id })

        #expect(firstFileProgressCount >= 2)
        #expect(result.importedFiles == 1)
        #expect(result.skippedFiles == 1)
        #expect(importedFirst.copyStatus == .copied)
        #expect(importedSecond.copyStatus == .skipped)
        #expect(importedSecond.decision == .known)
        #expect(importedSecond.knownSource == .portableLedger)
        #expect(importedSecond.error == "already_imported_portable_receipt")
    }

    @Test("source changes after scan require a rescan before portable dedupe")
    func changedSourceDoesNotMatchStalePortableReceipt() throws {
        let fixture = try Fixture()
        let originalBytes = Data("original".utf8)
        let changedBytes = Data("modified".utf8)
        #expect(originalBytes.count == changedBytes.count)
        let source = fixture.mountURL.appendingPathComponent("DCIM/IMG_CHANGED.JPG")
        try fixture.writeFile(source, bytes: originalBytes)
        _ = try fixture.scanner.scan(
            ScanRequest(
                mountURL: fixture.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: fixture.photosURL, videosURL: fixture.videosURL),
                jobID: "job-portable-source-changed",
                portableReceiptsEnabled: true
            )
        )
        let scannedFile = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-portable-source-changed").first
        )
        let scannedEpoch = try #require(scannedFile.modificationTimeEpochSeconds)
        try PortableImportReceiptLedger(sourceRootURL: fixture.mountURL).append(
            identity: PortableFileIdentity(
                size: Int64(originalBytes.count),
                modificationTimeEpochSeconds: scannedEpoch,
                relativePath: "DCIM/IMG_CHANGED.JPG"
            )
        )

        try changedBytes.write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(scannedEpoch + 60))],
            ofItemAtPath: source.path
        )

        let result = try ImportEngine(
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository,
            portableReceiptsEnabled: true
        ).importFiles(jobID: "job-portable-source-changed")
        let finalFile = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-portable-source-changed").first
        )

        #expect(result.importedFiles == 0)
        #expect(result.skippedFiles == 0)
        #expect(result.failedFiles == 1)
        #expect(finalFile.copyStatus == .failed)
        #expect(finalFile.error == "source changed since scan; rescan required")
        #expect(
            FileManager.default.fileExists(atPath: scannedFile.plannedDestinationPath ?? "") == false
        )
    }

    @Test("source identity changes do not block imports when portable receipts are disabled")
    func changedSourceImportsWithoutPortableReceipts() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("DCIM/IMG_CHANGED_DEFAULT.JPG")
        try fixture.writeFile(source, bytes: Data("unchanged-image-content".utf8))
        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-source-changed-default")
        )
        let scannedFile = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-source-changed-default").first
        )
        let scannedEpoch = try #require(scannedFile.modificationTimeEpochSeconds)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(scannedEpoch + 60))],
            ofItemAtPath: source.path
        )

        let result = try fixture.importEngine.importFiles(jobID: "job-source-changed-default")
        let finalFile = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-source-changed-default").first
        )

        #expect(result.importedFiles == 1)
        #expect(result.skippedFiles == 0)
        #expect(result.failedFiles == 0)
        #expect(finalFile.copyStatus == .copied)
        #expect(FileManager.default.fileExists(atPath: scannedFile.plannedDestinationPath ?? ""))
    }

    @Test("import anyway override bypasses an import-time portable receipt")
    func importAnywayBypassesPortableReceiptRecheck() throws {
        let fixture = try Fixture()
        let bytes = Data("portable-override-image-bytes".utf8)
        let source = fixture.mountURL.appendingPathComponent("DCIM/IMG_OVERRIDE.JPG")
        try fixture.writeFile(source, bytes: bytes)
        let modificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        )
        let identity = PortableFileIdentity(
            size: Int64(bytes.count),
            modificationDate: modificationDate,
            relativePath: "DCIM/IMG_OVERRIDE.JPG"
        )
        try PortableImportReceiptLedger(sourceRootURL: fixture.mountURL).append(
            identity: identity
        )
        _ = try fixture.scanner.scan(
            ScanRequest(
                mountURL: fixture.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: fixture.photosURL, videosURL: fixture.videosURL),
                jobID: "job-portable-override",
                portableReceiptsEnabled: true
            )
        )

        let file = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-portable-override").first
        )
        let fileID = try #require(file.id)
        #expect(file.knownSource == .portableLedger)
        try fixture.jobRepository.updateJobFileImportPlan(
            jobID: "job-portable-override",
            updates: [
                JobFilePlanUpdate(
                    id: fileID,
                    decision: .new,
                    destinationDirectory: nil,
                    plannedDestinationPath: nil,
                    copyStatus: .pending,
                    error: nil,
                    portableReceiptOverride: true
                )
            ]
        )

        let overriddenFile = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-portable-override").first
        )
        let builder = ImportPlanBuilder(
            sessions: [
                ImportPlanSession(
                    date: "2024-07-15",
                    label: "TEST",
                    photoCount: 1,
                    videoCount: 0,
                    unsupportedCount: 0,
                    includePhotos: true,
                    includeVideos: false,
                    includeSidecars: false
                )
            ],
            organizationPreset: .shootSessionsByDate,
            roots: DestinationRoots(photosURL: fixture.photosURL, videosURL: fixture.videosURL),
            fallbackLocation: "TEST",
            volumeName: "CARD"
        )
        try fixture.jobRepository.updateJobFileImportPlan(
            jobID: "job-portable-override",
            updates: builder.updates(files: [overriddenFile])
        )
        let replannedFile = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-portable-override").first
        )
        #expect(replannedFile.portableReceiptOverride == true)

        let result = try ImportEngine(
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository,
            portableReceiptsEnabled: true
        ).importFiles(jobID: "job-portable-override")

        #expect(result.importedFiles == 1)
        #expect(result.skippedFiles == 0)
        let importedFile = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-portable-override").first
        )
        let finalDestinationPath = try #require(importedFile.finalDestinationPath)
        #expect(
            FileManager.default.fileExists(atPath: finalDestinationPath)
        )
    }

    @Test("import uses persisted epoch instead of parsing the display timestamp")
    func importPortableIdentityUsesPersistedEpoch() throws {
        let fixture = try Fixture()
        let bytes = Data("epoch-identity-image-bytes".utf8)
        let source = fixture.mountURL.appendingPathComponent("DCIM/IMG_EPOCH.JPG")
        try fixture.writeFile(source, bytes: bytes)
        let modificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        )
        let epochSeconds = Int64(floor(modificationDate.timeIntervalSince1970))
        let relativePath = "DCIM/IMG_EPOCH.JPG"
        let identity = PortableFileIdentity(
            size: Int64(bytes.count),
            modificationTimeEpochSeconds: epochSeconds,
            relativePath: relativePath
        )
        try PortableImportReceiptLedger(sourceRootURL: fixture.mountURL).append(identity: identity)

        let jobID = "job-portable-epoch"
        try fixture.jobRepository.insertJob(
            ImportJob(
                id: jobID,
                createdAt: Date(),
                mountPath: fixture.mountURL.path,
                volumeName: "CARD",
                location: "TEST",
                photosRoot: fixture.photosURL.path,
                videosRoot: fixture.videosURL.path,
                status: .scanned,
                scannedFiles: 1,
                newFiles: 1
            )
        )
        let destinationDirectory = fixture.photosURL.appendingPathComponent("2024-07-15 TEST")
        try fixture.jobRepository.insertJobFile(
            JobFileRecord(
                jobID: jobID,
                sourcePath: source.path,
                relativePath: relativePath,
                filename: "IMG_EPOCH.JPG",
                ext: ".jpg",
                size: Int64(bytes.count),
                modificationDateString: "1970-01-01T00:00:00",
                modificationTimeEpochSeconds: epochSeconds,
                mediaKind: .photo,
                fingerprint: nil,
                captureDate: "2024-07-15",
                decision: .new,
                destinationDirectory: destinationDirectory.path,
                plannedDestinationPath: destinationDirectory.appendingPathComponent("IMG_EPOCH.JPG").path,
                copyStatus: .pending
            )
        )

        let result = try ImportEngine(
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository,
            portableReceiptsEnabled: true
        ).importFiles(jobID: jobID)

        #expect(result.importedFiles == 0)
        #expect(result.skippedFiles == 1)
        let file = try #require(fixture.jobRepository.fetchJobFiles(jobID: jobID).first)
        #expect(file.knownSource == .portableLedger)
    }

    @Test("enabling portable receipts backfills local dedupe history")
    func portableReceiptsBackfillLocalHistory() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_BACKFILL.JPG")
        let secondSource = fixture.mountURL.appendingPathComponent("IMG_BACKFILL_2.JPG")
        try fixture.writeFile(source, bytes: Data("backfill-image-bytes".utf8))
        try fixture.writeFile(secondSource, bytes: Data("second-backfill-image-bytes".utf8))

        _ = try fixture.scanner.scan(fixture.scanRequest(jobID: "job-backfill-import"))
        _ = try fixture.importEngine.importFiles(jobID: "job-backfill-import")
        let ledger = PortableImportReceiptLedger(sourceRootURL: fixture.mountURL)
        #expect(FileManager.default.fileExists(atPath: ledger.ledgerURL.path) == false)

        let summary = try fixture.scanner.scan(
            ScanRequest(
                mountURL: fixture.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: fixture.photosURL, videosURL: fixture.videosURL),
                jobID: "job-backfill-scan",
                portableReceiptsEnabled: true
            )
        )

        #expect(summary.knownFiles == 2)
        #expect(summary.portableKnownFiles == 0)
        #expect(try ledger.load().fingerprints.count == 2)
    }

    @Test("portable backfill requires an exact source path match")
    func portableBackfillRejectsNormalizedPathCollision() throws {
        let fixture = try Fixture()
        let bytes = Data("case-sensitive-backfill".utf8)
        let originalSource = fixture.mountURL.appendingPathComponent("DCIM/IMG_CASE.JPG")
        try fixture.writeFile(originalSource, bytes: bytes)
        let modificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: originalSource.path)[.modificationDate]
                as? Date
        )

        _ = try fixture.scanner.scan(fixture.scanRequest(jobID: "job-backfill-original"))
        _ = try fixture.importEngine.importFiles(jobID: "job-backfill-original")

        try FileManager.default.removeItem(at: originalSource)
        let caseDistinctSource = fixture.mountURL.appendingPathComponent("DCIM/img_case.jpg")
        try fixture.writeFile(caseDistinctSource, bytes: bytes)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: caseDistinctSource.path
        )

        let ledger = PortableImportReceiptLedger(sourceRootURL: fixture.mountURL)
        let summary = try fixture.scanner.scan(
            ScanRequest(
                mountURL: fixture.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(
                    photosURL: fixture.photosURL,
                    videosURL: fixture.videosURL
                ),
                jobID: "job-backfill-case-collision",
                portableReceiptsEnabled: true
            )
        )
        let file = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-backfill-case-collision").first
        )

        #expect(summary.knownFiles == 1)
        #expect(file.knownSource == .localLedger)
        #expect(try ledger.load().fingerprints.isEmpty)
        #expect(FileManager.default.fileExists(atPath: ledger.ledgerURL.path) == false)
    }

    @Test("invalid portable ledger warns but does not fail the scan")
    func invalidPortableLedgerDoesNotFailScan() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_WARNING.JPG")
        try fixture.writeFile(source, bytes: Data("warning-image-bytes".utf8))
        let ledger = PortableImportReceiptLedger(sourceRootURL: fixture.mountURL)
        try FileManager.default.createDirectory(at: ledger.ledgerURL, withIntermediateDirectories: true)

        let summary = try fixture.scanner.scan(
            ScanRequest(
                mountURL: fixture.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: fixture.photosURL, videosURL: fixture.videosURL),
                jobID: "job-portable-warning",
                portableReceiptsEnabled: true
            )
        )

        #expect(summary.newFiles == 1)
        #expect(summary.portableReceiptWarning?.contains("unavailable") == true)
    }

    @Test(
        "read-only source imports successfully with a portable history warning",
        .enabled(if: geteuid() != 0, "root bypasses POSIX write permissions")
    )
    func readOnlySourceDoesNotFailImport() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_READ_ONLY.JPG")
        try fixture.writeFile(source, bytes: Data("read-only-image-bytes".utf8))

        let scanner = MediaScanner(
            captureDateReader: FixedCaptureDateReader(fixedDate: "2024-07-15"),
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository
        )
        _ = try scanner.scan(
            ScanRequest(
                mountURL: fixture.mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: fixture.photosURL, videosURL: fixture.videosURL),
                jobID: "job-read-only",
                portableReceiptsEnabled: true
            )
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.mountURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.mountURL.path
            )
        }

        let engine = ImportEngine(
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository,
            portableReceiptsEnabled: true
        )
        let result = try engine.importFiles(jobID: "job-read-only")

        #expect(result.importedFiles == 1)
        #expect(result.failedFiles == 0)
        #expect(result.portableReceiptWarning?.contains("could not be updated") == true)
    }

    @Test("scanner recognizes common camera RAW extensions")
    func scannerRecognizesCommonCameraRawExtensions() throws {
        let fixture = try Fixture()
        for filename in ["SONY_0001.ARW", "CANON_0001.CR2", "CANON_0002.CR3", "NIKON_0001.NEF", "FUJI_0001.RAF"] {
            try fixture.writeFile(
                fixture.mountURL.appendingPathComponent("DCIM/100MEDIA/\(filename)"),
                bytes: Data("raw-\(filename)".utf8)
            )
        }

        let summary = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-camera-raw")
        )
        let files = try fixture.jobRepository.fetchJobFiles(jobID: "job-camera-raw")

        #expect(summary.scannedFiles == 5)
        #expect(summary.newFiles == 5)
        #expect(summary.unsupportedFiles == 0)
        #expect(files.allSatisfy { $0.mediaKind == .photo })
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

    @Test("scanner ignores camera index files")
    func scannerIgnoresCameraIndexFiles() throws {
        let fixture = try Fixture()
        let video = fixture.mountURL.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let mediaPro = fixture.mountURL.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML")
        let database = fixture.mountURL.appendingPathComponent("PRIVATE/DATABASE/DATABASE.BIN")
        try fixture.writeFile(video, bytes: Data("sample-video-bytes".utf8))
        try fixture.writeFile(mediaPro, bytes: Data("<mediapro />".utf8))
        try fixture.writeFile(database, bytes: Data([0, 1, 2, 3]))

        let summary = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-ignore-index")
        )
        let files = try fixture.jobRepository.fetchJobFiles(jobID: "job-ignore-index")

        #expect(summary.scannedFiles == 1)
        #expect(summary.newFiles == 1)
        #expect(summary.unsupportedFiles == 0)
        #expect(files.map(\.filename) == ["C0001.MP4"])
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

    @Test("copy verification failures retain localized detail in progress and history")
    func copyFailureUsesLocalizedDetail() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let source = fixture.mountURL.appendingPathComponent("IMG_100%.JPG")
        try fixture.writeFile(source, bytes: Data(repeating: 1, count: 12))
        _ = try fixture.scanner.scan(fixture.scanRequest(jobID: "job-copy-failure"))
        // A source changing after scan causes real CopyEngine size verification to fail.
        try fixture.writeFile(source, bytes: Data(repeating: 1, count: 4))

        var events: [ImportProgressFileEvent] = []
        let result = try fixture.importEngine.importFiles(jobID: "job-copy-failure") { progress in
            events.append(contentsOf: progress.recentFiles)
        }
        let files = try fixture.jobRepository.fetchJobFiles(jobID: "job-copy-failure")
        let expected: Int64 = 12, actual: Int64 = 4
        let detail = L10n.tr("Copy verification failed: expected \(expected) bytes, found \(actual) bytes.")

        #expect(result.failedFiles == 1)
        #expect(result.importedFiles == 0)
        #expect(files.first?.copyStatus == .failed)
        #expect(files.first?.error == detail)
        #expect(events.contains { $0.status == .failed && $0.detail == detail })
        let destinationPath = try #require(files.first?.plannedDestinationPath)
        #expect(!FileManager.default.fileExists(atPath: destinationPath))
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
        #expect(finalProgress.destinationDirectories.count == 1)
        #expect(finalProgress.destinationDirectories.first?.hasSuffix("2024-07-15 TEST") == true)
        #expect(finalProgress.status == "completed")
        #expect(finalProgress.percent == 100)
        #expect(finalProgress.processedBytes == finalProgress.totalBytes)
        #expect(finalProgress.throughputBytesPerSecond > 0)
        #expect(
            finalProgress.recentFiles.contains {
                $0.filename == "IMG_0002.JPG" && $0.status == .copied && $0.detail == "Size checked"
            }
        )

        let report = try String(contentsOf: fixture.reportsURL.appendingPathComponent("job-progress.md"))
        #expect(report.contains("## Copied Files"))
        #expect(report.contains("Copied"))
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

    @Test("import space check ignores files already imported after scan")
    func importSpaceCheckIgnoresFilesAlreadyImportedAfterScan() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_DEDUPE.JPG")
        try fixture.writeFile(source, bytes: Data(repeating: 7, count: 1_024))

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-first")
        )
        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-second")
        )
        _ = try fixture.importEngine.importFiles(jobID: "job-first")

        let photosPath = fixture.photosURL.path
        let constrainedEngine = ImportEngine(
            jobRepository: fixture.jobRepository,
            dedupeRepository: fixture.dedupeRepository,
            destinationSpaceChecker: DestinationSpaceChecker { _ in
                VolumeCapacity(
                    volumeID: "tiny",
                    displayPath: photosPath,
                    availableBytes: 0,
                    totalBytes: 1_024
                )
            }
        )
        let result = try constrainedEngine.importFiles(jobID: "job-second")
        let maybeJob = try fixture.jobRepository.fetchJob(id: "job-second")
        let job = try #require(maybeJob)
        let file = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-second").first
        )

        #expect(result.importedFiles == 0)
        #expect(result.skippedFiles == 1)
        #expect(result.failedFiles == 0)
        #expect(file.decision == .known)
        #expect(file.knownSource == .localLedger)
        #expect(job.newFiles == 0)
        #expect(job.knownFiles == 1)
    }

    @Test("import-time destination matches refresh known job totals")
    func importTimeDestinationMatchRefreshesDecisionTotals() throws {
        let fixture = try Fixture()
        let bytes = Data("late-destination-match".utf8)
        let source = fixture.mountURL.appendingPathComponent("IMG_LATE_DESTINATION.JPG")
        try fixture.writeFile(source, bytes: bytes)

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-late-destination")
        )
        let scannedFile = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-late-destination").first
        )
        let plannedDestinationPath = try #require(scannedFile.plannedDestinationPath)
        let destination = URL(fileURLWithPath: plannedDestinationPath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: destination)
        let sourceModificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        )
        try FileManager.default.setAttributes(
            [.modificationDate: sourceModificationDate],
            ofItemAtPath: destination.path
        )

        let result = try fixture.importEngine.importFiles(jobID: "job-late-destination")
        let file = try #require(
            fixture.jobRepository.fetchJobFiles(jobID: "job-late-destination").first
        )
        let maybeJob = try fixture.jobRepository.fetchJob(id: "job-late-destination")
        let job = try #require(maybeJob)

        #expect(result.importedFiles == 0)
        #expect(result.skippedFiles == 1)
        #expect(file.decision == .known)
        #expect(file.knownSource == .destination)
        #expect(job.newFiles == 0)
        #expect(job.knownFiles == 1)
    }

    @Test("replanned import copies to changed destination roots")
    func replannedImportCopiesToChangedDestinationRoots() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_REPLAN.JPG")
        try fixture.writeFile(source, bytes: Data("replan-image-bytes".utf8))

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-replan")
        )

        let changedPhotosURL = fixture.rootURL.appendingPathComponent("changed-photos", isDirectory: true)
        let changedVideosURL = fixture.rootURL.appendingPathComponent("changed-videos", isDirectory: true)
        let changedRoots = DestinationRoots(photosURL: changedPhotosURL, videosURL: changedVideosURL)
        let files = try fixture.jobRepository.fetchJobFiles(jobID: "job-replan")
        let builder = ImportPlanBuilder(
            sessions: [
                ImportPlanSession(
                    date: "2024-07-15",
                    label: "CHANGED",
                    photoCount: 1,
                    videoCount: 0,
                    unsupportedCount: 0,
                    includePhotos: true,
                    includeVideos: false,
                    includeSidecars: false
                )
            ],
            organizationPreset: .classicDatedFolders,
            roots: changedRoots,
            fallbackLocation: "CHANGED",
            volumeName: "CARD"
        )

        try fixture.jobRepository.updateJobImportPlan(
            jobID: "job-replan",
            destinationRoots: changedRoots,
            updates: builder.updates(files: files)
        )
        let result = try fixture.importEngine.importFiles(jobID: "job-replan")
        let changedDestination = changedPhotosURL
            .appendingPathComponent("2024-07-15 CHANGED", isDirectory: true)
            .appendingPathComponent("IMG_REPLAN.JPG")
        let originalDestination = fixture.photosURL
            .appendingPathComponent("2024-07-15 TEST", isDirectory: true)
            .appendingPathComponent("IMG_REPLAN.JPG")
        let maybeJob = try fixture.jobRepository.fetchJob(id: "job-replan")
        let job = try #require(maybeJob)
        let importedFiles = try fixture.jobRepository.fetchJobFiles(jobID: "job-replan")
        let importedFile = try #require(importedFiles.first)

        #expect(result.importedFiles == 1)
        #expect(FileManager.default.fileExists(atPath: changedDestination.path))
        #expect(FileManager.default.fileExists(atPath: originalDestination.path) == false)
        #expect(job.photosRoot == changedPhotosURL.path)
        #expect(job.videosRoot == changedVideosURL.path)
        #expect(importedFile.finalDestinationPath == changedDestination.path)
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
        #expect(sidecar.fingerprint != nil)
        #expect(result.importedFiles == 1)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        let rescan = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-sidecar-rescan")
        )
        let rescannedFiles = try fixture.jobRepository.fetchJobFiles(jobID: "job-sidecar-rescan")
        #expect(rescan.knownFiles == 1)
        #expect(rescannedFiles.first?.decision == .known)
    }

    @Test("scan cancellation exits before writing a job")
    func scanCancellationExitsBeforeWritingJob() throws {
        let fixture = try Fixture()
        let source = fixture.mountURL.appendingPathComponent("IMG_CANCEL.JPG")
        try fixture.writeFile(source, bytes: Data("cancel".utf8))

        do {
            _ = try fixture.scanner.scan(fixture.scanRequest(jobID: "job-cancelled-scan")) {
                true
            }
            Issue.record("Expected scan cancellation")
        } catch SDImportError.cancelled {
            #expect(try fixture.jobRepository.fetchJob(id: "job-cancelled-scan") == nil)
        }
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
        let receiptTotals = ImportReceiptTotals(files: filesAfterRetry)
        let maybeJob = try fixture.jobRepository.fetchJob(id: "job-partial-retry")
        let job = try #require(maybeJob)

        #expect(retryResult.importedFiles == 1)
        #expect(copiedAfterRetry.copyStatus == .copied)
        #expect(copiedAfterRetry.finalDestinationPath == copiedDestinationBeforeRetry)
        #expect(copiedAfterRetry.completedAt == copiedCompletedAtBeforeRetry)
        #expect(failedAfterRetry.copyStatus == .copied)
        #expect(receiptTotals.copiedFiles == 2)
        #expect(receiptTotals.copiedBytes == Int64(copiedBytes.count + failedBytes.count))
        #expect(receiptTotals.failedFiles == 0)
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

    @Test("receipt totals remain cumulative after cancelling between files and retrying")
    func retryAfterPartialCancellationHasCumulativeReceiptTotals() throws {
        let fixture = try Fixture()
        let firstSource = fixture.mountURL.appendingPathComponent("A_FIRST.JPG")
        let secondSource = fixture.mountURL.appendingPathComponent("B_SECOND.JPG")
        let firstBytes = Data(repeating: 1, count: 2 * 1024 * 1024)
        let secondBytes = Data(repeating: 2, count: 2 * 1024 * 1024)
        try fixture.writeFile(firstSource, bytes: firstBytes)
        try fixture.writeFile(secondSource, bytes: secondBytes)

        _ = try fixture.scanner.scan(
            fixture.scanRequest(jobID: "job-partial-cancel-retry")
        )

        var shouldCancel = false
        do {
            _ = try fixture.importEngine.importFiles(
                jobID: "job-partial-cancel-retry",
                onProgress: { progress in
                    if progress.doneFiles == 1 {
                        shouldCancel = true
                    }
                },
                shouldCancel: {
                    shouldCancel
                }
            )
            Issue.record("import should have been cancelled after its first file")
        } catch SDImportError.cancelled {
        }

        let filesAfterCancellation = try fixture.jobRepository.fetchJobFiles(
            jobID: "job-partial-cancel-retry"
        )
        #expect(filesAfterCancellation.filter { $0.copyStatus == .copied }.count == 1)
        #expect(filesAfterCancellation.filter { $0.copyStatus == .pending }.count == 1)

        let retryResult = try fixture.importEngine.importFiles(
            jobID: "job-partial-cancel-retry"
        )
        let filesAfterRetry = try fixture.jobRepository.fetchJobFiles(
            jobID: "job-partial-cancel-retry"
        )
        let receiptTotals = ImportReceiptTotals(files: filesAfterRetry)

        #expect(retryResult.importedFiles == 1)
        #expect(receiptTotals.copiedFiles == 2)
        #expect(receiptTotals.copiedBytes == Int64(firstBytes.count + secondBytes.count))
        #expect(receiptTotals.skippedFiles == 0)
        #expect(receiptTotals.failedFiles == 0)
        #expect(
            filesAfterRetry.allSatisfy { file in
                guard let destination = file.plannedDestinationPath else {
                    return false
                }
                return FileManager.default.fileExists(atPath: destination + ".part") == false
            }
        )
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
