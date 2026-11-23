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
    public let wholeDiskIdentifier: String?
    public let deviceGroupIdentifier: String?
    public let deviceVendorName: String?
    public let deviceProductName: String?

    public init(
        id: String,
        name: String,
        mountURL: URL,
        volumeUUID: String?,
        isRemovable: Bool,
        isInternal: Bool = false,
        isDiskImage: Bool = false,
        totalCapacityBytes: Int64? = nil,
        availableCapacityBytes: Int64? = nil,
        wholeDiskIdentifier: String? = nil,
        deviceGroupIdentifier: String? = nil,
        deviceVendorName: String? = nil,
        deviceProductName: String? = nil
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
        self.wholeDiskIdentifier = wholeDiskIdentifier
        self.deviceGroupIdentifier = deviceGroupIdentifier
        self.deviceVendorName = deviceVendorName
        self.deviceProductName = deviceProductName
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

    public var mountPath: String { mountURL.standardizedFileURL.path }

    public var physicalDeviceDisplayName: String? {
        let vendor = deviceVendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let product = deviceProductName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let product, !product.isEmpty {
            guard let vendor, !vendor.isEmpty else {
                return product
            }
            if product.localizedCaseInsensitiveContains(vendor) {
                return product
            }
            return "\(vendor) \(product)"
        }
        if let vendor, !vendor.isEmpty {
            return vendor
        }
        return nil
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
        case wholeDiskIdentifier
        case deviceGroupIdentifier
        case deviceVendorName
        case deviceProductName
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
        wholeDiskIdentifier = try container.decodeIfPresent(String.self, forKey: .wholeDiskIdentifier)
        deviceGroupIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceGroupIdentifier)
        deviceVendorName = try container.decodeIfPresent(String.self, forKey: .deviceVendorName)
        deviceProductName = try container.decodeIfPresent(String.self, forKey: .deviceProductName)
    }
}
