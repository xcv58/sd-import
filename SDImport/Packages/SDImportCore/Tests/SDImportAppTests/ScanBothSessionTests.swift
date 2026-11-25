import Foundation
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
        if case .complete(let summary, let filenames, _) = completed {
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

    @Test("both scan jobs can be copied separately from one session")
    func scansRealFilesAndKeepsCopySeparate() async throws {
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
        let internalNames = (1...6).map { "Internal-\($0).jpg" }
        let cardNames = ["Card-1.jpg", "Card-2.jpg"]
        for (volume, names) in [(internalStorage, internalNames), (card, cardNames)] {
            let source = try #require(sourceFolders[volume.name])
            let dcim = source.appendingPathComponent("DCIM", isDirectory: true)
            try fileManager.createDirectory(at: dcim, withIntermediateDirectories: true)
            for name in names {
                try Data(name.utf8).write(to: dcim.appendingPathComponent(name))
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
            guard case .complete(let summary, let preview, _) = entry.state else {
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
            #expect(AppModel.retryFilesMatchScan(files))
        }

        let firstJob = try #require(jobs.first { $0.volumeUUID == internalStorage.volumeUUID })
        let siblingJob = try #require(jobs.first { $0.volumeUUID == card.volumeUUID })
        let engine = ImportEngine(jobRepository: repository, dedupeRepository: dedupe)

        review.recordImport(ImportResult(
            jobID: firstJob.id, importedFiles: 0, skippedFiles: 0, failedFiles: 1, progressPath: nil
        ))
        #expect(review.entry(for: firstJob.id)?.awaitsImport == true)
        #expect(!review.allowsAutomaticEjection)

        review.reviewingJobID = firstJob.id
        let result = try engine.importFiles(jobID: firstJob.id)
        review.recordImport(result)
        #expect(result.importedFiles == internalNames.count)
        #expect(try repository.listImportHistoryJobs().map(\.id) == [firstJob.id])
        #expect(try repository.fetchJob(id: siblingJob.id)?.status == .scanned)
        #expect(try repository.fetchJobFiles(jobID: siblingJob.id).allSatisfy { $0.copyStatus == .pending })
        #expect(!review.allowsAutomaticEjection)

        review.reviewingJobID = nil
        #expect(review.entry(for: firstJob.id)?.awaitsImport == false)
        #expect(review.entry(for: siblingJob.id)?.awaitsImport == true)
        review.reviewingJobID = siblingJob.id
        let siblingResult = try engine.importFiles(jobID: siblingJob.id)
        review.recordImport(siblingResult)
        #expect(siblingResult.importedFiles == cardNames.count)
        #expect(Set(try repository.listImportHistoryJobs().map(\.id)) == Set([firstJob.id, siblingJob.id]))
        #expect(review.allowsAutomaticEjection)
        review.removedMountPaths.insert(card.mountPath)
        #expect(!review.allowsAutomaticEjection)
    }

    @Test("ejection checks a destination from either volume in the scan session")
    func ejectionChecksBothImportDestinations() throws {
        var coordinator = MountedDevicePromptCoordinator()
        let both = [internalStorage, card]
        _ = coordinator.receive(internalStorage, among: both, canPresent: true)
        let prompt = try #require(coordinator.pendingPrompt)
        var session = try #require(ScanBothSession(prompt: prompt))
        let macDestination = URL(fileURLWithPath: "/Users/Shared/Import Test", isDirectory: true)
        let cameraDestination = card.mountURL.appendingPathComponent("Offload", isDirectory: true)
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
        session.recordImportDestinations(
            DestinationRoots(photosURL: cameraDestination, videosURL: macDestination),
            for: internalStorage.name
        )
        let finalJob = ImportJob(
            id: card.name, createdAt: Date(), mountPath: card.mountPath, location: "Camera",
            photosRoot: macDestination.path, videosRoot: macDestination.path, status: .imported
        )
        let paths = session.ejectionDestinationPaths(for: finalJob)
        #expect(paths == Set([macDestination.path, cameraDestination.path]))
        #expect(paths.contains { AppModel.destination($0, sharesDeviceWith: both) })
    }

    @Test("retry rejects pending source files that changed after the scan")
    func verifiesPendingRetryFileMetadata() throws {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("old".utf8).write(to: url)
        defer { try? fileManager.removeItem(at: url) }
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try fileManager.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
        let file = JobFileRecord(
            jobID: "job", sourcePath: url.path, relativePath: url.lastPathComponent,
            filename: url.lastPathComponent, ext: "jpg", size: 3, modificationDateString: "",
            modificationTimeEpochSeconds: Int64(originalDate.timeIntervalSince1970), mediaKind: .photo,
            fingerprint: nil, captureDate: nil, decision: .new, destinationDirectory: nil,
            plannedDestinationPath: nil, copyStatus: .failed
        )
        #expect(AppModel.retryFilesMatchScan([file]))

        try Data("new".utf8).write(to: url)
        try fileManager.setAttributes(
            [.modificationDate: originalDate.addingTimeInterval(20)], ofItemAtPath: url.path
        )
        #expect(!AppModel.retryFilesMatchScan([file]))
    }

    private static func volume(_ name: String, disk: String, device: String = "camera") -> MountedVolume {
        MountedVolume(
            id: name, name: name, mountURL: URL(fileURLWithPath: "/Volumes/\(name)"),
            volumeUUID: name, isRemovable: true, wholeDiskIdentifier: disk, deviceGroupIdentifier: device
        )
    }
}
