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
            .volumeIsEjectableKey
        ])
        let name = values?.volumeName ?? mountURL.lastPathComponent
        let isRemovable = (values?.volumeIsRemovable ?? false)
            || (values?.volumeIsEjectable ?? false)
            || mountURL.path.hasPrefix("/Volumes/")

        return MountedVolume(
            id: values?.volumeUUIDString ?? mountURL.standardizedFileURL.path,
            name: name,
            mountURL: mountURL,
            volumeUUID: values?.volumeUUIDString,
            isRemovable: isRemovable
        )
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
