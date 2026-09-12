import Foundation

public struct MountedDeviceGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let volumes: [MountedVolume]

    public init(id: String, displayName: String, volumes: [MountedVolume]) {
        self.id = id
        self.displayName = displayName
        self.volumes = volumes
    }

    public var isMultiVolume: Bool {
        volumes.count > 1
    }
}

public struct MountedDeviceGrouper: Sendable {
    public init() {}

    public func groups(from volumes: [MountedVolume]) -> [MountedDeviceGroup] {
        Dictionary(grouping: volumes, by: groupIdentifier(for:))
            .map { identifier, groupedVolumes in
                let sortedVolumes = groupedVolumes.sorted(by: volumeSort)
                return MountedDeviceGroup(
                    id: identifier,
                    displayName: displayName(for: sortedVolumes),
                    volumes: sortedVolumes
                )
            }
            .sorted {
                let nameComparison = $0.displayName.localizedStandardCompare($1.displayName)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    public func group(
        containing sourceVolume: MountedVolume,
        among mountedVolumes: [MountedVolume]
    ) -> MountedDeviceGroup {
        let identifier = groupIdentifier(for: sourceVolume)
        let relatedVolumes = mountedVolumes
            .filter { groupIdentifier(for: $0) == identifier }
            .filter(isSafeEjectionCandidate)
            .sorted(by: volumeSort)
        let volumes = relatedVolumes.contains(where: { $0.id == sourceVolume.id })
            ? relatedVolumes
            : (relatedVolumes + [sourceVolume]).sorted(by: volumeSort)

        return MountedDeviceGroup(
            id: identifier,
            displayName: displayName(for: volumes),
            volumes: volumes
        )
    }

    public func ejectionVolumes(
        for sourceVolume: MountedVolume,
        among mountedVolumes: [MountedVolume]
    ) -> [MountedVolume] {
        let group = group(containing: sourceVolume, among: mountedVolumes)
        var representativeByWholeDisk: [String: MountedVolume] = [:]

        for volume in group.volumes {
            let identifier = wholeDiskIdentifier(for: volume)
            if representativeByWholeDisk[identifier] == nil || volume.id == sourceVolume.id {
                representativeByWholeDisk[identifier] = volume
            }
        }

        let sourceWholeDisk = wholeDiskIdentifier(for: sourceVolume)
        let siblings = representativeByWholeDisk
            .filter { $0.key != sourceWholeDisk }
            .map(\.value)
            .sorted(by: volumeSort)
        if let sourceRepresentative = representativeByWholeDisk[sourceWholeDisk] {
            return siblings + [sourceRepresentative]
        }
        return siblings
    }

    private func groupIdentifier(for volume: MountedVolume) -> String {
        if let identifier = volume.deviceGroupIdentifier, !identifier.isEmpty {
            return "device:\(identifier)"
        }
        if let identifier = volume.wholeDiskIdentifier, !identifier.isEmpty {
            return "disk:\(identifier)"
        }
        return "volume:\(volume.id)"
    }

    private func wholeDiskIdentifier(for volume: MountedVolume) -> String {
        if let identifier = volume.wholeDiskIdentifier, !identifier.isEmpty {
            return identifier
        }
        return volume.id
    }

    private func displayName(for volumes: [MountedVolume]) -> String {
        if let deviceName = volumes.lazy.compactMap(\.physicalDeviceDisplayName).first {
            return deviceName
        }
        if volumes.count == 1, let volume = volumes.first {
            return volume.name
        }
        return L10n.tr("External Device")
    }

    private func isSafeEjectionCandidate(_ volume: MountedVolume) -> Bool {
        volume.isRemovable
            && !volume.isDiskImage
            && volume.mountURL.standardizedFileURL.path.hasPrefix("/Volumes/")
    }

    private func volumeSort(_ lhs: MountedVolume, _ rhs: MountedVolume) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
