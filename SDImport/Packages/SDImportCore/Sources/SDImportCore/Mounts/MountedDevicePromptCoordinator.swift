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
    private let grouper = MountedDeviceGrouper()
    // IOKit registry IDs are unique within a boot. A reconnected USB device
    // has a new ID, so a gap with no mounted volumes need not erase this one.
    private var presentedUSBDevices: [String: MountedDeviceGroup] = [:]
    private var mountedPresentedGroups: [MountedDeviceGroup] = []
    public private(set) var pendingPrompt: MountedDevicePrompt?

    public init() {}

    public mutating func updateMountedVolumes(_ volumes: [MountedVolume]) {
        let groups = grouper.groups(from: volumes)
        mountedPresentedGroups = groups.filter(wasPresented)
        for group in mountedPresentedGroups {
            rememberUSBDevice(group)
        }

        if let pendingPrompt {
            let continuations = groups.filter { $0.continues(pendingPrompt.deviceGroup) }
            let group = continuations.first { $0.id == pendingPrompt.deviceGroup.id } ?? continuations.first
            self.pendingPrompt = group.map {
                MountedDevicePrompt(id: pendingPrompt.id, deviceGroup: $0)
            }
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
        let volumes = liveVolume == nil ? mountedVolumes + [volume] : mountedVolumes
        let group = grouper.group(containing: liveVolume ?? volume, among: volumes)
        if wasPresented(group) {
            rememberUSBDevice(group)
            return .alreadyPresented
        }
        guard canPresent, pendingPrompt == nil else {
            return .deferred
        }
        rememberUSBDevice(group)
        mountedPresentedGroups.append(group)
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

    private func wasPresented(_ group: MountedDeviceGroup) -> Bool {
        if mountedPresentedGroups.contains(where: { group.continues($0) }) {
            return true
        }
        guard let id = group.usbDeviceID, let previous = presentedUSBDevices[id] else {
            return false
        }
        // A reader can remain plugged in when its only card is swapped.
        // After an unmount, treat reuse of that single source as a fresh mount.
        return previous.isMultiVolume || !group.reusesStorage(of: previous)
    }

    private mutating func rememberUSBDevice(_ group: MountedDeviceGroup) {
        guard let id = group.usbDeviceID else { return }
        if presentedUSBDevices[id]?.isMultiVolume != true || group.isMultiVolume {
            presentedUSBDevices[id] = group
        }
    }
}

private extension MountedDeviceGroup {
    var usbDeviceID: String? {
        volumes.first?.deviceGroupIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    }

    func reusesStorage(of previous: MountedDeviceGroup) -> Bool {
        volumes.contains { current in
            previous.volumes.contains { old in
                current.mountPath == old.mountPath
                    || current.wholeDiskIdentifier.map { $0 == old.wholeDiskIdentifier } == true
            }
        }
    }

    func continues(_ previous: MountedDeviceGroup) -> Bool {
        if let currentUSB = usbDeviceID, let previousUSB = previous.usbDeviceID {
            return currentUSB == previousUSB
        }

        // Disk numbers can be recycled. Carry a fallback group forward only
        // when at least one of its volumes is still mounted at the same path.
        return volumes.contains { current in
            previous.volumes.contains { old in
                guard current.mountPath == old.mountPath else { return false }
                if let disk = current.wholeDiskIdentifier, let oldDisk = old.wholeDiskIdentifier, disk != oldDisk {
                    return false
                }
                if let oldUUID = old.volumeUUID, let currentUUID = current.volumeUUID {
                    return MountHandoffVolumeIdentity.matchesCurrentVolume(
                        expectedUUID: oldUUID, currentUUID: currentUUID
                    )
                }
                if current.wholeDiskIdentifier != nil && old.wholeDiskIdentifier != nil {
                    return true
                }
                return current.id == old.id
            }
        }
    }
}
