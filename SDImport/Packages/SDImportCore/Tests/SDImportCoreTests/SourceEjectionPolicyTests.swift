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
        volumeUUID: String = "card-uuid",
        isRemovable: Bool = true,
        isInternal: Bool = false,
        isDiskImage: Bool = false
    ) -> MountedVolume {
        MountedVolume(
            id: volumeUUID,
            name: "CARD",
            mountURL: URL(fileURLWithPath: mountPath, isDirectory: true),
            volumeUUID: volumeUUID,
            isRemovable: isRemovable,
            isInternal: isInternal,
            isDiskImage: isDiskImage
        )
    }
}
