import Foundation

public struct VolumeDetector: Sendable {
    private let ignoredNameFragments: [String]
    private let classifier = MediaClassifier()

    public init(ignoredNameFragments: [String] = ["time machine", "backup", "recovery", "preboot", "macintosh hd"]) {
        self.ignoredNameFragments = ignoredNameFragments.map { $0.lowercased() }
    }

    public func mountedVolume(from mountURL: URL) -> MountedVolume {
        let values = try? mountURL.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let name = values?.volumeName ?? mountURL.lastPathComponent
        let isRemovable = (values?.volumeIsRemovable ?? false)
            || (values?.volumeIsEjectable ?? false)
        let totalCapacity = values?.volumeTotalCapacity.map(Int64.init)
        let availableCapacity = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)

        return MountedVolume(
            id: values?.volumeUUIDString ?? mountURL.standardizedFileURL.path,
            name: name,
            mountURL: mountURL,
            volumeUUID: values?.volumeUUIDString,
            isRemovable: isRemovable,
            isInternal: values?.volumeIsInternal ?? false,
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
            .volumeIsInternalKey,
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
        return volume.isRemovable && volume.mountURL.path.hasPrefix("/Volumes/")
    }

    public func containsImportableMedia(
        at rootURL: URL,
        fileManager: FileManager = .default,
        maximumCandidates: Int = 20_000,
        maximumDuration: TimeInterval = 2.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(maximumDuration)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var inspectedFiles = 0
        for case let url as URL in enumerator {
            if Task.isCancelled || Date() > deadline {
                return false
            }
            if url.lastPathComponent.hasPrefix(".") {
                if isDirectory(url, fileManager: fileManager) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isDirectory(url, fileManager: fileManager) {
                continue
            }

            inspectedFiles += 1
            if classifier.classify(url: url) != .unsupported {
                return true
            }
            if inspectedFiles >= maximumCandidates {
                return false
            }
        }

        return false
    }

    private func isDiskImage(_ volume: MountedVolume) -> Bool {
        let name = volume.name.lowercased()
        let path = volume.mountURL.path.lowercased()
        return name.hasSuffix(".dmg")
            || name.hasSuffix(".sparsebundle")
            || path.hasSuffix(".dmg")
            || path.hasSuffix(".sparsebundle")
    }

    private func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
