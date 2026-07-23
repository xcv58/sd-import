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
            result.failedFiles == 0,
            let jobVolumeUUID = job.volumeUUID,
            !jobVolumeUUID.isEmpty,
            volume.volumeUUID == jobVolumeUUID,
            volume.isRemovable,
            !volume.isDiskImage
        else {
            return false
        }

        let sourcePath = URL(fileURLWithPath: job.mountPath, isDirectory: true).standardizedFileURL.path
        let volumePath = volume.mountURL.standardizedFileURL.path
        return volumePath.hasPrefix("/Volumes/")
            && (sourcePath == volumePath || sourcePath.hasPrefix(volumePath + "/"))
    }
}
