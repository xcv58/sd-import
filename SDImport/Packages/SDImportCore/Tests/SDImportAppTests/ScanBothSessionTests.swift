import Foundation
import os
import SDImportCommerce
import SDImportCore
import Testing

@testable import SDImportApp

@Suite("Scan both camera volumes")
@MainActor
struct ScanBothSessionTests {
    private let internalStorage = Self.volume("Z Internal", disk: "disk4")
    private let card = Self.volume("SD Card", disk: "disk5")

    @Test("an active copy stops on the first planned volume unmount")
    func unmountOfEitherPlannedVolumeStopsCopy() {
        var copy = ActiveCopySources(volumes: [internalStorage, card])
        let unrelated = copy.noteUnmount(at: "/Volumes/Unrelated")
        #expect(!unrelated)
        #expect(copy.disconnectedVolume == nil)
        let planned = copy.noteUnmount(at: card.mountPath)
        #expect(planned)
        #expect(copy.disconnectedVolume == card.name)
        let second = copy.noteUnmount(at: internalStorage.mountPath)
        #expect(!second)
        #expect(copy.disconnectedVolume == card.name)
    }

    @Test("a copy refuses a replacement at the approved source path")
    func refusesReplacementSourceDirectory() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = fixture.appendingPathComponent("Card", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let file = source.appendingPathComponent("IMG_0001.jpg")
        try Data("old".utf8).write(to: file)
        let copy = CopyEngine(sourceDirectory: try CopySourceDirectory(at: source))
        let originalDestination = fixture.appendingPathComponent("original.jpg")
        try copy.copyFile(from: file, to: originalDestination, expectedSize: 3, modificationDate: nil)
        #expect(try Data(contentsOf: originalDestination) == Data("old".utf8))

        try manager.moveItem(at: source, to: fixture.appendingPathComponent("Removed", isDirectory: true))
        try manager.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: file)
        let destination = fixture.appendingPathComponent("replacement.jpg")
        #expect(throws: SDImportError.sourceVolumeUnavailable) {
            try copy.copyFile(from: file, to: destination, expectedSize: 3, modificationDate: nil)
        }
        #expect(!manager.fileExists(atPath: destination.path))
    }

    @Test("a verified sibling arriving later enables Scan Both and internal storage goes first")
    func waitsForVerifiedSibling() throws {
        let otherCard = Self.volume("Other Card", disk: "disk6", device: "other-device")
        var coordinator = MountedDevicePromptCoordinator()
        _ = coordinator.receive(internalStorage, among: [internalStorage, otherCard], canPresent: true)
        let single = try #require(coordinator.pendingPrompt)
        #expect(ScanBothSession(prompt: single) == nil)

        let mounted = [internalStorage, card, otherCard]
        coordinator.updateMountedVolumes(mounted)
        _ = coordinator.receive(card, among: mounted, canPresent: false)
        let prompt = try #require(coordinator.pendingPrompt)
        let session = try #require(ScanBothSession(prompt: prompt))
        #expect(prompt.id == single.id)
        #expect(session.entries.map(\.volume) == [internalStorage, card])
    }

    @Test("a skipped source preserves the sibling's completed result", arguments: [true, false])
    func preservesSiblingResult(declineFirst: Bool) async throws {
        var coordinator = MountedDevicePromptCoordinator()
        _ = coordinator.receive(card, among: [card, internalStorage], canPresent: true)
        let prompt = try #require(coordinator.pendingPrompt)
        let session = try #require(ScanBothSession(prompt: prompt))
        let skippedVolume = declineFirst ? internalStorage : card
        let completedVolume = declineFirst ? card : internalStorage
        var states: [ScanBothSession.Entry.State] = [.waiting, .waiting]
        var order: [String] = []

        await session.scan { index, state in
            states[index] = state
        } volume: { volume in
            order.append(volume.name)
            if volume == card {
                if declineFirst {
                    guard case .skipped(.accessDeclined) = states[0] else {
                        Issue.record("The first source's decline must be recorded before the second starts")
                        throw ScanBothIssue.cancelled
                    }
                } else {
                    guard case .complete = states[0] else {
                        Issue.record("The first source must finish before the second starts")
                        throw ScanBothIssue.cancelled
                    }
                }
            }
            if volume == skippedVolume {
                throw declineFirst ? ScanBothIssue.accessDeclined : .removed
            }
            await Task.yield()
            return .complete(
                ScanSummary(
                    jobID: volume.name, mountPath: volume.mountPath, volumeName: volume.name,
                    volumeUUID: volume.volumeUUID, location: "Camera", scannedFiles: 1, newFiles: 1,
                    knownFiles: 0, unsupportedFiles: 0, conflictFiles: 0
                ),
                ["clip.mp4"],
                nil
            )
        }

        #expect(order == [internalStorage.name, card.name])
        let completed = states[declineFirst ? 1 : 0]
        let skipped = states[declineFirst ? 0 : 1]
        if case .complete(let summary, let filenames, _, _) = completed {
            #expect(summary.volumeName == completedVolume.name)
            #expect(filenames == ["clip.mp4"])
        } else {
            Issue.record("Expected the sibling's scan result")
        }
        switch skipped {
        case .skipped(.accessDeclined): #expect(declineFirst)
        case .skipped(.removed): #expect(!declineFirst)
        default: Issue.record("Expected the source's skip reason")
        }
    }

    @Test("separate plans can be confirmed before copying in volume order", arguments: [false, true])
    func confirmsBeforeSequentialCopy(sharedFilename: Bool) async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("sdimport-scan-both-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: directory) }

        let internalStorage = Self.volume("Z Internal", disk: "disk4")
        let card = Self.volume("SD Card", disk: "disk5")
        let sourceFolders = [
            internalStorage.name: directory.appendingPathComponent("Internal", isDirectory: true),
            card.name: directory.appendingPathComponent("SD Card", isDirectory: true)
        ]
        let internalNames = (1...6).map { "Internal-\($0).jpg" } + (sharedFilename ? ["Shared.jpg"] : [])
        let cardNames = ["Card-1.jpg", sharedFilename ? "Shared.jpg" : "Card-2.jpg"]
        for (volume, names) in [(internalStorage, internalNames), (card, cardNames)] {
            let source = try #require(sourceFolders[volume.name])
            let dcim = source.appendingPathComponent("DCIM", isDirectory: true)
            try fileManager.createDirectory(at: dcim, withIntermediateDirectories: true)
            for name in names {
                let file = dcim.appendingPathComponent(name)
                try Data("\(volume.name) \(name)".utf8).write(to: file)
                try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
            }
        }

        let roots = DestinationRoots(
            photosURL: directory.appendingPathComponent("photos", isDirectory: true),
            videosURL: directory.appendingPathComponent("videos", isDirectory: true)
        )
        for destination in [roots.photosURL, roots.videosURL] {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        let pool = try DatabasePoolFactory(databaseURL: directory.appendingPathComponent("state.sqlite"))
            .makeMigratedPool()
        let repository = JobRepository(pool: pool)
        let dedupe = DedupeRepository(pool: pool)
        let scanner = MediaScanner(jobRepository: repository, dedupeRepository: dedupe)

        var coordinator = MountedDevicePromptCoordinator()
        _ = coordinator.receive(card, among: [card, internalStorage], canPresent: true)
        let prompt = try #require(coordinator.pendingPrompt)
        var review = try #require(ScanBothSession(prompt: prompt))
        let session = review
        var scannedVolumes: [String] = []
        await session.scan { index, state in
            review.entries[index].state = state
        } volume: { volume in
            scannedVolumes.append(volume.name)
            let source = try #require(sourceFolders[volume.name])
            let summary = try scanner.scan(ScanRequest(
                mountURL: source,
                volumeName: volume.name,
                volumeUUID: volume.volumeUUID,
                location: "Camera",
                roots: roots
            ))
            let preview = try repository.previewFilenames(jobID: summary.jobID, limit: 5)
            return .complete(summary, preview, nil)
        }

        #expect(scannedVolumes == [internalStorage.name, card.name])
        let jobs = try repository.listJobs()
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.status == .scanned })
        #expect(try repository.listImportHistoryJobs().isEmpty)
        for destination in [roots.photosURL, roots.videosURL] {
            #expect(try fileManager.contentsOfDirectory(atPath: destination.path).isEmpty)
        }

        for (volume, expectedNames) in [(internalStorage, internalNames), (card, cardNames)] {
            let job = try #require(jobs.first { $0.volumeUUID == volume.volumeUUID })
            review.reviewingJobID = job.id
            let entry = try #require(review.reviewingEntry)
            #expect(entry.volume == volume)
            guard case .complete(let summary, let preview, _, _) = entry.state else {
                Issue.record("Missing scan result for \(volume.name)")
                return
            }
            #expect(summary.jobID == job.id)
            #expect(summary.scannedFiles == expectedNames.count)
            #expect(summary.mountPath == sourceFolders[volume.name]?.path)
            let files = try repository.fetchJobFiles(jobID: job.id)
            #expect(Set(files.map(\.filename)) == Set(expectedNames))
            #expect(preview == Array(files.prefix(5).map(\.filename)))
            #expect(files.allSatisfy { $0.copyStatus == .pending })
        }

        let firstJob = try #require(jobs.first { $0.volumeUUID == internalStorage.volumeUUID })
        let siblingJob = try #require(jobs.first { $0.volumeUUID == card.volumeUUID })
        let engine = ImportEngine(jobRepository: repository, dedupeRepository: dedupe)
        let builder = ImportPlanBuilder(
            sessions: [], organizationPreset: .classicDatedFolders, roots: roots,
            fallbackLocation: "Camera", volumeName: nil
        )

        #expect(!review.canStartImports)
        for jobID in [siblingJob.id, firstJob.id] {
            let summary = try #require(review.entry(for: jobID)?.summary)
            let files = try repository.fetchJobFiles(jobID: jobID)
            let plans = builder.plans(files: files)
            review.setConfirmation(.init(
                draft: draft(sourcePath: summary.mountPath, roots: roots),
                plans: plans,
                destinations: try #require(ReviewedImportDestinations(plans: plans))
            ), for: jobID)
            #expect(review.canStartImports == (jobID == firstJob.id))
        }
        #expect(try repository.listImportHistoryJobs().isEmpty)
        #expect(try fileManager.contentsOfDirectory(atPath: roots.photosURL.path).isEmpty)

        let first = try #require(review.nextConfirmedEntry)
        #expect(first.jobID == firstJob.id)
        let firstConfirmation = try #require(first.confirmation)
        review.recordImportStarted(for: firstJob.id)
        let result = try engine.importFiles(preparing: {
            try repository.updateJobImportPlan(
                jobID: firstJob.id, destinationRoots: roots, updates: firstConfirmation.plans.compactMap(\.update)
            )
        }, jobID: firstJob.id, requiresReviewedDestinations: true)
        review.recordImport(result)
        #expect(result.importedFiles == internalNames.count)
        #expect(try repository.listImportHistoryJobs().map(\.id) == [firstJob.id])
        #expect(try repository.fetchJob(id: siblingJob.id)?.status == .scanned)
        #expect(try repository.fetchJobFiles(jobID: siblingJob.id).allSatisfy { $0.copyStatus == .pending })
        #expect(!review.allowsAutomaticEjection)

        #expect(review.entry(for: firstJob.id)?.result == result)
        let second = try #require(review.nextConfirmedEntry)
        #expect(second.jobID == siblingJob.id)
        let secondConfirmation = try #require(second.confirmation)
        #expect(secondConfirmation.draft.sourcePath == sourceFolders[card.name]?.path)
        let freshSecondPlans = builder.plans(files: try repository.fetchJobFiles(jobID: siblingJob.id))
        #expect((freshSecondPlans != secondConfirmation.plans) == sharedFilename)
        if sharedFilename {
            review.setConfirmation(nil, for: siblingJob.id)
            #expect(review.nextConfirmedEntry == nil)
            #expect(try repository.listImportHistoryJobs().map(\.id) == [firstJob.id])
            #expect(review.entry(for: firstJob.id)?.result == result)
            review.setConfirmation(.init(
                draft: secondConfirmation.draft, plans: freshSecondPlans,
                destinations: try #require(ReviewedImportDestinations(plans: freshSecondPlans))
            ), for: siblingJob.id)
        }
        let approvedSecond = try #require(review.nextConfirmedEntry?.confirmation)
        review.recordImportStarted(for: siblingJob.id)
        let siblingResult = try engine.importFiles(preparing: {
            try repository.updateJobImportPlan(
                jobID: siblingJob.id, destinationRoots: roots, updates: approvedSecond.plans.compactMap(\.update)
            )
        }, jobID: siblingJob.id, requiresReviewedDestinations: true)
        review.recordImport(siblingResult)
        #expect(siblingResult.importedFiles == cardNames.count)
        #expect(Set(try repository.listImportHistoryJobs().map(\.id)) == Set([firstJob.id, siblingJob.id]))
        #expect(review.allowsAutomaticEjection)
        #expect(review.nextConfirmedEntry == nil)
        review.removedMountPaths.insert(card.mountPath)
        #expect(!review.allowsAutomaticEjection)
    }

    @Test("losing one approved volume invalidates only its confirmation")
    func disconnectInvalidatesOnlyAffectedConfirmation() throws {
        var session = try scannedSession()
        let roots = DestinationRoots(
            photosURL: FileManager.default.temporaryDirectory,
            videosURL: FileManager.default.temporaryDirectory
        )
        for entry in session.entries {
            let jobID = try #require(entry.jobID)
            session.setConfirmation(.init(
                draft: draft(sourcePath: entry.volume.mountPath, roots: roots), plans: [],
                destinations: try #require(ReviewedImportDestinations(plans: []))
            ), for: jobID)
        }
        #expect(session.canStartImports)
        #expect(session.noteUnmount(at: card.mountPath) == card.name)
        #expect(!session.canStartImports)
        #expect(session.entries[1].confirmation == nil)
        #expect(session.nextConfirmedEntry?.volume == internalStorage)
        session.skipEntry(session.entries[1].id)
        #expect(session.canStartImports)
        #expect(!session.allowsEjection)
    }

    private func draft(sourcePath: String, roots: DestinationRoots) -> ImportDraft {
        ImportDraft(
            sourcePath: sourcePath, photosPath: roots.photosURL.path, videosPath: roots.videosURL.path,
            shootName: "Camera", workflowProfile: .photoImport, mediaSelection: .photosOnly,
            destinationLayout: .separateMediaFolders, folderGrouping: .byDay
        )
    }

    @Test("ejection checks a destination from either volume in the scan session")
    func ejectionChecksBothImportDestinations() throws {
        var session = try scannedSession()
        let both = [internalStorage, card]
        let macDestination = try #require(try FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeURLKey]).volume)
        let cameraDestination = card.mountURL
        session.recordImportDestinations([cameraDestination.path], for: internalStorage.name)
        session.recordImportDestinations([macDestination.path], for: card.name)
        let paths = try #require(session.confirmedDestinationPaths)
        #expect(paths == Set([macDestination.path, cameraDestination.path]))
        #expect(!AppModel.canEject(both, withDestinationVolumeAt: cameraDestination.path))
        #expect(!AppModel.canEject(both, withDestinationVolumeAt: "/Volumes/Missing-\(UUID())"))

        session.recordImportDestinations(nil, for: internalStorage.name)
        session.recordImportDestinations([macDestination.path], for: card.name)
        #expect(session.confirmedDestinationPaths == nil)
    }

    @Test("skipping a failed scan preserves its error and lets the user eject after importing the sibling")
    func skipsFailedScan() throws {
        var session = try scannedSession()
        let issue = ScanBothIssue.failed("fixture error")
        session.entries[1].state = .skipped(issue)
        session.recordImport(ImportResult(
            jobID: internalStorage.name, importedFiles: 1, skippedFiles: 0, failedFiles: 0, progressPath: nil
        ))
        #expect(!session.allowsEjection)
        #expect(session.entries[1].canSkip)

        let entryID = session.entries[1].id
        session.skipEntry(entryID)
        #expect(session.allowsEjection)
        #expect(!session.entries[1].canSkip)
        guard case .skipped(let retainedIssue) = session.entries[1].state else {
            Issue.record("The original scan error should remain on the skipped row")
            return
        }
        #expect(retainedIssue.message == issue.message)
        session.removedMountPaths.insert(card.mountPath)
        #expect(!session.allowsEjection)
    }

    @Test("skipping an attempted but unsuccessful copy leaves eject manual")
    func skipsUnsuccessfulCopy() throws {
        let original = try scannedSession()
        let skippedEntry = original.entries[1].id
        let successfulInternalCopy = ImportResult(
            jobID: internalStorage.name, importedFiles: 1, skippedFiles: 0, failedFiles: 0, progressPath: nil
        )

        var attempted = original
        attempted.recordImportStarted(for: card.name)
        attempted.recordImport(ImportResult(
            jobID: card.name, importedFiles: 2, skippedFiles: 0, failedFiles: 1, progressPath: nil
        ))
        #expect(attempted.entries[1].awaitsImport)
        attempted.skipEntry(skippedEntry)
        attempted.recordImport(successfulInternalCopy)
        #expect(attempted.entries[1].result?.importedFiles == 2)
        #expect(attempted.entries[1].result?.failedFiles == 1)
        #expect(attempted.allowsEjection)
        #expect(!attempted.allowsAutomaticEjection)

        var skippedBeforeCopy = original
        skippedBeforeCopy.skipEntry(skippedEntry)
        skippedBeforeCopy.recordImport(successfulInternalCopy)
        #expect(skippedBeforeCopy.allowsAutomaticEjection)
    }

    @Test("interrupted receipts count recordings like History and retain partial lens copies", arguments: [false, true])
    func groupsInterruptedRecording(completePair: Bool) throws {
        var session = try scannedSession()
        let jobID = internalStorage.name
        let names = ["VID_20181001_210458_00_007.insv", "VID_20181001_210458_10_007.insv", "pending.mp4"]
        let files = names.enumerated().map { index, filename in
            JobFileRecord(
                id: Int64(index + 1), jobID: jobID, sourcePath: "/Volumes/Internal/DCIM/\(filename)",
                relativePath: "DCIM/\(filename)", filename: filename,
                ext: index == 2 ? ".mp4" : ".insv", size: 10, modificationDateString: "",
                mediaKind: .video, fingerprint: nil, captureDate: nil, decision: .new,
                destinationDirectory: "/tmp", plannedDestinationPath: "/tmp/\(filename)",
                copyStatus: index == 0 ? .copied : (index == 1 ? (completePair ? .copied : .failed) : .pending)
            )
        }
        session.recordInterruptedImport(jobID: jobID, files: files, message: "Stopped", includeEmptyReceipt: false)
        #expect(session.entries[0].result?.importedFiles == (completePair ? 1 : 0))
        #expect(session.entries[0].result?.failedFiles == (completePair ? 0 : 1))
        #expect(session.entries[0].copyInterruption == "Stopped")
        #expect(session.entries[0].awaitsImport)
    }

    @Test("replacing a Scan Both review needs confirmation while the sibling is still pending")
    func pendingResultsRequireConfirmation() throws {
        var session = try scannedSession()
        session.recordImport(ImportResult(
            jobID: internalStorage.name, importedFiles: 1, skippedFiles: 0, failedFiles: 0, progressPath: nil
        ))
        #expect(session.hasPendingResults)
        let siblingID = session.entries[1].id
        session.skipEntry(siblingID)
        #expect(!session.hasPendingResults)
    }

    @Test("a replacement Scan Both attempt needs at least one completed scan")
    func replacementNeedsCompletedScan() throws {
        var session = try scannedSession()
        session.entries[0].state = .skipped(.accessDeclined)
        #expect(session.issueIfNoVolumeScanned == nil)
        session.entries[1].state = .skipped(.removed)
        #expect(session.issueIfNoVolumeScanned != nil)
    }

    private func scannedSession() throws -> ScanBothSession {
        var coordinator = MountedDevicePromptCoordinator()
        _ = coordinator.receive(internalStorage, among: [internalStorage, card], canPresent: true)
        let prompt = try #require(coordinator.pendingPrompt)
        var session = try #require(ScanBothSession(prompt: prompt))
        for index in session.entries.indices {
            let volume = session.entries[index].volume
            session.entries[index].state = .complete(
                ScanSummary(
                    jobID: volume.name, mountPath: volume.mountPath, volumeName: volume.name,
                    volumeUUID: volume.volumeUUID, location: "Camera", scannedFiles: 1, newFiles: 1,
                    knownFiles: 0, unsupportedFiles: 0, conflictFiles: 0
                ),
                [],
                nil
            )
        }
        return session
    }

    private static func volume(_ name: String, disk: String, device: String = "camera", at url: URL? = nil) -> MountedVolume {
        MountedVolume(
            id: name, name: name, mountURL: url ?? URL(fileURLWithPath: "/Volumes/\(name)"),
            volumeUUID: name, isRemovable: true, wholeDiskIdentifier: disk, deviceGroupIdentifier: device
        )
    }

    @Test("destination approvals allow new folders and reject a retargeted path")
    func checksApprovedDestinationIdentity() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let directory = root.appendingPathComponent("planned", isDirectory: true)
        let plan = ImportFilePlan(
            update: nil, willCopy: true, disposition: .copy,
            destinationPath: directory.appendingPathComponent("IMG_001.jpg").path
        )
        let approval = try #require(ReviewedImportDestinations(plans: [plan]))
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(approval.matches())
        let existingDirectoryApproval = try #require(ReviewedImportDestinations(plans: [plan]))
        let replacement = root.appendingPathComponent("replacement")
        try fm.moveItem(at: directory, to: replacement)
        try fm.createSymbolicLink(at: directory, withDestinationURL: replacement)
        #expect(!approval.matches())
        #expect(!existingDirectoryApproval.matches())
    }

    @Test("new history only changes a plan for an unchanged source file")
    func refreshesHistoryWithoutHidingMissingFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        for folder in [source, destination] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        let file = source.appendingPathComponent("IMG_001.jpg")
        let bytes = Data("photo".utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try bytes.write(to: file)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let roots = DestinationRoots(photosURL: destination, videosURL: destination)
        let pool = try DatabasePoolFactory(databaseURL: root.appendingPathComponent("state.sqlite")).makeMigratedPool()
        let jobs = JobRepository(pool: pool)
        let dedupe = DedupeRepository(pool: pool)
        let summary = try MediaScanner(jobRepository: jobs, dedupeRepository: dedupe).scan(
            ScanRequest(mountURL: source, volumeName: "Card", volumeUUID: "Card", location: "Camera", roots: roots)
        )
        let files = try jobs.fetchJobFiles(jobID: summary.jobID)
        let id = try #require(files.first?.id)
        let engine = ImportEngine(jobRepository: jobs, dedupeRepository: dedupe, portableReceiptsEnabled: true)
        #expect(engine.refreshedReviewHistory(files: files, sourcePath: source.path).isEmpty)
        let ledger = PortableImportReceiptLedger(sourceRootURL: source)
        try ledger.append(
            identity: PortableFileIdentity(size: Int64(bytes.count), modificationDate: date, relativePath: file.lastPathComponent)
        )
        #expect(engine.refreshedReviewHistory(files: files, sourcePath: source.path)[id] == .known(.portableLedger))
        let previouslyKnown = try MediaScanner(jobRepository: jobs, dedupeRepository: dedupe).scan(
            ScanRequest(
                mountURL: source, volumeName: "Card", volumeUUID: "Card", location: "Camera",
                roots: roots, portableReceiptsEnabled: true
            )
        )
        let knownFiles = try jobs.fetchJobFiles(jobID: previouslyKnown.jobID)
        let knownID = try #require(knownFiles.first?.id)
        #expect(knownFiles.first?.knownSource == .portableLedger)
        try fm.removeItem(at: ledger.ledgerURL)
        let refreshed = engine.refreshedReviewHistory(files: knownFiles, sourcePath: source.path)
        #expect(refreshed[knownID] == .unmatched)
        let builder = ImportPlanBuilder(
            sessions: [], organizationPreset: .classicDatedFolders, roots: roots, fallbackLocation: "Camera", volumeName: nil
        )
        #expect(builder.plans(files: knownFiles, refreshedHistory: refreshed).first?.willCopy == true)
        // Copy through a second job to supply the local dedupe record, then remove the original media.
        let other = try MediaScanner(jobRepository: jobs, dedupeRepository: dedupe).scan(
            ScanRequest(mountURL: source, volumeName: "Other", volumeUUID: "Other", location: "Camera", roots: roots)
        )
        let result = try ImportEngine(jobRepository: jobs, dedupeRepository: dedupe).importFiles(jobID: other.jobID)
        #expect(result.importedFiles == 1)
        #expect(engine.refreshedReviewHistory(files: files, sourcePath: source.path)[id] == .known(.localLedger))
        let locallyKnown = try MediaScanner(jobRepository: jobs, dedupeRepository: dedupe).scan(
            ScanRequest(mountURL: source, volumeName: "Card", volumeUUID: "Card", location: "Camera", roots: roots)
        )
        let locallyKnownFiles = try jobs.fetchJobFiles(jobID: locallyKnown.jobID)
        let locallyKnownID = try #require(locallyKnownFiles.first?.id)
        #expect(locallyKnownFiles.first?.knownSource == .localLedger)
        try fm.removeItem(at: file)
        #expect(engine.refreshedReviewHistory(files: files, sourcePath: source.path).isEmpty)
        try bytes.write(to: file)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        #expect(engine.refreshedReviewHistory(files: locallyKnownFiles, sourcePath: source.path)[locallyKnownID] == .known(.localLedger))
        #expect(try dedupe.forgetImportedFiles(jobID: other.jobID) == 1)
        #expect(engine.refreshedReviewHistory(files: locallyKnownFiles, sourcePath: source.path)[locallyKnownID] == .unmatched)
    }

    enum CopyScenario: Sendable, Equatable {
        case bothSucceed
        case reimportKnownFile
        case receiptAfterHistoryNavigation
        case firstCopyChangesSecondPlan
        case destinationChangesInWorker
        case destinationFillsInWorker
        case disconnectBeforeCopy
        case firstVolumeDisconnectsBeforeSecond
        case unmountNotificationBeforeCopy
        case unmountDuringCopy
        case unmountDuringFirstCopy
        case cancelDuringFirstCopy
        case destinationReplacedAfterPartialCopy
        case nestedDestinationReplacedAfterPartialCopy
        case sourceChangesInWorker
        case sourceChangesInSameSecond
        case sourceChangesWithPortableHistory
        case knownSourceChangesBeforeStart
        case sourceMissingInWorker
        case sourceFolderMissingBeforeStart
        case sourceFolderMissingInWorker
    }

    @Test("one Start drives the real Scan Both import flow",
          arguments: [CopyScenario.bothSucceed, .receiptAfterHistoryNavigation, .firstCopyChangesSecondPlan,
                      .destinationChangesInWorker, .destinationFillsInWorker,
                      .disconnectBeforeCopy, .unmountNotificationBeforeCopy, .unmountDuringCopy, .destinationReplacedAfterPartialCopy,
                      .unmountDuringFirstCopy, .cancelDuringFirstCopy, .nestedDestinationReplacedAfterPartialCopy,
                      .sourceChangesInWorker, .sourceChangesInSameSecond, .sourceChangesWithPortableHistory, .knownSourceChangesBeforeStart,
                      .sourceMissingInWorker, .sourceFolderMissingBeforeStart, .sourceFolderMissingInWorker,
                      .firstVolumeDisconnectsBeforeSecond])
    func startsBatchThroughAppModel(_ scenario: CopyScenario) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Destination")
        let internalFolder = root.appendingPathComponent("Internal")
        let cardFolder = root.appendingPathComponent("Card")
        let first = Self.volume("Internal", disk: "disk4", at: internalFolder)
        let second = Self.volume("Card", disk: "disk5", at: cardFolder)
        let suite = "SDImportAppTests.scanBoth.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        for folder in [internalFolder, cardFolder, destination] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let firstFile = internalFolder.appendingPathComponent("Shared.jpg")
        let laterFile = internalFolder.appendingPathComponent("ZZ-Later.jpg")
        let replacesParent = scenario == .nestedDestinationReplacedAfterPartialCopy
        let stopsDuringFirstFile = scenario == .cancelDuringFirstCopy || scenario == .unmountDuringFirstCopy
        let hasLaterFile = scenario == .unmountDuringCopy || scenario == .destinationReplacedAfterPartialCopy || replacesParent
        let testsHistoryExclusion = scenario == .sourceChangesWithPortableHistory
            || scenario == .knownSourceChangesBeforeStart || scenario == .reimportKnownFile
        let needsSecondInternalFile = hasLaterFile || testsHistoryExclusion || scenario == .receiptAfterHistoryNavigation
        let secondFile = cardFolder.appendingPathComponent(scenario == .firstCopyChangesSecondPlan ? "Shared.jpg" : "Card.jpg")
        try Data("internal image".utf8).write(to: firstFile)
        try Data("longer card image".utf8).write(to: secondFile)
        if needsSecondInternalFile { try Data("another internal image".utf8).write(to: laterFile) }
        for url in [firstFile, secondFile] + (needsSecondInternalFile ? [laterFile] : []) {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        }
        if scenario == .reimportKnownFile {
            let laterDate = Date(timeIntervalSince1970: 1_700_086_400)
            try fm.setAttributes(
                [.creationDate: laterDate, .modificationDate: laterDate], ofItemAtPath: laterFile.path
            )
        }
        if testsHistoryExclusion {
            try PortableImportReceiptLedger(sourceRootURL: internalFolder).append(identity: PortableFileIdentity(
                size: 14, modificationTimeEpochSeconds: 1_700_000_000, relativePath: firstFile.lastPathComponent
            ))
        }
        let session = try #require(ScanBothSession(deviceName: "Fixture Camera", entries: [
            .init(id: UUID(), volume: first), .init(id: UUID(), volume: second)
        ]))
        let lateChange = OSAllocatedUnfairLock(initialState: Optional<URL>.none)
        let movedSource = root.appendingPathComponent("MovedSource")
        let firstFinished = OSAllocatedUnfairLock(initialState: false)
        let capacity = OSAllocatedUnfairLock(
            initialState: (available: true, shouldFill: scenario == .destinationFillsInWorker)
        )
        let unmountDelivered = DispatchSemaphore(value: 0)
        let reachedLateCopy = OSAllocatedUnfairLock(initialState: false)
        let model = AppModel(
            purchaseManager: PurchaseManager(distribution: .direct, startsStoreTask: false),
            defaults: defaults, startsBootstrap: false,
            scanBothMountLookup: { volume in
                if scenario == .firstVolumeDisconnectsBeforeSecond, volume == first,
                   firstFinished.withLock({ $0 }) { return nil }
                if !Thread.isMainThread, volume == second {
                    if scenario == .disconnectBeforeCopy { return nil }
                    if scenario == .unmountNotificationBeforeCopy {
                        _ = unmountDelivered.wait(timeout: .now() + 5)
                    }
                    let change = lateChange.withLock { path in
                        defer { path = nil }
                        return path
                    }
                    if let change {
                        switch scenario {
                        case .sourceMissingInWorker:
                            try? FileManager.default.removeItem(at: change)
                        case .sourceChangesInSameSecond, .sourceChangesWithPortableHistory:
                            let timestamp = testsHistoryExclusion ? 1_700_000_000 : 1_700_000_000.5
                            try? Data("different data".utf8).write(to: change)
                            try? FileManager.default.setAttributes(
                                [.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: change.path
                            )
                        case .sourceChangesInWorker:
                            try? Data("different data".utf8).write(to: change)
                            try? FileManager.default.setAttributes(
                                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_010)], ofItemAtPath: change.path
                            )
                        default:
                            try? FileManager.default.createDirectory(
                                at: change.deletingLastPathComponent(), withIntermediateDirectories: true
                            )
                            try? Data("another process created this destination".utf8).write(to: change)
                        }
                    }
                }
                return volume
            },
            destinationCapacity: { path in
                if scenario == .sourceFolderMissingInWorker, !Thread.isMainThread {
                    try FileManager.default.moveItem(at: internalFolder, to: movedSource)
                }
                let available = capacity.withLock { state in
                    if state.shouldFill && !Thread.isMainThread {
                        state.shouldFill = false
                        state.available = false
                    }
                    return state.available
                }
                return VolumeCapacity(
                    volumeID: "test-destination", displayPath: path,
                    availableBytes: available ? 10_000 : 0, totalBytes: 10_000
                )
            },
            observeCopyProgress: { progress in
                if scenario == .firstVolumeDisconnectsBeforeSecond, progress.status == "completed" {
                    firstFinished.withLock { $0 = true }
                }
                if stopsDuringFirstFile {
                    guard progress.currentSourcePath == firstFile.path, progress.copiedBytes > 0,
                          progress.importedFiles == 0 else { return }
                } else {
                    guard hasLaterFile, progress.importedFiles == 1 else { return }
                    if scenario == .unmountDuringCopy {
                        guard progress.currentSourcePath == laterFile.path, progress.copiedBytes > 14 else { return }
                    } else {
                        guard progress.currentSourcePath == nil else { return }
                    }
                }
                let shouldInterrupt = reachedLateCopy.withLock { reached in
                    defer { reached = true }
                    return !reached
                }
                guard shouldInterrupt else { return }
                if scenario == .unmountDuringCopy || stopsDuringFirstFile {
                    _ = unmountDelivered.wait(timeout: .now() + 5)
                } else {
                    try? FileManager.default.removeItem(at: laterFile)
                }
            }
        )
        model.bootstrap(at: root.appendingPathComponent("State"), startsRuntimeServices: false)
        model.portableImportReceiptsEnabled = testsHistoryExclusion
        model.importDefaults.photosPath = destination.path
        model.importDefaults.videosPath = destination.path
        model.beginScanBoth(session)
        try await waitForImport(model)
        let entries = try #require(model.scanBothSession?.entries)
        #expect(entries.allSatisfy { $0.summary != nil })
        var lateConflictPath: URL?
        var sharedDestination: URL?
        for entry in entries.reversed() {
            model.reviewScanBothVolume(entry.id)
            if testsHistoryExclusion, entry.volume == first {
                try #require(model.previewRows.contains { $0.disposition == .known(.portableLedger) })
                try #require(model.previewRows.contains { $0.willCopy })
            }
            if scenario == .reimportKnownFile, entry.volume == first {
                let known = try #require(model.previewRows.first { $0.canReimport })
                let newDate = try #require(model.previewRows.first { $0.willCopy }?.date)
                try #require(newDate != known.date)
                #expect(model.previewSessions.map(\.date) == [newDate])
                let newDateIndex = try #require(model.previewSessions.firstIndex { $0.date == newDate })
                model.previewSessions[newDateIndex].label = "New Photos"

                model.returnToScanBothResults()
                let ledger = PortableImportReceiptLedger(sourceRootURL: internalFolder)
                try fm.removeItem(at: ledger.ledgerURL)
                model.reviewScanBothVolume(entry.id)
                #expect(model.previewRows.first { $0.id == known.id }?.willCopy == true)
                #expect(model.previewSessions.map(\.date) == [known.date, newDate].sorted())
                #expect(model.previewSessions.first { $0.date == known.date }?.photoCount == 1)
                #expect(model.previewSessions.first { $0.date == newDate }?.label == "New Photos")

                model.returnToScanBothResults()
                try ledger.append(identity: PortableFileIdentity(
                    size: known.size, modificationTimeEpochSeconds: 1_700_000_000, relativePath: firstFile.lastPathComponent
                ))
                model.reviewScanBothVolume(entry.id)
                #expect(model.previewSessions.map(\.date) == [newDate])

                for (index, requested) in [true, false, true].enumerated() {
                    model.setReimportSelection([known.id], requested: requested)
                    #expect(model.importUIPhase == .review)
                    #expect(model.activeImportOperation == .reimportSelection)
                    #expect(!model.canImportPlannedFiles)
                    try await waitForImport(model)
                    #expect(model.importUIPhase == .review)
                    #expect(model.activeImportOperation == nil)
                    #expect(model.previewRows.first { $0.id == known.id }?.willCopy == requested)
                    #expect(model.previewSessions.first { $0.date == newDate }?.label == "New Photos")
                    if requested {
                        let dateIndex = try #require(model.previewSessions.firstIndex { $0.date == known.date })
                        #expect(model.previewSessions[dateIndex].photoCount == 1)
                        if index == 0 {
                            model.previewSessions[dateIndex].label = "Earlier Photos"
                            model.previewSessions[dateIndex].includeSidecars = true
                        } else {
                            #expect(model.previewSessions[dateIndex].label == "Earlier Photos")
                            #expect(model.previewSessions[dateIndex].includeSidecars)
                        }
                    } else {
                        #expect(model.previewSessions.map(\.date) == [newDate])
                    }
                }
                #expect(model.scanBothSession?.entries[1].confirmation != nil)

                model.importCurrentJob()
                try #require(model.scanBothSession?.entries[0].confirmation != nil)
                model.reviewScanBothVolume(entry.id)
                let latestDestination = root.appendingPathComponent("Latest Destination")
                try fm.createDirectory(at: latestDestination, withIntermediateDirectories: false)
                model.photosPath = latestDestination.path
                model.videosPath = latestDestination.path
                model.destinationPathDidChange(clearFeedback: false)
                model.setReimportSelection([known.id], requested: false)
                try await waitForImport(model)
                let latestDraft = model.currentImportDraft
                model.returnToScanBothResults()
                #expect(!model.canStartScanBothImports)
                #expect(model.scanBothSession?.entries[0].confirmation == nil)
                #expect(model.scanBothSession?.entries[1].confirmation != nil)

                model.reviewScanBothVolume(entry.id)
                #expect(model.currentImportDraft == latestDraft)
                model.setReimportSelection([known.id], requested: true)
                try await waitForImport(model)
                #expect(model.previewRows.first { $0.id == known.id }?.willCopy == true)
                #expect(model.previewSessions.first { $0.date == known.date }?.label == "Earlier Photos")
            }
            if (scenario == .firstVolumeDisconnectsBeforeSecond || scenario == .receiptAfterHistoryNavigation),
               entry.volume == first {
                let customDestination = root.appendingPathComponent("CustomDestination")
                try fm.createDirectory(at: customDestination, withIntermediateDirectories: false)
                model.photosPath = customDestination.path
                model.videosPath = customDestination.path
                model.destinationPathDidChange(clearFeedback: false)
            }
            if replacesParent {
                model.useImportMediaSelection(.photosAndVideos)
                model.useDestinationLayout(.singleLibrary)
                model.useFolderGrouping(entry.volume == first ? .oneShootFolder : .byDay)
            }
            if (hasLaterFile || stopsDuringFirstFile), entry.volume == first {
                let path = try #require(model.previewRows.first(where: \.willCopy)?.destinationPath)
                sharedDestination = URL(fileURLWithPath: path).deletingLastPathComponent()
            }
            if scenario == .destinationChangesInWorker, entry.volume == first {
                let path = try #require(model.previewRows.first(where: \.willCopy)?.destinationPath)
                lateConflictPath = URL(fileURLWithPath: path)
            }
            model.importCurrentJob()
        }
        model.reviewScanBothVolume(entries[0].id)
        model.returnToScanBothResults()
        #expect(model.canStartScanBothImports)
        #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)

        let changeInWorker: URL?
        switch scenario {
        case .sourceChangesInWorker, .sourceChangesInSameSecond, .sourceChangesWithPortableHistory, .sourceMissingInWorker:
            changeInWorker = firstFile
        default:
            changeInWorker = lateConflictPath
        }
        lateChange.withLock { $0 = changeInWorker }
        if scenario == .sourceFolderMissingBeforeStart {
            try fm.moveItem(at: internalFolder, to: movedSource)
        }
        if scenario == .knownSourceChangesBeforeStart {
            try Data("different data".utf8).write(to: firstFile)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: firstFile.path)
        }
        model.startScanBothImports()
        if scenario == .unmountNotificationBeforeCopy {
            model.invalidateScansAtUnmount(second.mountURL)
            unmountDelivered.signal()
        }
        if scenario == .unmountDuringCopy || stopsDuringFirstFile {
            let deadline = ContinuousClock.now + .seconds(5)
            while !reachedLateCopy.withLock({ $0 }), model.isWorking, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if scenario == .cancelDuringFirstCopy {
                model.cancelImport()
            } else {
                model.invalidateScansAtUnmount(second.mountURL)
            }
            unmountDelivered.signal()
            #expect(reachedLateCopy.withLock { $0 })
        }
        try await waitForImport(model)
        let after = try #require(model.scanBothSession)
        switch scenario {
        case .bothSucceed:
            #expect(after.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
            #expect(after.allowsAutomaticEjection)
        case .reimportKnownFile:
            #expect(after.entries.compactMap(\.result).map(\.importedFiles) == [2, 1])
        case .receiptAfterHistoryNavigation:
            let firstJobID = try #require(after.entries[0].jobID)
            let secondJobID = try #require(after.entries[1].jobID)
            try #require(after.entries.compactMap(\.result).map(\.importedFiles) == [2, 1])
            model.openImportInHistory(jobID: secondJobID)
            #expect(model.selectedJobID == secondJobID)
            model.loadJobDetail(jobID: firstJobID)
            let deadline = ContinuousClock.now + .seconds(5)
            while model.isHistoryDetailLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.selectedJobFiles.filter { $0.copyStatus == .copied }.count == 2)
            model.selection = .import
            let receipt = try #require(model.currentImportReceipt)
            #expect(receipt.result.jobID == secondJobID)
            #expect(receipt.job?.id == secondJobID)
            #expect(receipt.files.filter { $0.copyStatus == .copied }.map(\.filename) == [secondFile.lastPathComponent])
            #expect(receipt.files.first?.finalDestinationPath?.contains("/CustomDestination/") == false)
            model.openImportInHistory(jobID: receipt.result.jobID)
            #expect(model.selectedJobID == secondJobID)
        case .firstCopyChangesSecondPlan:
            #expect(after.entries[0].result?.importedFiles == 1)
            #expect(after.entries[1].confirmation == nil)
            #expect(model.importUIPhase == .review)
            #expect(!model.needsRescan(try #require(after.entries[1].jobID)))
            model.importCurrentJob()
            #expect(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries[1].result?.importedFiles == 1)
        case .destinationChangesInWorker:
            #expect(after.entries.allSatisfy { $0.result == nil })
            #expect(after.entries[1].confirmation != nil)
            #expect(model.importUIPhase == .review)
            let firstJobID = try #require(after.entries[0].jobID)
            #expect(!model.needsRescan(firstJobID))
            model.importCurrentJob()
            #expect(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
        case .destinationFillsInWorker:
            #expect(after.entries.allSatisfy { $0.result == nil })
            #expect(after.entries[1].confirmation != nil)
            #expect(model.importUIPhase == .review)
            #expect(!model.needsRescan(try #require(after.entries[0].jobID)))
            #expect(model.previewSpaceRequirements.contains { !$0.isSatisfied })
            #expect(model.canImportPlannedFiles)
            capacity.withLock { $0.available = true }
            model.importCurrentJob()
            #expect(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
        case .disconnectBeforeCopy, .unmountNotificationBeforeCopy:
            #expect(model.importUIPhase == .failed)
            #expect(model.importFailure?.message.contains(second.name) == true)
            #expect(after.entries.allSatisfy { $0.result == nil })
            #expect(!after.allowsEjection)
            #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
            model.returnToScanBothResults()
            model.skipScanBothImport(after.entries[1].id)
            let firstJobID = try #require(after.entries[0].jobID)
            #expect(!model.needsRescan(firstJobID))
            #expect(after.entries[0].confirmation != nil)
            #expect(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries[0].result?.importedFiles == 1)
        case .unmountDuringCopy:
            let folder = try #require(sharedDestination)
            #expect(model.importUIPhase == .failed)
            #expect(model.importFailure?.message.contains(second.name) == true)
            #expect(after.entries[0].result?.importedFiles == 1)
            #expect(after.entries[0].copyInterruption?.contains(second.name) == true)
            #expect(after.entries[1].result == nil)
            #expect(!after.allowsAutomaticEjection)
            #expect(try fm.contentsOfDirectory(atPath: folder.path) == [firstFile.lastPathComponent])
            model.returnToScanBothResults()
            #expect(model.scanBothSession?.entries[0].result?.importedFiles == 1)
        case .cancelDuringFirstCopy, .unmountDuringFirstCopy:
            let folder = try #require(sharedDestination)
            let firstJobID = try #require(after.entries[0].jobID)
            #expect(after.entries[1].result == nil)
            #expect(try fm.contentsOfDirectory(atPath: folder.path).isEmpty)
            model.returnToScanBothResults()
            if scenario == .cancelDuringFirstCopy {
                #expect(model.jobs.first { $0.id == firstJobID }?.status == .cancelled)
                #expect(model.scanBothSession?.entries[0].result?.importedFiles == 0)
                #expect(model.scanBothSession?.entries[0].copyInterruption != nil)
                #expect(model.scanBothSession?.entries[1].confirmation != nil)
                #expect(model.needsRescan(firstJobID))
            } else {
                #expect(model.jobs.allSatisfy { $0.id != firstJobID })
                #expect(model.scanBothSession?.entries[0].result == nil)
                #expect(model.scanBothSession?.entries[0].confirmation != nil)
                #expect(!model.needsRescan(firstJobID))
            }
        case .destinationReplacedAfterPartialCopy, .nestedDestinationReplacedAfterPartialCopy:
            let folder = try #require(sharedDestination)
            #expect(after.entries[0].result?.importedFiles == 1)
            #expect(after.entries[0].copyInterruption != nil)
            #expect(after.entries[1].confirmation != nil)
            let cardPath = try #require(after.entries[1].confirmation?.plans.first(where: \.willCopy)?.destinationPath)
            let cardFolder = URL(fileURLWithPath: cardPath).deletingLastPathComponent()
            try #require((replacesParent ? cardFolder.deletingLastPathComponent() : cardFolder).path == folder.path)
            model.returnToScanBothResults()
            model.skipScanBothImport(after.entries[0].id)
            let archive = root.appendingPathComponent("Archive", isDirectory: true)
            try fm.moveItem(at: folder, to: archive)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries[1].confirmation == nil)
            #expect(try fm.contentsOfDirectory(atPath: folder.path).isEmpty)
            model.importCurrentJob()
            #expect(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
            #expect(model.scanBothSession?.entries[0].copyInterruption != nil)
            #expect(try fm.contentsOfDirectory(atPath: archive.path) == [firstFile.lastPathComponent])
            #expect(try fm.contentsOfDirectory(atPath: cardFolder.path) == [secondFile.lastPathComponent])
            #expect(model.scanBothSession?.allowsAutomaticEjection == false)
        case .sourceChangesInWorker, .sourceChangesInSameSecond, .sourceChangesWithPortableHistory,
             .knownSourceChangesBeforeStart, .sourceMissingInWorker:
            let firstJobID = try #require(after.entries[0].jobID)
            #expect(model.needsRescan(firstJobID))
            #expect(after.entries[1].confirmation != nil)
            #expect(after.entries.allSatisfy { $0.result == nil })
            #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        case .sourceFolderMissingBeforeStart, .sourceFolderMissingInWorker:
            let firstJobID = try #require(after.entries[0].jobID)
            #expect(model.needsRescan(firstJobID))
            #expect(after.entries[0].confirmation == nil)
            #expect(after.entries[1].confirmation != nil)
            #expect(after.removedMountPaths.isEmpty)
            #expect(model.folderAccessFeedback != nil)
            #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        case .firstVolumeDisconnectsBeforeSecond:
            #expect(after.entries[0].result?.importedFiles == 1)
            #expect(after.entries[1].confirmation != nil)
            #expect(after.entries[1].result == nil)
            #expect(after.removedMountPaths.contains(first.mountPath))
            #expect(model.isShowingScanBothResults)
            model.destinationPathDidChange(clearFeedback: !model.isReviewingScanBothVolume)
            #expect(model.folderAccessFeedback?.text.contains(first.name) == true)
        }
    }

    @Test("Scan Both keeps re-import edits, date choices, and drafts separate from approval")
    func reimportsKnownFileInBatch() async throws {
        try await startsBatchThroughAppModel(.reimportKnownFile)
    }

    private func waitForImport(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isWorking, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isWorking)
    }
}
