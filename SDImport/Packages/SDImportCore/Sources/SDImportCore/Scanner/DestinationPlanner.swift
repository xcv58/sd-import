import Foundation

public struct DestinationPlanner: Sendable {
    public init() {}

    public func destinationDirectory(
        for mediaKind: MediaKind,
        captureDate: String,
        location: String,
        roots: DestinationRoots
    ) -> URL? {
        switch mediaKind {
        case .photo:
            let safeLocation = location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : location
            return roots.photosURL.appendingPathComponent("\(captureDate) \(safeLocation)", isDirectory: true)
        case .video:
            return roots.videosURL.appendingPathComponent("tmp-\(captureDate)-videos", isDirectory: true)
        case .unsupported:
            return nil
        }
    }

    public func destinationURL(
        filename: String,
        mediaKind: MediaKind,
        captureDate: String,
        location: String,
        roots: DestinationRoots
    ) -> URL? {
        destinationDirectory(
            for: mediaKind,
            captureDate: captureDate,
            location: location,
            roots: roots
        )?.appendingPathComponent(filename, isDirectory: false)
    }

    public func destinationURL(
        filename: String,
        mediaKind: MediaKind,
        captureDate: String,
        sessionLabel: String,
        roots: DestinationRoots,
        organizationPreset: ImportOrganizationPreset,
        relativePath: String? = nil,
        volumeName: String? = nil
    ) -> URL? {
        switch organizationPreset {
        case .classicDatedFolders:
            return destinationURL(
                filename: filename,
                mediaKind: mediaKind,
                captureDate: captureDate,
                location: sessionLabel,
                roots: roots
            )

        case .shootSessionsByDate:
            guard mediaKind != .unsupported else {
                return nil
            }
            let sessionDirectory = roots.photosURL
                .appendingPathComponent("\(captureDate) \(safeComponent(sessionLabel, fallback: "Untitled"))", isDirectory: true)
            let mediaDirectory = mediaKind == .photo ? "Photos" : "Video"
            return sessionDirectory
                .appendingPathComponent(mediaDirectory, isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)

        case .footageBackup:
            guard mediaKind == .video || mediaKind == .unsupported else {
                return nil
            }
            let sessionDirectory = roots.videosURL
                .appendingPathComponent("\(captureDate) \(safeComponent(sessionLabel, fallback: "Footage"))", isDirectory: true)
                .appendingPathComponent("Card \(safeComponent(volumeName, fallback: "Unknown"))", isDirectory: true)
            return sessionDirectory.appendingPathComponent(safeComponent(filename, fallback: "File"), isDirectory: false)
        }
    }

    private func safeComponent(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? fallback : trimmed
        let invalid = CharacterSet(charactersIn: "/:")
        return source
            .components(separatedBy: invalid)
            .joined(separator: "-")
    }

}
