import Darwin
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
        guard let uuid = expected.volumeUUID, !uuid.isEmpty, current.volumeUUID == uuid else { return false }
        if let device = expected.deviceGroupIdentifier, current.deviceGroupIdentifier != device { return false }
        if let disk = expected.wholeDiskIdentifier, current.wholeDiskIdentifier != disk { return false }
        return true
    }

    public func resolvedDestinationVolumePaths(plans: [ImportFilePlan]) -> Set<String>? {
        var directories = Set<String>()
        for plan in plans where plan.willCopy || plan.disposition == .copied {
            guard let path = plan.destinationPath else { return nil }
            directories.insert((path as NSString).deletingLastPathComponent)
        }
        var paths = Set<String>()
        for directory in directories {
            if Task.isCancelled { return nil }
            guard let resolved = resolvedExistingDirectory(directory),
                  let volume = try? resolved.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
            paths.insert(volume.standardizedFileURL.path)
        }
        return paths
    }

    func resolvedExistingDirectory(_ directory: String) -> URL? {
        var candidate = directory
        var metadata = stat()
        // The copy can create some directories. Walk only through missing components.
        // lstat identifies an existing symlink even when its target is missing.
        while lstat(candidate, &metadata) != 0 {
            guard errno == ENOENT, candidate.hasPrefix("/"), candidate != "/" else { return nil }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(candidate, nil) else { return nil }
        defer { free(resolved) }
        guard stat(resolved, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
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
