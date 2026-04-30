import Foundation

public struct MediaClassifier: Sendable {
    public static let photoExtensions: Set<String> = [
        ".jpg",
        ".jpeg",
        ".heif",
        ".heic",
        ".dng",
        ".raw",
        ".cr2",
        ".nef",
        ".arw",
        ".raf"
    ]

    public static let videoExtensions: Set<String> = [
        ".mp4",
        ".mov",
        ".avi",
        ".mkv"
    ]

    public init() {}

    public func classify(extension ext: String) -> MediaKind {
        let normalized = ext.lowercased()
        if Self.photoExtensions.contains(normalized) {
            return .photo
        }
        if Self.videoExtensions.contains(normalized) {
            return .video
        }
        return .unsupported
    }

    public func classify(url: URL) -> MediaKind {
        classify(extension: "." + url.pathExtension)
    }
}
