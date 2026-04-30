import Foundation

public enum ConflictResolution: Equatable, Sendable {
    case copy(to: URL)
    case skip(reason: String)
}

public struct ConflictResolver {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func resolveDestination(
        candidate: URL,
        expectedFingerprint: FileFingerprint
    ) -> ConflictResolution {
        if !fileManager.fileExists(atPath: candidate.path) {
            return .copy(to: candidate)
        }

        if existingFileMatches(candidate, expectedFingerprint: expectedFingerprint) {
            return .skip(reason: "already_exists_same_fingerprint")
        }

        let directory = candidate.deletingLastPathComponent()
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension

        var counter = 1
        while true {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let next = directory.appendingPathComponent("\(stem)-copy-\(counter)\(suffix)")
            if !fileManager.fileExists(atPath: next.path) {
                return .copy(to: next)
            }
            if existingFileMatches(next, expectedFingerprint: expectedFingerprint) {
                return .skip(reason: "already_exists_same_fingerprint")
            }
            counter += 1
        }
    }

    private func existingFileMatches(
        _ url: URL,
        expectedFingerprint: FileFingerprint
    ) -> Bool {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            let modificationDate = attributes[.modificationDate] as? Date
        else {
            return false
        }

        let fileSize = size.int64Value
        guard fileSize == expectedFingerprint.size else {
            return false
        }

        let actual = FileFingerprint.compute(
            size: fileSize,
            modificationDate: modificationDate,
            identityHint: expectedFingerprint.identityHint
        )
        return actual.value == expectedFingerprint.value
    }
}
