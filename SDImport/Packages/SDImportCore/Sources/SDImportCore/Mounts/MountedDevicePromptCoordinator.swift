import Foundation

public struct MountedDevicePrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let deviceGroup: MountedDeviceGroup

    public func contains(_ volume: MountedVolume) -> Bool {
        deviceGroup.volumes.contains {
            $0.id == volume.id && $0.mountURL.standardizedFileURL.path == volume.mountURL.standardizedFileURL.path
        }
    }
}

public enum MountedDevicePromptDelivery: Equatable, Sendable {
    case present
    case alreadyPresented
    case deferred
}

public struct MountedDevicePromptCoordinator: Sendable {
    private let grouper = MountedDeviceGrouper()
    private var presentedDeviceIDs: Set<String> = []
    public private(set) var pendingPrompt: MountedDevicePrompt?

    public init() {}

    public mutating func updateMountedVolumes(_ volumes: [MountedVolume]) {
        let groups = grouper.groups(from: volumes)
        // The last mounted volume disappearing ends this connection's prompt.
        presentedDeviceIDs.formIntersection(groups.map(\.id))
        if let pendingPrompt {
            self.pendingPrompt = groups.first { $0.id == pendingPrompt.deviceGroup.id }.map {
                MountedDevicePrompt(id: pendingPrompt.id, deviceGroup: $0)
            }
        }
    }

    public mutating func receive(
        _ volume: MountedVolume,
        among mountedVolumes: [MountedVolume],
        canPresent: Bool
    ) -> MountedDevicePromptDelivery {
        let group = grouper.group(containing: volume, among: mountedVolumes)
        if presentedDeviceIDs.contains(group.id) {
            return .alreadyPresented
        }
        guard canPresent, pendingPrompt == nil else {
            return .deferred
        }
        presentedDeviceIDs.insert(group.id)
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
