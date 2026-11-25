import Foundation

/// Carries verified destination evidence into a fresh review without reusing the old plan.
public struct Insta360RescanRecovery: Sendable {
    struct Recording: Sendable {
        let allMastersPresent: Bool
        let originalFolder: URL?
        let verifiedCopies: [String: URL]
    }

    private let recordingsBySourcePath: [String: Recording]

    public var isEmpty: Bool { recordingsBySourcePath.isEmpty }

    public var hasOriginalFolders: Bool {
        recordingsBySourcePath.values.contains { $0.originalFolder != nil }
    }

    public var hasIncompleteRecordings: Bool {
        recordingsBySourcePath.values.contains { !$0.allMastersPresent }
    }

    public func originalFolder(for sourcePath: String) -> URL? {
        recordingsBySourcePath[sourcePath]?.originalFolder
    }

    public func includes(sourcePath: String) -> Bool {
        recordingsBySourcePath[sourcePath] != nil
    }

    func recording(for sourcePath: String) -> Recording? {
        recordingsBySourcePath[sourcePath]
    }

    public init(previousFiles: [JobFileRecord], scannedFiles: [JobFileRecord]) throws {
        let detector = Insta360ClipDetector()
        var previousByMasterPath: [String: Insta360ClipGroup] = [:]
        for group in detector.groups(files: previousFiles) where group.masterFiles.count > 1 {
            let completed = group.masterFiles.filter { Self.recordedCopy(of: $0) != nil }.count
            guard completed > 0, completed < group.masterFiles.count else { continue }
            for master in group.masterFiles {
                previousByMasterPath[master.sourcePath] = group
            }
        }

        var result: [String: Recording] = [:]
        for group in detector.groups(files: scannedFiles) {
            try Task.checkCancellation()
            guard let previous = group.masterFiles.lazy.compactMap({ previousByMasterPath[$0.sourcePath] }).first
            else { continue }
            let newMasters = Set(group.masterFiles.map(\.sourcePath))
            let allMastersPresent = previous.masterFiles.allSatisfy { newMasters.contains($0.sourcePath) }
            let previousCopies = previous.files.compactMap { file in
                Self.recordedCopy(of: file).map { (file.sourcePath, $0) }
            }
            let copiedMasters = Set(previous.masterFiles.compactMap { file in
                Self.recordedCopy(of: file).map { _ in file.sourcePath }
            })
            let currentByPath = Dictionary(uniqueKeysWithValues: group.files.map { ($0.sourcePath, $0) })
            var verifiedCopies: [String: URL] = [:]
            if allMastersPresent {
                for (path, destination) in previousCopies {
                    guard let file = currentByPath[path],
                          Self.matchesSource(file, at: destination, using: CopyEngine())
                    else { continue }
                    verifiedCopies[path] = destination
                }
            }
            let folders = Set(copiedMasters.compactMap {
                verifiedCopies[$0]?.deletingLastPathComponent().resolvingSymlinksInPath()
            })
            let originalFolder = folders.count == 1 && copiedMasters.isSubset(of: Set(verifiedCopies.keys))
                ? folders.first : nil
            let writableFolder = originalFolder.flatMap {
                PathValidator().validate(path: $0.path, purpose: .destination).isUsable ? $0 : nil
            }
            let recording = Recording(
                allMastersPresent: allMastersPresent, originalFolder: writableFolder, verifiedCopies: verifiedCopies
            )
            for file in group.files {
                result[file.sourcePath] = recording
            }
        }
        try Task.checkCancellation()
        recordingsBySourcePath = result
    }

    private static func recordedCopy(of file: JobFileRecord) -> URL? {
        let path: String?
        switch file.copyStatus {
        case .copied:
            path = file.finalDestinationPath
        case .skipped where file.knownSource == .destination:
            path = file.plannedDestinationPath
        default:
            path = nil
        }
        return path.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    static func matchesSource(_ file: JobFileRecord, at destination: URL, using copyEngine: CopyEngine) -> Bool {
        guard let info = try? CopyEngine.fileInfo(at: destination), info.st_size == file.size,
              let sourceDigest = try? copyEngine.readSourceDigest(at: URL(fileURLWithPath: file.sourcePath)),
              let destinationDigest = try? CopyEngine.readDigest(at: destination) else { return false }
        return sourceDigest == destinationDigest
    }
}
