import Foundation

public struct SourceEjectionPolicy: Sendable {
    public init() {}

    public func canEject(
        job: ImportJob,
        result: ImportResult,
        volume: MountedVolume
    ) -> Bool {
        guard
            job.id == result.jobID,
            job.status == .imported,
            result.failedFiles == 0
        else {
            return false
        }

        return canEject(
            sourcePath: job.mountPath,
            expectedVolumeUUID: job.volumeUUID,
            volume: volume
        )
    }

    public func canEjectAfterScan(
        summary: ScanSummary,
        plannedCopyFiles: Int,
        volume: MountedVolume
    ) -> Bool {
        guard !summary.jobID.isEmpty, plannedCopyFiles == 0 else {
            return false
        }

        return canEject(
            sourcePath: summary.mountPath,
            expectedVolumeUUID: summary.volumeUUID,
            volume: volume
        )
    }

    private func canEject(
        sourcePath: String,
        expectedVolumeUUID: String?,
        volume: MountedVolume
    ) -> Bool {
        guard
            let expectedVolumeUUID,
            !expectedVolumeUUID.isEmpty,
            volume.volumeUUID == expectedVolumeUUID,
            volume.isRemovable,
            !volume.isDiskImage
        else {
            return false
        }

        let sourcePath = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL.path
        let volumePath = volume.mountURL.standardizedFileURL.path
        return volumePath.hasPrefix("/Volumes/")
            && (sourcePath == volumePath || sourcePath.hasPrefix(volumePath + "/"))
    }
}
