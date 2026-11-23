import Foundation

public struct MountedDevicePrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let deviceGroup: MountedDeviceGroup

    public func contains(_ volume: MountedVolume) -> Bool {
        deviceGroup.volumes.contains {
            $0.id == volume.id && $0.mountPath == volume.mountPath
        }
    }
}

public enum MountedDevicePromptDelivery: Equatable, Sendable {
    case present
    case alreadyPresented
    case deferred
    case stale
}

public struct MountedDevicePromptCoordinator: Sendable {
    private struct Presentation: Sendable {
        let group: MountedDeviceGroup
        let offeredVolumes: [MountedVolume]
        let acceptsLateSiblings: Bool
    }

    private let grouper = MountedDeviceGrouper()
    private var presentations: [Presentation] = []
    public private(set) var pendingPrompt: MountedDevicePrompt?

    public init() {}

    public mutating func updateMountedVolumes(_ volumes: [MountedVolume]) {
        let groups = grouper.groups(from: volumes)
        if let pendingPrompt {
            let continuations = groups.filter { $0.continues(pendingPrompt.deviceGroup) }
            let group = continuations.first { $0.id == pendingPrompt.deviceGroup.id } ?? continuations.first
            self.pendingPrompt = group.map {
                MountedDevicePrompt(id: pendingPrompt.id, deviceGroup: $0)
            }
        }

        let previousPresentations = presentations
        presentations = groups.compactMap { group in
            let previous = previousPresentations.filter { group.continues($0.group) }
            let previouslyOffered = previous.flatMap(\.offeredVolumes)
            let stillOffered = group.volumes.filter { volume in
                previouslyOffered.contains { volume.isSameMount(as: $0) }
            }
            let isOpen = pendingPrompt?.deviceGroup.id == group.id
            guard isOpen || !stillOffered.isEmpty else { return nil }

            // Once a previously offered volume has gone away, an unfamiliar
            // mount may be replacement media. Keep the decision only for the
            // surviving volumes until the user sees another prompt.
            let acceptsLateSiblings = previous.allSatisfy(\.acceptsLateSiblings)
                && previouslyOffered.allSatisfy { old in volumes.contains { $0.isSameMount(as: old) } }
            return Presentation(
                group: group,
                offeredVolumes: isOpen || acceptsLateSiblings ? group.volumes : stillOffered,
                acceptsLateSiblings: acceptsLateSiblings
            )
        }
    }

    public mutating func receive(
        _ volume: MountedVolume,
        among mountedVolumes: [MountedVolume],
        canPresent: Bool
    ) -> MountedDevicePromptDelivery {
        let liveVolume = mountedVolumes.first { $0.mountPath == volume.mountPath }
        if let liveVolume, !MountHandoffVolumeIdentity.matchesCurrentVolume(
            expectedUUID: volume.volumeUUID, currentUUID: liveVolume.volumeUUID
        ) {
            return .stale
        }
        let currentVolume = liveVolume ?? volume
        let volumes = liveVolume == nil ? mountedVolumes + [volume] : mountedVolumes
        updateMountedVolumes(volumes)
        let group = grouper.group(containing: currentVolume, among: volumes)
        if presentations.contains(where: { presentation in
            presentation.group.id == group.id
                && presentation.offeredVolumes.contains { currentVolume.isSameMount(as: $0) }
        }) {
            return .alreadyPresented
        }
        guard canPresent, pendingPrompt == nil else {
            return .deferred
        }
        presentations.removeAll { $0.group.id == group.id }
        presentations.append(Presentation(group: group, offeredVolumes: group.volumes, acceptsLateSiblings: true))
        pendingPrompt = MountedDevicePrompt(id: UUID(), deviceGroup: group)
        return .present
    }

    @discardableResult
    public mutating func dismiss(_ promptID: UUID) -> Bool {
        guard pendingPrompt?.id == promptID else {
            return false
        }
        pendingPrompt = nil
        return true
    }
}

private extension MountedDeviceGroup {
    var usbDeviceID: String? {
        volumes.first?.deviceGroupIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    }

    func continues(_ previous: MountedDeviceGroup) -> Bool {
        if let currentUSB = usbDeviceID, let previousUSB = previous.usbDeviceID, currentUSB != previousUSB {
            return false
        }
        return volumes.contains { current in
            previous.volumes.contains { current.isSameMount(as: $0) }
        }
    }
}

private extension MountedVolume {
    func isSameMount(as previous: MountedVolume) -> Bool {
        guard mountPath == previous.mountPath else { return false }
        if let currentUSB = deviceGroupIdentifier, let previousUSB = previous.deviceGroupIdentifier,
           currentUSB != previousUSB {
            return false
        }
        if let disk = wholeDiskIdentifier, let previousDisk = previous.wholeDiskIdentifier, disk != previousDisk {
            return false
        }
        if let uuid = volumeUUID, let previousUUID = previous.volumeUUID {
            return MountHandoffVolumeIdentity.matchesCurrentVolume(expectedUUID: previousUUID, currentUUID: uuid)
        }
        if wholeDiskIdentifier != nil && previous.wholeDiskIdentifier != nil {
            return true
        }
        return id == previous.id
    }
}
