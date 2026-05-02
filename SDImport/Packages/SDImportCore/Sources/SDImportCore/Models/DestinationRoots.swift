import Foundation

public struct DestinationRoots: Equatable, Codable, Sendable {
    public let photosURL: URL
    public let videosURL: URL

    public init(photosURL: URL, videosURL: URL) {
        self.photosURL = photosURL
        self.videosURL = videosURL
    }
}
