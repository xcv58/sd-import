import DiskArbitration
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
        let diskTraits = Self.diskTraits(for: mountURL)
        let isRemovable = (values?.volumeIsRemovable ?? false)
            || (values?.volumeIsEjectable ?? false)
            || diskTraits.isRemovable
            || diskTraits.isEjectable
        let totalCapacity = values?.volumeTotalCapacity.map(Int64.init)
        let availableCapacity = Self.sourceAvailableCapacity(
            available: values?.volumeAvailableCapacity.map(Int64.init),
            importantUsage: values?.volumeAvailableCapacityForImportantUsage
        )

        return MountedVolume(
            id: values?.volumeUUIDString ?? mountURL.standardizedFileURL.path,
            name: name,
            mountURL: mountURL,
            volumeUUID: values?.volumeUUIDString,
            isRemovable: isRemovable,
            isInternal: values?.volumeIsInternal ?? false,
            isDiskImage: diskTraits.isDiskImage || Self.hasDiskImageNameOrPath(name: name, path: mountURL.path),
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
        volume.isDiskImage || Self.hasDiskImageNameOrPath(name: volume.name, path: volume.mountURL.path)
    }

    private static func hasDiskImageNameOrPath(name: String, path: String) -> Bool {
        let name = name.lowercased()
        let path = path.lowercased()
        return name.hasSuffix(".dmg")
            || name.hasSuffix(".sparsebundle")
            || path.hasSuffix(".dmg")
            || path.hasSuffix(".sparsebundle")
    }

    private static func diskTraits(for volumeURL: URL) -> DiskTraits {
        guard
            let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
            let description = DADiskCopyDescription(disk) as? [String: Any]
        else {
            return DiskTraits()
        }

        return DiskTraits(
            deviceModel: description[kDADiskDescriptionDeviceModelKey as String] as? String,
            mediaName: description[kDADiskDescriptionMediaNameKey as String] as? String,
            isRemovable: boolValue(description[kDADiskDescriptionMediaRemovableKey as String]),
            isEjectable: boolValue(description[kDADiskDescriptionMediaEjectableKey as String])
        )
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private struct DiskTraits: Sendable {
        let deviceModel: String?
        let mediaName: String?
        let isRemovable: Bool
        let isEjectable: Bool

        init(
            deviceModel: String? = nil,
            mediaName: String? = nil,
            isRemovable: Bool = false,
            isEjectable: Bool = false
        ) {
            self.deviceModel = deviceModel
            self.mediaName = mediaName
            self.isRemovable = isRemovable
            self.isEjectable = isEjectable
        }

        var isDiskImage: Bool {
            [deviceModel, mediaName]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains("disk image") }
        }
    }

    private func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func sourceAvailableCapacity(available: Int64?, importantUsage: Int64?) -> Int64? {
        if let available, available > 0 {
            return available
        }
        if let importantUsage, importantUsage > 0 {
            return importantUsage
        }
        return available ?? importantUsage
    }
}
