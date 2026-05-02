import Foundation

public struct MountedVolume: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let mountURL: URL
    public let volumeUUID: String?
    public let isRemovable: Bool

    public init(
        id: String,
        name: String,
        mountURL: URL,
        volumeUUID: String?,
        isRemovable: Bool
    ) {
        self.id = id
        self.name = name
        self.mountURL = mountURL
        self.volumeUUID = volumeUUID
        self.isRemovable = isRemovable
    }
}
