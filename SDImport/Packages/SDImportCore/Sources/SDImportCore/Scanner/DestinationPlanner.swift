import Foundation

public struct DestinationPlanner: Sendable {
    public init() {}

    public func destinationDirectory(
        for mediaKind: MediaKind,
        captureDate: String,
        location: String,
        roots: DestinationRoots
    ) -> URL? {
        classicDestinationDirectory(
            for: mediaKind,
            captureDate: captureDate,
            sessionLabel: location,
            roots: roots
        )
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
        folderGrouping: ImportFolderGrouping = .byDay,
        relativePath: String? = nil,
        volumeName: String? = nil
    ) -> URL? {
        let folderName = "\(captureDate) \(safeComponent(sessionLabel, fallback: "Untitled"))"

        switch organizationPreset {
        case .classicDatedFolders:
            if folderGrouping == .oneShootFolder {
                return classicDestinationDirectory(
                    for: mediaKind,
                    captureDate: captureDate,
                    sessionLabel: sessionLabel,
                    roots: roots
                )?
                    .appendingPathComponent(safeComponent(filename, fallback: "File"), isDirectory: false)
            }

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
                .appendingPathComponent(folderName, isDirectory: true)
            if folderGrouping == .oneShootFolder {
                return sessionDirectory.appendingPathComponent(safeComponent(filename, fallback: "File"), isDirectory: false)
            }

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
            return sessionDirectory.appendingPathComponent(safeComponent(filename, fallback: "File"), isDirectory: false)
        }
    }

    private func classicDestinationDirectory(
        for mediaKind: MediaKind,
        captureDate: String,
        sessionLabel: String,
        roots: DestinationRoots
    ) -> URL? {
        guard mediaKind != .unsupported else {
            return nil
        }

        var folderName = "\(captureDate) \(safeComponent(sessionLabel, fallback: "Untitled"))"
        if rootsShareDirectory(roots) {
            folderName += mediaKind == .photo ? "-Photos" : "-Video"
        }

        let root = mediaKind == .photo ? roots.photosURL : roots.videosURL
        return root.appendingPathComponent(folderName, isDirectory: true)
    }

    private func rootsShareDirectory(_ roots: DestinationRoots) -> Bool {
        roots.photosURL.standardizedFileURL.path == roots.videosURL.standardizedFileURL.path
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
