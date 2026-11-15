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

    public func canEjectCurrentVolume(_ current: MountedVolume, matching expected: MountedVolume) -> Bool {
        guard current.isRemovable, !current.isDiskImage,
              current.mountURL.standardizedFileURL.path == expected.mountURL.standardizedFileURL.path else {
            return false
        }
        if let uuid = expected.volumeUUID, !uuid.isEmpty, current.volumeUUID != uuid { return false }
        if let device = expected.deviceGroupIdentifier, current.deviceGroupIdentifier != device { return false }
        if let disk = expected.wholeDiskIdentifier, current.wholeDiskIdentifier != disk { return false }
        return true
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
