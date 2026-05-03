import Foundation

public struct VolumeDetector: Sendable {
    private let ignoredNameFragments: [String]

    public init(ignoredNameFragments: [String] = ["time machine", "backup"]) {
        self.ignoredNameFragments = ignoredNameFragments.map { $0.lowercased() }
    }

    public func mountedVolume(from mountURL: URL) -> MountedVolume {
        let values = try? mountURL.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let name = values?.volumeName ?? mountURL.lastPathComponent
        let isRemovable = (values?.volumeIsRemovable ?? false)
            || (values?.volumeIsEjectable ?? false)
            || mountURL.path.hasPrefix("/Volumes/")
        let totalCapacity = values?.volumeTotalCapacity.map(Int64.init)
        let availableCapacity = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)

        return MountedVolume(
            id: values?.volumeUUIDString ?? mountURL.standardizedFileURL.path,
            name: name,
            mountURL: mountURL,
            volumeUUID: values?.volumeUUIDString,
            isRemovable: isRemovable,
            totalCapacityBytes: totalCapacity,
            availableCapacityBytes: availableCapacity
        )
    }

    public func mountedVolumes(
        under rootURL: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default
    ) -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return likelyImportVolumes(from: urls.map(mountedVolume(from:)))
    }

    public func likelyImportVolumes(from volumes: [MountedVolume]) -> [MountedVolume] {
        volumes
            .filter(isLikelyImportVolume)
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    public func isLikelyImportVolume(_ volume: MountedVolume) -> Bool {
        let lowercasedName = volume.name.lowercased()
        guard !ignoredNameFragments.contains(where: lowercasedName.contains) else {
            return false
        }
        guard !isDiskImage(volume) else {
            return false
        }
        return volume.isRemovable || volume.mountURL.path.hasPrefix("/Volumes/")
    }

    private func isDiskImage(_ volume: MountedVolume) -> Bool {
        let name = volume.name.lowercased()
        let path = volume.mountURL.path.lowercased()
        return name.hasSuffix(".dmg")
            || name.hasSuffix(".sparsebundle")
            || path.hasSuffix(".dmg")
            || path.hasSuffix(".sparsebundle")
    }
}
