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
                nil
            )
        }

        #expect(order == [internalStorage.name, card.name])
        let completed = states[declineFirst ? 1 : 0]
        let skipped = states[declineFirst ? 0 : 1]
        if case .complete(let summary, _, _) = completed {
            #expect(summary.volumeName == completedVolume.name)
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
            return .complete(summary, nil)
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
            guard let summary = entry.summary else {
                Issue.record("Missing scan result for \(volume.name)")
                return
            }
            #expect(summary.jobID == job.id)
            #expect(summary.scannedFiles == expectedNames.count)
            #expect(summary.mountPath == sourceFolders[volume.name]?.path)
            let files = try repository.fetchJobFiles(jobID: job.id)
            #expect(Set(files.map(\.filename)) == Set(expectedNames))
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
                destinations: try #require(ReviewedImportDestinations(plans: plans)),
                copyFileCount: 0, destinationPaths: []
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
                destinations: try #require(ReviewedImportDestinations(plans: freshSecondPlans)),
                copyFileCount: 0, destinationPaths: []
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
                destinations: try #require(ReviewedImportDestinations(plans: [])),
                copyFileCount: 0, destinationPaths: []
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
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = base.appendingPathComponent("Original", isDirectory: true)
        let replacement = base.appendingPathComponent("Replacement", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for folder in [original, replacement] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let originalRoot = try #require(ReviewedImportDestinations.Root(at: original))
        let replacementRoot = try #require(ReviewedImportDestinations.Root(at: replacement))
        let selectedOriginal = session.setDestination(originalRoot, access: nil)
        #expect(selectedOriginal)
        #expect(!session.hasStartedImports)
        session.recordImportStarted(for: jobID)
        #expect(session.hasStartedImports)
        let changedAfterStart = session.setDestination(replacementRoot, access: nil)
        #expect(!changedAfterStart)
        #expect(session.destinationPath == original.path)
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
        session.skipEntry(session.entries[0].id)
        let changedAfterSkip = session.setDestination(replacementRoot, access: nil)
        #expect(!changedAfterSkip)
        #expect(session.destinationPath == original.path)
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

    @Test("equal volume names use their distinct mount paths")
    func disambiguatesDuplicateVolumeNames() throws {
        let first = Self.volume("CAMERA", disk: "disk4", at: URL(fileURLWithPath: "/Volumes/CAMERA"))
        let second = Self.volume("CAMERA", disk: "disk5", at: URL(fileURLWithPath: "/Volumes/CAMERA 1"))
        let session = try #require(ScanBothSession(deviceName: "Fixture Camera", entries: [
            .init(id: UUID(), volume: first), .init(id: UUID(), volume: second)
        ]))
        let titles = session.entries.map { session.volumeTitle(for: $0) }
        #expect(titles[0].hasSuffix(first.mountPath))
        #expect(titles[1].hasSuffix(second.mountPath))
        #expect(titles[0] != titles[1])

        let distinctSession = try scannedSession()
        #expect(distinctSession.entries.map { distinctSession.volumeTitle(for: $0) }
            == distinctSession.entries.map(\.volume.name))
    }

    @Test("switching inline plans saves the draft and keeps the sibling approved")
    func switchesInlinePlans() async throws {
        try await withScannedInlinePlans { model, session, roots in
            let internalID = session.entries[0].id
            let cardID = session.entries[1].id

            model.reviewScanBothVolume(internalID)
            model.location = "Modified Internal Plan"
            model.reviewScanBothVolume(cardID)
            #expect(model.importUIPhase == .review)
            #expect(model.scanBothSession?.reviewingEntry?.id == cardID)
            #expect(model.scanBothSession?.entries[0].draft?.shootName == "Modified Internal Plan")
            #expect(model.importMediaSelection == .videosOnly)
            let previewPaths = model.previewDestinations.map(\.path)
            try #require(previewPaths.count == 1)
            #expect(previewPaths[0].hasPrefix(roots.photosURL.path + "/"))
            model.importCurrentJob()
            let approvedCard = try #require(model.scanBothSession?.entries[1].confirmation)
            #expect(approvedCard.copyFileCount == 1)
            #expect(approvedCard.destinationPaths == previewPaths)
            #expect(!model.canStartScanBothImports)

            model.reviewScanBothVolume(internalID)
            #expect(model.location == "Modified Internal Plan")
            #expect(model.scanBothSession?.entries[1].confirmation?.destinationPaths == previewPaths)
            #expect(model.scanBothSession?.entries[1].confirmation?.plans == approvedCard.plans)
            model.skipScanBothImport(internalID)
            #expect(model.scanBothSession?.reviewingEntry == nil)
            #expect(model.scanBothSession?.entries[0].disposition == .skipped)
            #expect(model.canStartScanBothImports)
            #expect(try FileManager.default.contentsOfDirectory(atPath: roots.photosURL.path).isEmpty)
        }
    }

    @Test("the active Scan Both review reports a disconnect and keeps the sibling confirmed")
    func reportsDisconnectInActiveReview() async throws {
        try await withScannedInlinePlans { model, session, _ in
            let editing = session.entries[0]
            let sibling = session.entries[1]
            model.reviewScanBothVolume(sibling.id)
            model.importCurrentJob()
            let approval = try #require(model.scanBothSession?.entries[1].confirmation)

            model.reviewScanBothVolume(editing.id)
            let jobID = try #require(model.currentSummary?.jobID)
            try #require(model.canImportPlannedFiles)
            #expect(model.scanBothSession?.removedMountPaths.isEmpty == true)

            model.invalidateScansAtUnmount(editing.volume.mountURL)
            #expect(model.scanBothSession?.reviewingEntry?.id == editing.id)
            #expect(model.scanBothSession?.removedMountPaths == [editing.volume.mountPath])
            #expect(model.needsRescan(jobID))
            #expect(!model.canImportPlannedFiles)
            #expect(model.scanBothSession?.entries[1].confirmation?.plans == approval.plans)

            model.returnToScanBothResults()
            #expect(model.scanBothSession?.removedMountPaths == [editing.volume.mountPath])
            #expect(model.scanBothSession?.entries[1].confirmation?.plans == approval.plans)
        }
    }

    enum RecordingCollisionScenario: CaseIterable {
        case shootName
        case skipVolume
        case customDateFolder
        case unicodeShootNames
        case redirectedFolder
    }

    @Test("Scan Both checks destinations before copying and keeps the plans editable", arguments: RecordingCollisionScenario.allCases)
    func detectsRecordingCollisionBeforeStarting(scenario: RecordingCollisionScenario) async throws {
        let filenames = ["VID_20181001_210458_00_009.insv", "VID_20181001_210458_10_009.insv"]
        let manager = FileManager.default
        try await withScannedInlinePlans(populateSources: { internalFolder, cardFolder in
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            for folder in [internalFolder, cardFolder] {
                for filename in filenames {
                    let file = folder.appendingPathComponent(filename)
                    try Data("\(folder.lastPathComponent): \(filename)".utf8).write(to: file)
                    try manager.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: file.path)
                }
            }
        }) { model, session, roots in
            for (index, entry) in session.entries.enumerated() {
                model.reviewScanBothVolume(entry.id)
                switch scenario {
                case .unicodeShootNames:
                    model.location = index == 0 ? "Straße" : "Strasse"
                case .redirectedFolder where index == 1:
                    model.location = "Other Shoot"
                case .customDateFolder:
                    model.previewSessions[0].label = "Custom Date Folder"
                default:
                    break
                }
                model.importCurrentJob()
            }
            try #require(model.canStartScanBothImports)
            let approvedSession = try #require(model.scanBothSession)
            let approvals = approvedSession.entries.compactMap(\.confirmation)
            try #require(approvals.count == 2)
            let firstPath = try #require(approvals[0].plans.first?.destinationPath)
            let secondPath = try #require(approvals[1].plans.first?.destinationPath)
            let firstFolder = URL(fileURLWithPath: firstPath).deletingLastPathComponent()
            let secondFolder = URL(fileURLWithPath: secondPath).deletingLastPathComponent()
            if scenario == .redirectedFolder {
                try manager.createDirectory(at: firstFolder, withIntermediateDirectories: true)
                try manager.createSymbolicLink(at: secondFolder, withDestinationURL: firstFolder)
            }

            if scenario == .unicodeShootNames,
               try roots.photosURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                   .volumeSupportsCaseSensitiveNames == true {
                model.startScanBothImports()
                try await waitForImport(model)
                #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
                return
            }

            model.startScanBothImports()
            await Task.yield()
            #expect(model.isShowingScanBothResults)
            #expect(!model.isWorking)
            #expect(model.scanBothSession?.hasStartedImports == false)
            #expect(model.scanBothSession?.entries.allSatisfy { $0.result == nil } == true)
            let message = try #require(model.folderAccessFeedback?.text)
            if scenario == .redirectedFolder {
                #expect(message == L10n.tr("The import plan changed. Review it before copying."))
                #expect(model.scanBothSession?.entries[0].confirmation?.plans == approvals[0].plans)
                #expect(model.scanBothSession?.entries[1].confirmation == nil)
                try manager.removeItem(at: secondFolder)
            } else {
                #expect(message.contains(session.entries[0].volume.name))
                #expect(message.contains(session.entries[1].volume.name))
                #expect(filenames.contains { message.contains($0) })
                #expect(model.scanBothSession?.entries.allSatisfy { $0.confirmation != nil } == true)
            }
            #expect(try manager.subpathsOfDirectory(atPath: roots.photosURL.path).allSatisfy { !$0.hasSuffix(".insv") })

            let second = session.entries[1]
            if scenario == .skipVolume {
                model.skipScanBothImport(second.id)
            } else {
                model.reviewScanBothVolume(second.id)
                #expect(!model.isScanBothPlanLocked)
                if scenario == .customDateFolder {
                    #expect(message.localizedCaseInsensitiveContains(L10n.tr("Customize Dates")))
                    #expect(message.localizedCaseInsensitiveContains(L10n.tr("Folder label")))
                    model.previewSessions[0].label = "Different Date Folder"
                } else {
                    model.location = "Different Shoot"
                }
                model.importCurrentJob()
            }
            #expect(model.folderAccessFeedback == nil)
            try #require(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            let skipsSecondVolume = scenario == .skipVolume
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == (skipsSecondVolume ? [1] : [1, 1]))
            let outputs = try manager.subpathsOfDirectory(atPath: roots.photosURL.path).filter { $0.hasSuffix(".insv") }
            #expect(outputs.count == (skipsSecondVolume ? 2 : 4))
        }
    }

    @Test("cancelling a new scan restores the edited draft and requires another confirmation")
    func restoresEditedDraftAfterCancelledScan() async throws {
        try await withScannedInlinePlans { model, session, roots in
            for entry in session.entries {
                model.reviewScanBothVolume(entry.id)
                model.importCurrentJob()
            }
            try #require(model.canStartScanBothImports)
            let cardApproval = try #require(model.scanBothSession?.entries[1].confirmation)

            let internalID = session.entries[0].id
            model.reviewScanBothVolume(internalID)
            model.location = "Edited Internal Plan"

            model.beginScanBoth(session)
            model.cancelImport()
            try await waitForImport(model)
            let restored = try #require(model.scanBothSession)
            #expect(model.importUIPhase == .review)
            #expect(restored.reviewingEntry == nil)
            #expect(restored.destinationPath == roots.photosURL.path)
            #expect(restored.entries[0].draft?.shootName == "Edited Internal Plan")
            #expect(restored.entries[0].confirmation == nil)
            #expect(restored.entries[1].confirmation?.plans == cardApproval.plans)
            #expect(!model.canStartScanBothImports)

            model.reviewScanBothVolume(internalID)
            #expect(model.location == "Edited Internal Plan")
            model.importCurrentJob()
            try #require(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
            let copiedPaths = try FileManager.default.subpathsOfDirectory(atPath: roots.photosURL.path)
            #expect(copiedPaths.contains { $0.hasSuffix("/Internal.jpg") })
            #expect(copiedPaths.contains { $0.hasSuffix("/Card.mp4") })
        }
    }

    @Test("both volumes use the chosen destination and changing it clears both approvals")
    func confirmsPlansUnderOneDestination() async throws {
        try await withScannedInlinePlans(usesSharedDefault: false) { model, session, roots in
            #expect(model.scanBothSession?.destinationPath == "")
            model.reviewScanBothVolume(session.entries[0].id)
            #expect(model.scanBothSession?.reviewingEntry == nil)
            model.setScanBothDestination(roots.photosURL)

            for entry in session.entries {
                model.reviewScanBothVolume(entry.id)
                model.location = "Trip \(entry.volume.name)"
                model.importCurrentJob()
            }
            try #require(model.canStartScanBothImports)

            model.setScanBothDestination(roots.videosURL)
            #expect(model.scanBothSession?.entries.allSatisfy { $0.confirmation == nil } == true)
            #expect(!model.canStartScanBothImports)
            for entry in session.entries {
                model.reviewScanBothVolume(entry.id)
                #expect(model.location == "Trip \(entry.volume.name)")
                #expect(model.previewDestinations.count == 1)
                #expect(model.previewDestinations.first?.path.hasPrefix(roots.videosURL.path + "/") == true)
                model.importCurrentJob()
            }
            try #require(model.canStartScanBothImports)
            #expect(try FileManager.default.contentsOfDirectory(atPath: roots.videosURL.path).isEmpty)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
            let copiedPaths = try FileManager.default.subpathsOfDirectory(atPath: roots.videosURL.path)
            #expect(copiedPaths.contains { $0.hasSuffix("/Internal.jpg") })
            #expect(copiedPaths.contains { $0.hasSuffix("/Card.mp4") })
            #expect(try FileManager.default.contentsOfDirectory(atPath: roots.photosURL.path).isEmpty)
            #expect(model.importDefaults.photosPath == roots.photosURL.path)
            #expect(model.importDefaults.videosPath == roots.videosURL.path)
            model.setScanBothDestination(roots.photosURL)
            #expect(model.scanBothSession?.destinationPath == roots.videosURL.path)
        }
    }

    @Test("Scan Both requires choosing a renamed destination before copying", arguments: [false, true])
    func requiresSelectingRenamedDestination(confirmedBeforeRename: Bool) async throws {
        try await withScannedInlinePlans { model, session, roots in
            let fixtureRoot = roots.photosURL.deletingLastPathComponent()
            let original = fixtureRoot.appendingPathComponent("Library ", isDirectory: true)
            let renamed = fixtureRoot.appendingPathComponent("Library", isDirectory: true)
            let manager = FileManager.default
            try manager.createDirectory(at: original, withIntermediateDirectories: false)
            model.setScanBothDestination(original)
            try #require(model.scanBothDestinationValidation.isUsable)

            if confirmedBeforeRename {
                for entry in session.entries {
                    model.reviewScanBothVolume(entry.id)
                    model.importCurrentJob()
                }
                try #require(model.canStartScanBothImports)
            } else {
                model.reviewScanBothVolume(session.entries[0].id)
                try #require(model.canImportPlannedFiles)
            }

            try manager.moveItem(at: original, to: renamed)
            #expect(model.scanBothDestinationValidation.status == .missing)
            if confirmedBeforeRename {
                model.startScanBothImports()
            } else {
                model.importCurrentJob()
            }
            #expect(model.activeImportOperation == nil)
            #expect(model.scanBothSession?.entries[0].confirmation == nil)
            #expect(!model.canImportPlannedFiles)
            #expect(!manager.fileExists(atPath: original.path))
            #expect(try manager.contentsOfDirectory(atPath: renamed.path).isEmpty)

            model.setScanBothDestination(renamed)
            model.returnToScanBothResults()
            for entry in session.entries {
                model.reviewScanBothVolume(entry.id)
                model.importCurrentJob()
            }
            try #require(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
            #expect(!manager.fileExists(atPath: original.path))
            let paths = try manager.subpathsOfDirectory(atPath: renamed.path)
            #expect(paths.contains { $0.hasSuffix("/Internal.jpg") })
            #expect(paths.contains { $0.hasSuffix("/Card.mp4") })
        }
    }

    @Test("Scan Both requires reselecting a replacement at the same path before copying")
    func requiresSelectingReplacementDestination() async throws {
        try await withScannedInlinePlans { model, session, roots in
            let destination = roots.photosURL
            let moved = destination.deletingLastPathComponent().appendingPathComponent("Moved")
            model.reviewScanBothVolume(session.entries[0].id)
            model.importCurrentJob()
            try #require(model.scanBothSession?.entries[0].confirmation != nil)

            try FileManager.default.moveItem(at: destination, to: moved)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            model.reviewScanBothVolume(session.entries[1].id)
            #expect(model.scanBothDestinationValidation.isUsable)
            #expect(model.scanBothDestinationChangeMessage != nil)
            #expect(!model.canImportPlannedFiles)
            model.importCurrentJob()
            #expect(model.scanBothSession?.entries[1].confirmation == nil)

            model.setScanBothDestination(destination)
            #expect(model.scanBothDestinationChangeMessage == nil)
            #expect(model.scanBothSession?.entries[0].confirmation == nil)
            #expect(model.canImportPlannedFiles)
        }
    }

    @Test("Scan Both keeps the original folder identity between volumes")
    func rejectsReplacementDestinationAfterFirstCopy() async throws {
        let relocation = OSAllocatedUnfairLock(initialState: Optional<(original: URL, moved: URL)>.none)
        try await withScannedInlinePlans(observeCopyProgress: { progress in
            guard progress.status == "completed" else { return }
            relocation.withLock { folders in
                guard let current = folders else { return }
                folders = nil
                do {
                    try FileManager.default.moveItem(at: current.original, to: current.moved)
                    try FileManager.default.createDirectory(at: current.original, withIntermediateDirectories: false)
                } catch {
                    Issue.record("Could not replace the destination folder: \(error)")
                }
            }
        }) { model, session, roots in
            let destination = roots.photosURL
            let moved = destination.deletingLastPathComponent().appendingPathComponent("Moved")
            for entry in session.entries {
                model.reviewScanBothVolume(entry.id)
                model.importCurrentJob()
            }
            try #require(model.canStartScanBothImports)
            relocation.withLock { $0 = (destination, moved) }
            model.startScanBothImports()
            try await waitForImport(model)

            #expect(model.scanBothSession?.entries[0].result?.importedFiles == 1)
            #expect(model.scanBothSession?.reviewingEntry?.id == session.entries[1].id)
            #expect(model.isScanBothPlanLocked)
            #expect(model.scanBothDestinationChangeMessage != nil)
            model.setScanBothDestination(destination)
            model.importCurrentJob()
            #expect(model.scanBothSession?.entries[1].confirmation == nil)
            #expect(!model.canStartScanBothImports)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)

            try FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: moved, to: destination)
            #expect(model.scanBothDestinationChangeMessage == nil)
            model.importCurrentJob()
            try #require(model.canStartScanBothImports)
            model.startScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
            let paths = try FileManager.default.subpathsOfDirectory(atPath: destination.path)
            #expect(paths.contains { $0.hasSuffix("/Internal.jpg") })
            #expect(paths.contains { $0.hasSuffix("/Card.mp4") })
        }
    }

    @Test("saving a Scan Both plan as defaults keeps destination settings changed during review")
    func savingPlanDefaultsKeepsDestinations() async throws {
        try await withScannedInlinePlans { model, session, roots in
            model.reviewScanBothVolume(session.entries[0].id)
            let sharedPath = model.scanBothSession?.destinationPath
            model.importDefaults.photosPath = roots.videosURL.path
            await model.validateAndSaveDestinationSettings()

            model.location = "New Shoot Label"
            #expect(!model.importDraftUsesDefaults)
            model.saveImportDraftAsDefaults()

            #expect(model.importDefaults.shootName == "New Shoot Label")
            #expect(model.importDefaults.photosPath == roots.videosURL.path)
            #expect(model.importDefaults.videosPath == roots.photosURL.path)
            #expect(model.scanBothSession?.destinationPath == sharedPath)
            #expect(model.importDraftUsesDefaults)
        }
    }

    @Test("Scan Both keeps each volume's warning until a fresh review or destination change")
    func retainsRelevantReviewWarnings() async throws {
        let hasSpace = OSAllocatedUnfairLock(initialState: false)
        try await withScannedInlinePlans(destinationCapacity: { path in
            VolumeCapacity(
                volumeID: "fixture", displayPath: path,
                availableBytes: hasSpace.withLock { $0 } ? 1_000_000 : 0, totalBytes: 1_000_000
            )
        }) { model, session, roots in
            let internalID = session.entries[0].id
            let cardID = session.entries[1].id
            model.reviewScanBothVolume(internalID)
            #expect(model.previewNeedsAttention)

            model.reviewScanBothVolume(cardID)
            #expect(model.scanBothSession?.entries[0].reviewNeedsAttention == true)
            model.returnToScanBothResults()
            #expect(model.scanBothSession?.entries.allSatisfy(\.reviewNeedsAttention) == true)

            hasSpace.withLock { $0 = true }
            model.reviewScanBothVolume(internalID)
            #expect(!model.previewNeedsAttention)
            model.returnToScanBothResults()
            #expect(model.scanBothSession?.entries[0].reviewNeedsAttention == false)
            #expect(model.scanBothSession?.entries[1].reviewNeedsAttention == true)

            model.setScanBothDestination(roots.videosURL)
            #expect(model.scanBothSession?.entries.contains(where: \.reviewNeedsAttention) == false)
            model.reviewScanBothVolume(cardID)
            #expect(!model.previewNeedsAttention)
        }
    }

    @Test("one shared review starts both volumes in order and uses a common shoot folder")
    func startsSharedPlanInVolumeOrder() async throws {
        try await withScannedInlinePlans(populateSources: { internalFolder, cardFolder in
            let photo = internalFolder.appendingPathComponent("Internal.jpg")
            let video = cardFolder.appendingPathComponent("Card.mp4")
            for (index, file) in [photo, video].enumerated() {
                try Data(file.lastPathComponent.utf8).write(to: file)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 172_800)],
                    ofItemAtPath: file.path
                )
            }
        }) { model, session, _ in
            model.updateSharedScanBothReview(\.shootName, to: "Hawaii")
            model.updateSharedScanBothReview(\.mediaSelection, to: .photosOnly)
            let internalID = session.entries[0].id
            let cardID = session.entries[1].id
            #expect(model.scanBothSession?.sharedReview?.volumes[cardID]?.totals.copyFiles == 0)
            model.updateSharedScanBothReview(\.mediaSelection, to: .photosAndVideos)
            model.updateSharedScanBothReview(\.folderGrouping, to: .oneShootFolder)

            model.skipScanBothImport(cardID)
            let skipped = try #require(model.scanBothSession)
            #expect(skipped.sharedReview?.queuedEntries(in: skipped).map(\.id) == [internalID])
            model.includeScanBothImport(cardID)
            let included = try #require(model.scanBothSession)
            let review = try #require(included.sharedReview)
            #expect(review.queuedEntries(in: included).map(\.id) == [internalID, cardID])
            #expect(review.totals(in: included).copyFiles == 2)
            #expect(review.volumes[cardID]?.paths == review.volumes[internalID]?.paths)
            let destination = try #require(review.volumes[internalID]?.paths.first)
            #expect(destination.contains("Hawaii"))
            #expect(included.entries.allSatisfy { $0.confirmation == nil })
            try #require(model.canStartSharedScanBothImports)

            model.startSharedScanBothImports()
            try await waitForImport(model)

            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1, 1])
            #expect(model.scanBothSession?.hasStartedImports == true)
            model.updateSharedScanBothReview(\.shootName, to: "Other")
            #expect(model.scanBothSession?.sharedReview?.shootName == "Hawaii")
            let files = try FileManager.default.contentsOfDirectory(atPath: destination)
            #expect(Set(files) == ["Internal.jpg", "Card.mp4"])
        }
    }

    @Test("the shared review stops before any copy if only one volume would fit")
    func blocksWhenCombinedSpaceDoesNotFit() async throws {
        try await withScannedInlinePlans(destinationCapacity: { path in
            VolumeCapacity(volumeID: "fixture", displayPath: path, availableBytes: 9, totalBytes: 100)
        }) { model, _, roots in
            model.updateSharedScanBothReview(\.mediaSelection, to: .photosAndVideos)
            #expect(model.scanBothSession?.sharedReview?.blockingMessage?.contains("Not enough space") == true)
            model.startSharedScanBothImports()
            #expect(!model.isWorking)
            #expect(model.scanBothSession?.hasStartedImports == false)
            let files = try FileManager.default.contentsOfDirectory(atPath: roots.photosURL.path)
            #expect(files.isEmpty)
        }
    }

    @Test("the shared review blocks a cross-volume filename collision before any copy")
    func blocksSharedFilenameCollision() async throws {
        try await withScannedInlinePlans(populateSources: { internalFolder, cardFolder in
            try Data("internal".utf8).write(to: internalFolder.appendingPathComponent("IMG_001.jpg"))
            try Data("card".utf8).write(to: cardFolder.appendingPathComponent("IMG_001.jpg"))
        }) { model, session, roots in
            model.updateSharedScanBothReview(\.mediaSelection, to: .photosAndVideos)
            model.updateSharedScanBothReview(\.folderGrouping, to: .oneShootFolder)
            #expect(model.scanBothSession?.sharedReview?.blockingMessage?.contains("IMG_001.jpg") == true)
            model.startSharedScanBothImports()
            #expect(model.scanBothSession?.hasStartedImports == false)
            #expect(try FileManager.default.contentsOfDirectory(atPath: roots.photosURL.path).isEmpty)
            model.skipScanBothImport(session.entries[1].id)
            #expect(model.scanBothSession?.sharedReview?.blockingMessage == nil)
            model.startSharedScanBothImports()
            try await waitForImport(model)
            #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [1])
        }
    }

    @Test("a changed second destination stops the whole batch and appears in the shared review")
    func refreshesBothVolumesBeforeStarting() async throws {
        try await withScannedInlinePlans { model, session, roots in
            model.updateSharedScanBothReview(\.mediaSelection, to: .photosAndVideos)
            let cardID = session.entries[1].id
            let path = try #require(model.scanBothSession?.sharedReview?.volumes[cardID]?.rows.first?.destinationPath)
            let planned = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: planned.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("conflicting destination".utf8).write(to: planned)

            model.startSharedScanBothImports()

            #expect(model.scanBothSession?.hasStartedImports == false)
            #expect(model.folderAccessFeedback?.text.contains("The import plan changed") == true)
            let refreshed = model.scanBothSession?.sharedReview?.volumes[cardID]?.rows.first?.destinationPath
            #expect(refreshed != path)
            #expect(try FileManager.default.subpathsOfDirectory(atPath: roots.photosURL.path).allSatisfy {
                !$0.hasSuffix("Internal.jpg")
            })
        }
    }

    @Test("the shared plan refuses to start if a scanned source folder disappears")
    func blocksSharedPlanWhenSecondSourceIsGone() async throws {
        try await withScannedInlinePlans { model, session, roots in
            let card = session.entries[1].volume
            let moved = card.mountURL.deletingLastPathComponent().appendingPathComponent("Removed")
            try FileManager.default.moveItem(at: card.mountURL, to: moved)
            model.startSharedScanBothImports()
            #expect(model.scanBothSession?.hasStartedImports == false)
            let jobID = try #require(model.scanBothSession?.entries[1].jobID)
            #expect(model.needsRescan(jobID))
            let files = try FileManager.default.contentsOfDirectory(atPath: roots.photosURL.path)
            #expect(files.isEmpty)
        }
    }

    @Test("a re-import choice in the shared review stays with its source volume")
    func appliesSharedReimportToOneVolume() async throws {
        try await withScannedInlinePlans { model, session, roots in
            model.startSharedScanBothImports()
            try await waitForImport(model)
            try #require(model.scanBothSession?.entries.allSatisfy { $0.result?.importedFiles == 1 } == true)

            model.beginScanBoth(session)
            try await waitForImport(model)
            model.setScanBothDestination(roots.videosURL)
            let internalID = session.entries[0].id
            let cardID = session.entries[1].id
            let review = try #require(model.scanBothSession?.sharedReview)
            let eligibleFile = review.volumes[internalID]?.rows.first(where: \.canReimport)
            let known = try #require(eligibleFile)
            #expect(review.volumes[internalID]?.totals.copyFiles == 0)
            #expect(review.volumes[cardID]?.totals.copyFiles == 0)

            model.setReimportSelection([known.id], requested: true, volumeID: internalID)
            try await waitForImport(model)
            #expect(model.scanBothSession?.sharedReview?.volumes[internalID]?.totals.copyFiles == 1)
            #expect(model.scanBothSession?.sharedReview?.volumes[cardID]?.totals.copyFiles == 0)

            model.setReimportSelection([known.id], requested: false, volumeID: internalID)
            try await waitForImport(model)
            #expect(model.scanBothSession?.sharedReview?.volumes[internalID]?.totals.copyFiles == 0)
        }
    }

    private func withScannedInlinePlans(
        usesSharedDefault: Bool = true,
        destinationCapacity: @escaping DestinationSpaceChecker.CapacityProvider = DestinationSpaceChecker.fileSystemCapacity,
        observeCopyProgress: (@Sendable (ImportProgress) -> Void)? = nil,
        populateSources: ((URL, URL) throws -> Void)? = nil,
        _ test: (AppModel, ScanBothSession, DestinationRoots) async throws -> Void
    ) async throws {
        let manager = FileManager.default
        let identifier = UUID().uuidString
        let root = manager.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
        let suite = "SDImportTests.InlinePlans.\(identifier)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: root)
        }
        let internalFolder = root.appendingPathComponent("Internal", isDirectory: true)
        let cardFolder = root.appendingPathComponent("SD Card", isDirectory: true)
        let roots = DestinationRoots(
            photosURL: root.appendingPathComponent("Photos", isDirectory: true).resolvingSymlinksInPath(),
            videosURL: root.appendingPathComponent("Videos", isDirectory: true).resolvingSymlinksInPath()
        )
        for folder in [internalFolder, cardFolder, roots.photosURL, roots.videosURL] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if let populateSources {
            try populateSources(internalFolder, cardFolder)
        } else {
            try Data("internal".utf8).write(to: internalFolder.appendingPathComponent("Internal.jpg"))
            try Data("card".utf8).write(to: cardFolder.appendingPathComponent("Card.mp4"))
        }
        let session = try #require(ScanBothSession(deviceName: "Fixture Camera", entries: [
            .init(id: UUID(), volume: Self.volume("Internal", disk: "disk4", at: internalFolder)),
            .init(id: UUID(), volume: Self.volume("SD Card", disk: "disk5", at: cardFolder))
        ]))
        let model = AppModel(
            purchaseManager: PurchaseManager(distribution: .direct, startsStoreTask: false),
            defaults: defaults, startsBootstrap: false, scanBothMountLookup: { $0 },
            destinationCapacity: destinationCapacity, observeCopyProgress: observeCopyProgress
        )
        model.bootstrap(at: root.appendingPathComponent("State"), startsRuntimeServices: false)
        model.ejectAfterSuccessfulImport = false
        model.importDefaults.photosPath = roots.photosURL.path
        model.importDefaults.videosPath = usesSharedDefault ? roots.photosURL.path : roots.videosURL.path
        model.importDefaults.destinationLayout = .singleLibrary
        model.beginScanBoth(session)
        try await waitForImport(model)
        try await test(model, session, roots)
    }

    @Test("cross-volume collision detection uses resolved recording destinations")
    func detectsRecordingCollisionThroughDestinationAlias() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let actual = root.appendingPathComponent("Actual", isDirectory: true)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try manager.createDirectory(at: actual, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createSymbolicLink(at: alias, withDestinationURL: actual)

        for filename in ["VID_20181001_210458_00_009.INSV", "Photo.jpg"] {
            let plans = [actual, alias].map { folder in
                ImportFilePlan(
                    update: nil, willCopy: true, disposition: .copy,
                    destinationPath: folder.appendingPathComponent("Pending Shoot/\(filename)").path
                )
            }
            let first = try #require(ReviewedImportDestinations(plans: [plans[0]]))
            let second = try #require(ReviewedImportDestinations(plans: [plans[1]]))
            let collision = first.firstRecordingFilenameCollision(in: [plans[0]], with: second, siblingPlans: [plans[1]])
            #expect(collision == (filename.hasSuffix(".INSV") ? filename : nil))
        }
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
        if scenario == .firstVolumeDisconnectsBeforeSecond || scenario == .receiptAfterHistoryNavigation {
            let customDestination = root.appendingPathComponent("CustomDestination")
            try fm.createDirectory(at: customDestination, withIntermediateDirectories: false)
            model.setScanBothDestination(customDestination)
        }
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
                let receipt = PortableFileIdentity(
                    size: known.size, modificationTimeEpochSeconds: 1_700_000_000, relativePath: firstFile.lastPathComponent
                )
                try ledger.append(identity: receipt)
                model.reviewScanBothVolume(entry.id)
                #expect(model.previewSessions.map(\.date) == [newDate])

                try fm.removeItem(at: ledger.ledgerURL)
                model.importCurrentJob()
                #expect(model.importUIPhase == .review)
                #expect(model.scanBothSession?.entries[0].confirmation == nil)
                #expect(model.previewRows.first { $0.id == known.id }?.willCopy == true)
                #expect(model.previewSessions.map(\.date) == [known.date, newDate].sorted())
                #expect(model.previewSessions.first { $0.date == known.date }?.photoCount == 1)
                #expect(model.previewSessions.first { $0.date == newDate }?.label == "New Photos")

                try ledger.append(identity: receipt)
                model.importCurrentJob()
                #expect(model.importUIPhase == .review)
                #expect(model.scanBothSession?.entries[0].confirmation == nil)
                #expect(model.scanBothSession?.entries[1].confirmation != nil)
                #expect(model.previewRows.first { $0.id == known.id }?.disposition == .known(.portableLedger))
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
                model.location = "Latest Shoot"
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
            #expect(receipt.files.first?.finalDestinationPath?.contains("/CustomDestination/") == true)
            model.openImportInHistory(jobID: receipt.result.jobID)
            #expect(model.selectedJobID == secondJobID)
        case .firstCopyChangesSecondPlan:
            #expect(after.entries[0].result?.importedFiles == 1)
            #expect(after.entries[1].confirmation == nil)
            #expect(model.importUIPhase == .review)
            #expect(!model.needsRescan(try #require(after.entries[1].jobID)))
            #expect(model.isScanBothPlanLocked)
            let lockedDraft = model.currentImportDraft
            model.useImportMediaSelection(.videosOnly)
            model.useFolderGrouping(lockedDraft.folderGrouping == .byDay ? .oneShootFolder : .byDay)
            model.setPreviewSessionInclusion(\.includePhotos, to: false)
            #expect(model.currentImportDraft == lockedDraft)
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

    @Test("revalidating a changed Scan Both destination keeps its date controls and folder",
          arguments: [ImportFolderGrouping.byDay, .oneShootFolder])
    func revalidatesLateDestinationChange(_ grouping: ImportFolderGrouping) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("Destination")
        let internalFolder = root.appendingPathComponent("Internal")
        let cardFolder = root.appendingPathComponent("Card")
        let suite = "SDImportAppTests.scanBothDates.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        for folder in [internalFolder, cardFolder, destination] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let firstName = grouping == .byDay ? "VID_20231114_210458_00_007.insv" : "First.jpg"
        let laterName = grouping == .byDay ? "Later.mp4" : "Later.jpg"
        let firstFile = internalFolder.appendingPathComponent(firstName)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let laterDate = firstDate.addingTimeInterval(86_400)
        for (url, date) in [
            (firstFile, firstDate), (internalFolder.appendingPathComponent(laterName), laterDate),
            (cardFolder.appendingPathComponent("Card.jpg"), firstDate)
        ] {
            try Data(url.lastPathComponent.utf8).write(to: url)
            try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        let session = try #require(ScanBothSession(deviceName: "Fixture Camera", entries: [
            .init(id: UUID(), volume: Self.volume("Internal", disk: "disk4", at: internalFolder)),
            .init(id: UUID(), volume: Self.volume("Card", disk: "disk5", at: cardFolder))
        ]))
        let model = AppModel(
            purchaseManager: PurchaseManager(distribution: .direct, startsStoreTask: false),
            defaults: defaults, startsBootstrap: false, scanBothMountLookup: { $0 },
            destinationCapacity: { path in
                VolumeCapacity(volumeID: "fixture", displayPath: path, availableBytes: 10_000, totalBytes: 10_000)
            }
        )
        model.bootstrap(at: root.appendingPathComponent("State"), startsRuntimeServices: false)
        model.importDefaults.photosPath = destination.path
        model.importDefaults.videosPath = destination.path
        model.beginScanBoth(session)
        try await waitForImport(model)
        model.reviewScanBothVolume(session.entries[1].id)
        model.importCurrentJob()
        try #require(model.scanBothSession?.entries[1].confirmation != nil)

        model.reviewScanBothVolume(session.entries[0].id)
        model.useFolderGrouping(grouping)
        try #require(model.previewSessions.count == 2 && model.canImportPlannedFiles)
        let initialDates = model.previewSessions.map(\.date)
        let firstRow = try #require(model.previewRows.first { $0.filename == firstName })
        let laterRow = try #require(model.previewRows.first { $0.filename == laterName })
        let output = URL(fileURLWithPath: try #require(firstRow.destinationPath))
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if grouping == .byDay {
            try Data("different recording".utf8).write(to: output)
        } else {
            try fm.copyItem(at: firstFile, to: output)
            try fm.setAttributes([.modificationDate: firstDate], ofItemAtPath: output.path)
        }

        model.importCurrentJob()
        #expect(model.importUIPhase == .review)
        #expect(model.scanBothSession?.entries[0].confirmation == nil)
        #expect(model.scanBothSession?.entries[1].confirmation != nil)
        #expect(model.previewSessions.map(\.date) == initialDates)
        #expect(model.previewRows.first { $0.id == laterRow.id }?.destinationPath == laterRow.destinationPath)
        if grouping == .byDay {
            #expect(model.previewRows.first { $0.id == firstRow.id }?.disposition.attention == .blocking)
            #expect(!model.canImportPlannedFiles)
            let index = try #require(model.previewSessions.firstIndex { $0.date == firstRow.date })
            model.previewSessions[index].label = "Recording"
            #expect(model.canImportPlannedFiles)
            #expect(model.previewRows.first { $0.id == firstRow.id }?.destinationPath != firstRow.destinationPath)

            let laterIndex = try #require(model.previewSessions.firstIndex { $0.date == laterRow.date })
            model.previewSessions[laterIndex].label = "Later Session"
            let firstPath = try #require(model.previewRows.first { $0.id == firstRow.id }?.destinationPath)
            let matchingOutput = URL(fileURLWithPath: firstPath)
            try fm.createDirectory(at: matchingOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: firstFile, to: matchingOutput)
            try fm.setAttributes([.modificationDate: firstDate], ofItemAtPath: matchingOutput.path)
            model.importCurrentJob()
            #expect(model.previewSessions.map(\.date) == [laterRow.date])
            #expect(model.previewSessions.first?.label == "Later Session")
            #expect(model.canCustomizeDates)

            model.previewSessions[0].label = model.location
            #expect(!model.canCustomizeDates)
            model.previewSessions[0].includeVideos = false
            #expect(model.canCustomizeDates)
            model.previewSessions[0].includeVideos = true
            model.previewSessions[0].label = "Later Session"

            let alternate = root.appendingPathComponent("Alternate")
            let relativePath = matchingOutput.resolvingSymlinksInPath().pathComponents
                .dropFirst(destination.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
            let conflictingOutput = alternate.appendingPathComponent(relativePath)
            try fm.createDirectory(at: conflictingOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("different recording at the alternate destination".utf8).write(to: conflictingOutput)
            model.setScanBothDestination(alternate)
            #expect(model.previewSessions.map(\.date) == initialDates)
            #expect(model.previewRows.first { $0.id == firstRow.id }?.disposition.attention == .blocking)
            #expect(!model.canImportPlannedFiles)
            let restoredIndex = try #require(model.previewSessions.firstIndex { $0.date == firstRow.date })
            #expect(model.previewSessions[restoredIndex].label == "Recording")
            model.previewSessions[restoredIndex].label = "Resolved"
            #expect(model.canImportPlannedFiles)
        } else {
            #expect(model.previewRows.first { $0.id == firstRow.id }?.disposition == .alreadyExists)
            #expect(model.previewRows.first { $0.id == firstRow.id }?.destinationPath == firstRow.destinationPath)
            #expect(model.previewRows.filter(\.willCopy).map(\.id) == [laterRow.id])
        }

        model.importCurrentJob()
        if grouping == .byDay {
            #expect(model.scanBothSession?.entries[1].confirmation == nil)
            model.reviewScanBothVolume(session.entries[1].id)
            model.importCurrentJob()
        }
        try #require(model.canStartScanBothImports)
        model.startScanBothImports()
        try await waitForImport(model)
        #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles)
            == [grouping == .byDay ? 2 : 1, 1])
    }

    enum ReviewEdit: CaseIterable {
        case shoot, saveTo, organize
    }

    @Test("Scan Both refreshes dates after editing the review and starts both approved imports",
          arguments: ReviewEdit.allCases)
    func refreshesDatesAfterReviewEdit(_ edit: ReviewEdit) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let internalFolder = root.appendingPathComponent("Internal")
        let cardFolder = root.appendingPathComponent("Card")
        let library = root.appendingPathComponent("Library")
        let alternate = root.appendingPathComponent("Alternate")
        let suite = "SDImportAppTests.scanBothReviewEdit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        for folder in [internalFolder, cardFolder, library, alternate] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let firstName = edit == .saveTo ? "VID_20231114_210458_00_007.insv" : "First.jpg"
        let firstFile = internalFolder.appendingPathComponent(firstName)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let laterDate = firstDate.addingTimeInterval(86_400)
        for (url, date) in [
            (firstFile, firstDate), (internalFolder.appendingPathComponent("Later.jpg"), laterDate),
            (cardFolder.appendingPathComponent("Card.jpg"), laterDate)
        ] {
            try Data(url.lastPathComponent.utf8).write(to: url)
            try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        let session = try #require(ScanBothSession(deviceName: "Fixture Camera", entries: [
            .init(id: UUID(), volume: Self.volume("Internal", disk: "disk4", at: internalFolder)),
            .init(id: UUID(), volume: Self.volume("Card", disk: "disk5", at: cardFolder))
        ]))
        let model = AppModel(
            purchaseManager: PurchaseManager(distribution: .direct, startsStoreTask: false),
            defaults: defaults, startsBootstrap: false, scanBothMountLookup: { $0 },
            destinationCapacity: { path in
                VolumeCapacity(volumeID: "fixture", displayPath: path, availableBytes: 10_000, totalBytes: 10_000)
            }
        )
        model.bootstrap(at: root.appendingPathComponent("State"), startsRuntimeServices: false)
        model.importDefaults.photosPath = library.path
        model.importDefaults.videosPath = library.path
        model.beginScanBoth(session)
        try await waitForImport(model)
        model.reviewScanBothVolume(session.entries[1].id)
        model.importCurrentJob()
        try #require(model.scanBothSession?.entries[1].confirmation != nil)

        model.reviewScanBothVolume(session.entries[0].id)
        model.useFolderGrouping(.byDay)
        if edit == .saveTo {
            model.useImportMediaSelection(.photosAndVideos)
            model.useDestinationLayout(.separateMediaFolders)
        }
        let selectPath = edit == .saveTo ? model.selectVideosPath : model.selectPhotosPath
        let originalDates = model.previewSessions.map(\.date)
        try #require(originalDates.count == 2)
        selectPath(alternate.path)
        let firstRow = try #require(model.previewRows.first { $0.filename == firstName })
        let match = URL(fileURLWithPath: try #require(firstRow.destinationPath))
        selectPath(library.path)
        try fm.createDirectory(at: match.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: firstFile, to: match)
        try fm.setAttributes([.modificationDate: firstDate], ofItemAtPath: match.path)
        selectPath(alternate.path)
        try #require(model.previewSessions.count == 1)
        try #require(model.previewRows.first { $0.id == firstRow.id }?.disposition == .alreadyExists)

        switch edit {
        case .shoot:
            model.location = "Another Shoot"
        case .saveTo:
            model.useDestinationLayout(.singleLibrary)
            let conflict = URL(fileURLWithPath: try #require(
                model.previewRows.first { $0.id == firstRow.id }?.destinationPath
            ))
            model.useDestinationLayout(.separateMediaFolders)
            try fm.createDirectory(at: conflict.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Different recording".utf8).write(to: conflict)
            model.useDestinationLayout(.singleLibrary)
            #expect(model.previewRows.first { $0.id == firstRow.id }?.disposition.attention == .blocking)
            #expect(model.canCustomizeDates)
            let index = try #require(model.previewSessions.firstIndex { $0.date == firstRow.date })
            model.previewSessions[index].label = "Recording"
        case .organize:
            model.useFolderGrouping(.oneShootFolder)
            let folders = Set(model.previewRows.filter(\.willCopy).compactMap { row in
                row.destinationPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            })
            #expect(folders.count == 1)
        }
        #expect(model.previewSessions.map(\.date) == originalDates)
        #expect(model.previewRows.filter(\.willCopy).count == 2)
        model.importCurrentJob()
        try #require(model.canStartScanBothImports)
        model.startScanBothImports()
        try await waitForImport(model)
        #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [2, 1])
    }

    enum ReviewChange: CaseIterable {
        case matchingLabel, removedReceipt, oneShootConflict, recoverVideos, changedShootDefault
    }

    @Test("Scan Both keeps approval and destination dates in sync", arguments: ReviewChange.allCases)
    func keepsApprovalInSyncWithDates(_ change: ReviewChange) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let internalFolder = root.appendingPathComponent("Internal")
        let cardFolder = root.appendingPathComponent("Card")
        let destination = root.appendingPathComponent("Destination")
        let suite = "SDImportAppTests.scanBothApprovalDates.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: root)
        }
        for folder in [internalFolder, cardFolder, destination] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let hasInsta360Recording = change == .oneShootConflict || change == .changedShootDefault
        let firstName = hasInsta360Recording ? "VID_20231114_210458_00_007.insv" : "First.jpg"
        let laterName = switch change {
        case .oneShootConflict, .changedShootDefault: "Later.dng"
        case .recoverVideos: "Later.mp4"
        default: "Later.jpg"
        }
        let firstFile = internalFolder.appendingPathComponent(firstName)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        var fixtureFiles = [
            (firstFile, firstDate),
            (internalFolder.appendingPathComponent(laterName), firstDate.addingTimeInterval(86_400)),
            (cardFolder.appendingPathComponent("Card.jpg"), firstDate)
        ]
        if change == .recoverVideos {
            fixtureFiles.append((internalFolder.appendingPathComponent("Last.mp4"), firstDate.addingTimeInterval(172_800)))
        }
        for (url, date) in fixtureFiles {
            try Data(url.lastPathComponent.utf8).write(to: url)
            try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        let ledger = PortableImportReceiptLedger(sourceRootURL: internalFolder)
        let hasReceipt = change == .removedReceipt || change == .recoverVideos || change == .changedShootDefault
        if hasReceipt {
            try ledger.append(identity: PortableFileIdentity(
                size: Int64(firstName.utf8.count), modificationDate: firstDate, relativePath: firstName
            ))
        }
        let session = try #require(ScanBothSession(deviceName: "Fixture Camera", entries: [
            .init(id: UUID(), volume: Self.volume("Internal", disk: "disk4", at: internalFolder)),
            .init(id: UUID(), volume: Self.volume("Card", disk: "disk5", at: cardFolder))
        ]))
        let model = AppModel(
            purchaseManager: PurchaseManager(distribution: .direct, startsStoreTask: false),
            defaults: defaults, startsBootstrap: false, scanBothMountLookup: { $0 },
            destinationCapacity: { path in
                VolumeCapacity(volumeID: "fixture", displayPath: path, availableBytes: 10_000, totalBytes: 10_000)
            }
        )
        model.bootstrap(at: root.appendingPathComponent("State"), startsRuntimeServices: false)
        model.portableImportReceiptsEnabled = hasReceipt
        model.importDefaults.photosPath = destination.path
        model.importDefaults.videosPath = destination.path
        model.beginScanBoth(session)
        try await waitForImport(model)
        model.reviewScanBothVolume(session.entries[1].id)
        let updatedShoot = "Updated Shoot"
        if change == .changedShootDefault {
            try #require(model.scanBothSession?.entries[0].summary?.location != updatedShoot)
            model.location = updatedShoot
            model.useFolderGrouping(.byDay)
            model.saveImportDraftAsDefaults()
            try #require(model.importDefaults.shootName == updatedShoot)
        }
        model.importCurrentJob()
        try #require(model.scanBothSession?.entries[1].confirmation != nil)
        model.reviewScanBothVolume(session.entries[0].id)

        func row(named filename: String) throws -> ImportPreviewRow {
            try #require(model.previewRows.first { $0.filename == filename })
        }
        let firstDay = try row(named: firstName).date
        let laterDay = try row(named: laterName).date
        let bothDays = [firstDay, laterDay].sorted()
        try #require(firstDay != laterDay)

        switch change {
        case .matchingLabel:
            model.useFolderGrouping(.byDay)
            let index = try #require(model.previewSessions.firstIndex { $0.date == firstDay })
            model.previewSessions[index].label = "Identical"
            let match = URL(fileURLWithPath: try #require(try row(named: firstName).destinationPath))
            try fm.createDirectory(at: match.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: firstFile, to: match)
            try fm.setAttributes([.modificationDate: firstDate], ofItemAtPath: match.path)
            model.previewSessions[index].label = "Original"
            model.previewSessions[index].label = "Identical"
            #expect(try row(named: firstName).disposition == .alreadyExists)

            model.importCurrentJob()
            let approved = try #require(model.scanBothSession?.entries[0].confirmation)
            #expect(approved.draft.sessions.map(\.date) == [laterDay])
            #expect(approved.draft.hiddenSessions[firstDay]?.label == "Identical")
            model.reviewScanBothVolume(session.entries[0].id)
            #expect(model.previewSessions.map(\.date) == [laterDay])
            model.returnToScanBothResults()
            let retained = try #require(model.scanBothSession?.entries[0].confirmation)
            #expect(retained.plans == approved.plans)
            #expect(retained.draft == approved.draft)
        case .removedReceipt:
            model.useFolderGrouping(.oneShootFolder)
            try #require(try row(named: firstName).disposition == .known(.portableLedger))
            try #require(model.previewSessions.map(\.date) == [laterDay])
            let oldLaterPath = try row(named: laterName).destinationPath
            try fm.removeItem(at: ledger.ledgerURL)
            model.importCurrentJob()
            #expect(model.importUIPhase == .review)
            #expect(model.scanBothSession?.entries[0].confirmation == nil)
            #expect(model.previewSessions.map(\.date) == bothDays)
            #expect(try row(named: firstName).willCopy)
            #expect(try row(named: laterName).destinationPath != oldLaterPath)
            model.importCurrentJob()
        case .oneShootConflict:
            model.useImportMediaSelection(.photosAndVideos)
            model.useFolderGrouping(.oneShootFolder)
            try #require(model.previewSessions.map(\.date) == bothDays)
            let fullRangePath = try #require(try row(named: firstName).destinationPath)
            model.useFolderGrouping(.byDay)
            let conflict = URL(fileURLWithPath: fullRangePath)
            try fm.createDirectory(at: conflict.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Unrelated footage".utf8).write(to: conflict)
            model.useFolderGrouping(.oneShootFolder)
            #expect(model.previewSessions.map(\.date) == bothDays)
            #expect(try row(named: firstName).disposition == .filenameConflict(destinationPath: fullRangePath))
            #expect(!model.canImportPlannedFiles)
            model.importCurrentJob()
            #expect(!model.canStartScanBothImports)
            #expect(try row(named: firstName).destinationPath == fullRangePath)

            try fm.removeItem(at: conflict)
            model.importCurrentJob()
            #expect(model.scanBothSession?.entries[0].confirmation == nil)
            model.importCurrentJob()
        case .recoverVideos:
            model.useFolderGrouping(.oneShootFolder)
            model.useImportMediaSelection(.photosOnly)
            try #require(model.previewTotals.copyFiles == 0)
            #expect(model.previewSessions.isEmpty)

            model.applyWorkflowProfile(.footageBackup)
            let videoDays = [laterDay, try row(named: "Last.mp4").date].sorted()
            #expect(model.previewSessions.map(\.date) == videoDays)
            #expect(model.previewTotals.copyFiles == 2)
            let folder = try #require(model.previewDestinations.first)
            #expect(model.previewDestinations.count == 1)
            #expect(URL(fileURLWithPath: folder.path).lastPathComponent.hasPrefix(
                ImportPlanBuilder.dateRangeTitle(for: videoDays)
            ))
            model.importCurrentJob()
        case .changedShootDefault:
            #expect(model.location == updatedShoot)
            try #require(try row(named: firstName).disposition == .known(.portableLedger))
            #expect(try row(named: firstName).destinationPath?.contains(updatedShoot) == true)
            #expect(try row(named: laterName).destinationPath?.contains(updatedShoot) == true)
            let previewedPath = try #require(try row(named: laterName).destinationPath)
            model.importCurrentJob()
            let confirmed = try #require(model.scanBothSession?.entries[0].confirmation)
            #expect(confirmed.plans.filter(\.willCopy).compactMap(\.destinationPath) == [previewedPath])
        }

        try #require(model.canStartScanBothImports)
        let approvedPaths = model.scanBothSession?.entries.flatMap { entry in
            entry.confirmation?.plans.filter(\.willCopy).compactMap(\.destinationPath) ?? []
        } ?? []
        model.startScanBothImports()
        try await waitForImport(model)
        let expectedCount = change == .matchingLabel || change == .changedShootDefault ? 1 : 2
        #expect(model.scanBothSession?.entries.compactMap(\.result).map(\.importedFiles) == [expectedCount, 1])
        if change == .changedShootDefault {
            try #require(approvedPaths.count == 2)
            for path in approvedPaths {
                let url = URL(fileURLWithPath: path)
                #expect(try Data(contentsOf: url) == Data(url.lastPathComponent.utf8))
            }
        }
    }

    private func waitForImport(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isWorking, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isWorking)
    }
}
