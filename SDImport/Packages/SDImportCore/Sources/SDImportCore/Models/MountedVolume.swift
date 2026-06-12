import Foundation

public struct MountedVolume: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let mountURL: URL
    public let volumeUUID: String?
    public let isRemovable: Bool
    public let isInternal: Bool
    public let isDiskImage: Bool
    public let totalCapacityBytes: Int64?
    public let availableCapacityBytes: Int64?

    public init(
        id: String,
        name: String,
        mountURL: URL,
        volumeUUID: String?,
        isRemovable: Bool,
        isInternal: Bool = false,
        isDiskImage: Bool = false,
        totalCapacityBytes: Int64? = nil,
        availableCapacityBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.mountURL = mountURL
        self.volumeUUID = volumeUUID
        self.isRemovable = isRemovable
        self.isInternal = isInternal
        self.isDiskImage = isDiskImage
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

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mountURL
        case volumeUUID
        case isRemovable
        case isInternal
        case isDiskImage
        case totalCapacityBytes
        case availableCapacityBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mountURL = try container.decode(URL.self, forKey: .mountURL)
        volumeUUID = try container.decodeIfPresent(String.self, forKey: .volumeUUID)
        isRemovable = try container.decode(Bool.self, forKey: .isRemovable)
        isInternal = try container.decodeIfPresent(Bool.self, forKey: .isInternal) ?? false
        isDiskImage = try container.decodeIfPresent(Bool.self, forKey: .isDiskImage) ?? false
        totalCapacityBytes = try container.decodeIfPresent(Int64.self, forKey: .totalCapacityBytes)
        availableCapacityBytes = try container.decodeIfPresent(Int64.self, forKey: .availableCapacityBytes)
    }
}
