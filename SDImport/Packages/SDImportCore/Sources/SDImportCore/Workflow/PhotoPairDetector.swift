import Foundation

public struct PhotoPairSummary: Equatable, Sendable {
    public let rawJPEGPairCount: Int
    public let rawOnlyCount: Int
    public let jpegOnlyCount: Int

    public init(rawJPEGPairCount: Int, rawOnlyCount: Int, jpegOnlyCount: Int) {
        self.rawJPEGPairCount = rawJPEGPairCount
        self.rawOnlyCount = rawOnlyCount
        self.jpegOnlyCount = jpegOnlyCount
    }
}

public struct PhotoPairDetector: Sendable {
    private let rawExtensions: Set<String> = [
        ".arw",
        ".cr2",
        ".dng",
        ".nef",
        ".raf",
        ".raw"
    ]
    private let jpegExtensions: Set<String> = [
        ".jpg",
        ".jpeg"
    ]

    public init() {}

    public func summarize(files: [JobFileRecord]) -> PhotoPairSummary {
        struct Group {
            var rawCount = 0
            var jpegCount = 0
        }

        var groups: [String: Group] = [:]
        for file in files where file.mediaKind == .photo {
            let ext = file.ext.lowercased()
            guard rawExtensions.contains(ext) || jpegExtensions.contains(ext) else {
                continue
            }

            let key = pairKey(for: file)
            var group = groups[key, default: Group()]
            if rawExtensions.contains(ext) {
                group.rawCount += 1
            } else if jpegExtensions.contains(ext) {
                group.jpegCount += 1
            }
            groups[key] = group
        }

        var pairCount = 0
        var rawOnlyCount = 0
        var jpegOnlyCount = 0

        for group in groups.values {
            let pairs = min(group.rawCount, group.jpegCount)
            pairCount += pairs
            rawOnlyCount += max(0, group.rawCount - pairs)
            jpegOnlyCount += max(0, group.jpegCount - pairs)
        }

        return PhotoPairSummary(
            rawJPEGPairCount: pairCount,
            rawOnlyCount: rawOnlyCount,
            jpegOnlyCount: jpegOnlyCount
        )
    }

    private func pairKey(for file: JobFileRecord) -> String {
        let relativePath = (file.relativePath ?? file.filename)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let url = URL(fileURLWithPath: relativePath)
        let directory = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        return "\(directory)/\(stem)"
    }
}
