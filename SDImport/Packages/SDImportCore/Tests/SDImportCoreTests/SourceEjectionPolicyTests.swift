import Foundation
import Testing

@testable import SDImportCore

@Suite("Source ejection policy")
struct SourceEjectionPolicyTests {
    private let policy = SourceEjectionPolicy()

    @Test("allows only the successfully imported matching removable volume")
    func allowsMatchingSuccessfulVolume() {
        let job = makeJob()
        let result = makeResult()
        let volume = makeVolume()

        #expect(policy.canEject(job: job, result: result, volume: volume))
        #expect(policy.canEject(job: job, result: result, volume: makeVolume(isInternal: true)))
    }

    @Test("rejects errors, identity mismatches, and unsafe volumes")
    func rejectsUnsafeTargets() {
        let job = makeJob()
        let result = makeResult()

        #expect(!policy.canEject(job: job, result: makeResult(failedFiles: 1), volume: makeVolume()))
        #expect(!policy.canEject(job: makeJob(status: .importedWithErrors), result: result, volume: makeVolume()))
        #expect(!policy.canEject(job: makeJob(volumeUUID: nil), result: result, volume: makeVolume()))
        #expect(!policy.canEject(job: job, result: result, volume: makeVolume(volumeUUID: "other-card")))
        #expect(!policy.canEject(job: job, result: result, volume: makeVolume(isRemovable: false)))
        #expect(!policy.canEject(job: job, result: result, volume: makeVolume(isDiskImage: true)))
        #expect(!policy.canEject(job: job, result: result, volume: makeVolume(mountPath: "/Volumes/OTHER")))
    }

    @Test("an eject attempt cannot target a replacement volume at the same path")
    func rejectsReplacementVolume() {
        let expected = makeVolume()
        #expect(policy.canEjectCurrentVolume(makeVolume(isInternal: true), matching: expected))
        #expect(!policy.canEjectCurrentVolume(makeVolume(volumeUUID: "new-card"), matching: expected))
        #expect(!policy.canEjectCurrentVolume(makeVolume(isDiskImage: true), matching: expected))
        #expect(!policy.canEjectCurrentVolume(makeVolume(volumeUUID: nil), matching: makeVolume(volumeUUID: nil)))
    }

    @Test("ejection checks nested symlinks in approved copy destinations")
    func resolvesApprovedDestinationFolders() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mac = fixture.appendingPathComponent("Mac", isDirectory: true)
        let camera = fixture.appendingPathComponent("Camera", isDirectory: true)
        try manager.createDirectory(at: mac, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        try manager.createDirectory(at: camera, withIntermediateDirectories: false)
        let symlink = mac.appendingPathComponent("Photos", isDirectory: true)
        try manager.createSymbolicLink(at: symlink, withDestinationURL: camera)
        let newFolder = symlink.appendingPathComponent("New Trip", isDirectory: true)
        let file = newFolder.appendingPathComponent("photo.jpg")
        let plan = ImportFilePlan(update: nil, willCopy: true, disposition: .copy, destinationPath: file.path)

        let resolved = try #require(policy.resolvedExistingDirectory(newFolder.path))
        #expect(try manager.attributesOfItem(atPath: resolved.path)[.systemFileNumber] as? NSNumber
            == manager.attributesOfItem(atPath: camera.path)[.systemFileNumber] as? NSNumber)
        let volume = try #require(try camera.resourceValues(forKeys: [.volumeURLKey]).volume)
        let paths = try #require(policy.resolvedDestinationVolumePaths(plans: [plan]))
        #expect(paths == [volume.standardizedFileURL.path])
    }

    @Test("broken and cyclic destination symlinks prevent eject", arguments: [true, false])
    func rejectsUnresolvableDestinationFolders(cycle: Bool) throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixture) }
        let link = fixture.appendingPathComponent("Photos", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: cycle ? link : fixture.appendingPathComponent("Missing"))
        let file = link.appendingPathComponent("New Trip/photo.jpg")
        let plan = ImportFilePlan(update: nil, willCopy: true, disposition: .copy, destinationPath: file.path)

        #expect(policy.resolvedDestinationVolumePaths(plans: [plan]) == nil)
    }

    private func makeJob(
        status: ImportJobStatus = .imported,
        volumeUUID: String? = "card-uuid"
    ) -> ImportJob {
        ImportJob(
            id: "job-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            mountPath: "/Volumes/CARD/DCIM",
            volumeName: "CARD",
            volumeUUID: volumeUUID,
            location: "Gardens",
            photosRoot: "/tmp/Photos",
            videosRoot: "/tmp/Videos",
            status: status
        )
    }

    private func makeResult(failedFiles: Int = 0) -> ImportResult {
        ImportResult(
            jobID: "job-1",
            importedFiles: failedFiles == 0 ? 3 : 2,
            skippedFiles: 0,
            failedFiles: failedFiles,
            progressPath: nil
        )
    }

    private func makeVolume(
        mountPath: String = "/Volumes/CARD",
        volumeUUID: String? = "card-uuid",
        isRemovable: Bool = true,
        isInternal: Bool = false,
        isDiskImage: Bool = false
    ) -> MountedVolume {
        MountedVolume(
            id: volumeUUID ?? mountPath,
            name: "CARD",
            mountURL: URL(fileURLWithPath: mountPath, isDirectory: true),
            volumeUUID: volumeUUID,
            isRemovable: isRemovable,
            isInternal: isInternal,
            isDiskImage: isDiskImage
        )
    }
}
