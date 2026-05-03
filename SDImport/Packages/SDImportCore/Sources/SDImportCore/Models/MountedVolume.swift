import Foundation

public struct MountedVolume: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let mountURL: URL
    public let volumeUUID: String?
    public let isRemovable: Bool
    public let isInternal: Bool
    public let totalCapacityBytes: Int64?
    public let availableCapacityBytes: Int64?

    public init(
        id: String,
        name: String,
        mountURL: URL,
        volumeUUID: String?,
        isRemovable: Bool,
        isInternal: Bool = false,
        totalCapacityBytes: Int64? = nil,
        availableCapacityBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.mountURL = mountURL
        self.volumeUUID = volumeUUID
        self.isRemovable = isRemovable
        self.isInternal = isInternal
        self.totalCapacityBytes = totalCapacityBytes
        self.availableCapacityBytes = availableCapacityBytes
    }

    public var usedCapacityBytes: Int64? {
        guard
            let totalCapacityBytes,
            let availableCapacityBytes,
            totalCapacityBytes >= availableCapacityBytes
        else {
            return nil
        }

        return totalCapacityBytes - availableCapacityBytes
    }
}
