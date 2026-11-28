import Darwin
import Foundation

/// Carries verified destination evidence into a fresh review without reusing the old plan.
public struct Insta360RescanRecovery: Sendable {
    struct Recording: Sendable {
        let allMastersPresent: Bool
        let originalFolder: URL?
        let verifiedCopies: [String: VerifiedCopy]

        func hasVerifiedCopy(of file: JobFileRecord, at destination: URL) -> Bool {
            guard let copy = verifiedCopies[file.sourcePath] else { return false }
            let key = ConflictResolver.destinationKey(destination)
            guard ConflictResolver.destinationKey(copy.url) == key,
                  !file.unverifiedDestinationPaths.contains(key),
                  let info = try? CopyEngine.fileInfo(at: destination)
            else { return false }
            return copy.revision == FileRevision(info)
        }

        func completedFolder(for masters: [JobFileRecord]) -> URL? {
            guard allMastersPresent, let first = masters.first,
                  let copy = verifiedCopies[first.sourcePath] else { return nil }
            let folder = Insta360RescanRecovery.parentFolder(copy.url)
            return masters.allSatisfy { hasVerifiedCopy(of: $0, at: folder.appendingPathComponent($0.filename)) }
                ? folder : nil
        }
    }

    struct VerifiedCopy: Sendable {
        let url: URL
        let revision: FileRevision
    }

    struct FileRevision: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let changeSeconds: Int
        let changeNanoseconds: Int
        let modificationSeconds: Int
        let modificationNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            changeSeconds = info.st_ctimespec.tv_sec
            changeNanoseconds = info.st_ctimespec.tv_nsec
            modificationSeconds = info.st_mtimespec.tv_sec
            modificationNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private let recordingsBySourcePath: [String: Recording]

    public var isEmpty: Bool { recordingsBySourcePath.isEmpty }

    public var hasIncompleteRecordings: Bool {
        recordingsBySourcePath.values.contains { !$0.allMastersPresent }
    }

    public func originalFolder(for sourcePath: String) -> URL? {
        recordingsBySourcePath[sourcePath]?.originalFolder
    }

    public func includes(sourcePath: String) -> Bool {
        recordingsBySourcePath[sourcePath] != nil
    }

    public struct Preparation: Sendable {
        public let destinationFolders: [URL]
        let earlierAttempts: [(jobID: String, attemptIDs: Set<UUID>)]
    }

    public static func prepare(
        request: ScanRequest, jobRepository: JobRepository
    ) throws -> Preparation {
        var attempts = PreviousAttempts(jobID: request.rescanOfJobID, jobRepository: jobRepository)
        var matchedMasters: Set<String> = []
        var folders: Set<URL> = []
        var earlierAttempts: [(jobID: String, attemptIDs: Set<UUID>)] = []
        while let previous = try attempts.next() {
            guard let paths = MatchingPaths(previous: previous, current: request) else { continue }
            let pendingCopies = try pendingCopiesByFile(jobID: previous.id, jobRepository: jobRepository)
            var attemptIDs: Set<UUID> = []
            for group in try lensPairs(jobID: previous.id, jobRepository: jobRepository) {
                let masters = group.masterFiles.compactMap {
                    paths.previousKeyInScope($0, current: request)
                }
                guard masters.count == group.masterFiles.count,
                      matchedMasters.isDisjoint(with: masters) else { continue }
                for file in group.files {
                    guard let id = file.id, let copy = pendingCopies[id] else { continue }
                    folders.insert(parentFolder(copy.destination))
                    attemptIDs.insert(copy.id)
                }
                guard group.masterFiles.contains(where: { recordedCopy(of: $0) != nil }) else { continue }
                matchedMasters.formUnion(masters)
                folders.formUnion(group.files.compactMap(recordedCopy).map(parentFolder))
            }
            // The selected job is recovered as usual. For older jobs, replay only
            // the copy entries relevant to the recordings in this rescan.
            if previous.id != request.rescanOfJobID, !attemptIDs.isEmpty {
                earlierAttempts.append((previous.id, attemptIDs))
            }
        }
        return Preparation(destinationFolders: folders.sorted { $0.path < $1.path }, earlierAttempts: earlierAttempts)
    }

    func recording(for sourcePath: String) -> Recording? {
        recordingsBySourcePath[sourcePath]
    }

    public init(request: ScanRequest, scannedFiles: [JobFileRecord], jobRepository: JobRepository) throws {
        let detector = Insta360ClipDetector()
        var unmatched = detector.groups(files: scannedFiles)
        var result: [String: Recording] = [:]

        // Each new scan has its own job. A cancellation before its first copy can
        // leave useful evidence only on an earlier job in the rescan chain.
        var attempts = PreviousAttempts(jobID: request.rescanOfJobID, jobRepository: jobRepository)
        while !unmatched.isEmpty, let previous = try attempts.next() {
            guard let paths = MatchingPaths(previous: previous, current: request) else { continue }
            var previousByMaster: [String: Insta360ClipGroup] = [:]
            for group in try Self.lensPairs(jobID: previous.id, jobRepository: jobRepository)
            where group.masterFiles.contains(where: { Self.recordedCopy(of: $0) != nil }) {
                for file in group.masterFiles {
                    if let key = paths.previousKey(file) { previousByMaster[key] = group }
                }
            }

            var matched: Set<String> = []
            for current in unmatched {
                try Task.checkCancellation()
                let masters = Set(current.masterFiles.compactMap(paths.currentKey))
                guard let group = masters.compactMap({ previousByMaster[$0] }).first,
                      masters.allSatisfy({ (previousByMaster[$0]?.id ?? group.id) == group.id }) else { continue }
                let expected = Set(group.masterFiles.compactMap(paths.previousKey))
                guard expected.count == group.masterFiles.count else { continue }
                matched.insert(current.id)
                let recording = Self.makeRecording(
                    current: current, previous: group, paths: paths,
                    completeSource: expected.isSubset(of: masters)
                )
                for file in current.files {
                    result[file.sourcePath] = recording
                }
            }
            unmatched.removeAll { matched.contains($0.id) }
        }

        // If the original job was removed or the source cannot be identified,
        // still include both lenses when dedupe would otherwise split the pair.
        if request.rescanOfJobID != nil {
            for group in unmatched where group.masterFiles.count > 1 {
                let known = group.masterFiles.filter { $0.decision == .known && $0.knownSource != .destination }.count
                guard known > 0, known < group.masterFiles.count else { continue }
                let recording = Recording(allMastersPresent: true, originalFolder: nil, verifiedCopies: [:])
                for file in group.files {
                    result[file.sourcePath] = recording
                }
            }
        }
        try Task.checkCancellation()
        recordingsBySourcePath = result
    }

    private struct PreviousAttempts {
        var jobID: String?
        let jobRepository: JobRepository
        private var visited: Set<String> = []

        init(jobID: String?, jobRepository: JobRepository) {
            self.jobID = jobID
            self.jobRepository = jobRepository
        }

        mutating func next() throws -> ImportJob? {
            while let id = jobID, visited.insert(id).inserted {
                try Task.checkCancellation()
                guard let job = try jobRepository.fetchJob(id: id) else { return nil }
                jobID = job.rescanOfJobID
                if job.status != .scanned { return job }
            }
            return nil
        }
    }

    private static func lensPairs(
        jobID: String, jobRepository: JobRepository
    ) throws -> [Insta360ClipGroup] {
        let files = try jobRepository.fetchJobFiles(jobID: jobID)
        return Insta360ClipDetector().groups(files: files).filter { $0.masterFiles.count > 1 }
    }

    private static func pendingCopiesByFile(
        jobID: String, jobRepository: JobRepository
    ) throws -> [Int64: ImportCopyAttempt] {
        let attempts = try jobRepository.copyAttempts(jobID: jobID)
        return Dictionary(uniqueKeysWithValues: attempts.compactMap { attempt in
            guard attempt.localCopyCommitted != true, attempt.destinationDirectory != nil,
                  attempt.staged != nil || (attempt.reservedDestination != nil && attempt.directCopyDigest != nil)
            else { return nil }
            return (attempt.fileID, attempt)
        })
    }

    private static func makeRecording(
        current: Insta360ClipGroup,
        previous: Insta360ClipGroup,
        paths: MatchingPaths,
        completeSource: Bool
    ) -> Recording {
        guard completeSource else {
            return Recording(allMastersPresent: false, originalFolder: nil, verifiedCopies: [:])
        }
        let recordedPaths = Dictionary(uniqueKeysWithValues: previous.files.compactMap { file in
            paths.previousKey(file).flatMap { key in recordedCopy(of: file).map { (key, $0) } }
        })
        var verified: [String: VerifiedCopy] = [:]
        for file in current.files {
            guard let key = paths.currentKey(file), let destination = recordedPaths[key],
                  let proof = verifiedCopy(of: file, at: destination, using: CopyEngine()) else { continue }
            verified[file.sourcePath] = proof
        }

        // Only verified masters can establish a folder for completing the recording.
        let folders = Set(current.masterFiles.compactMap { verified[$0.sourcePath].map { parentFolder($0.url) } })
        let folder = folders.count == 1 ? folders.first : nil
        if let folder {
            for file in current.files where verified[file.sourcePath] == nil {
                let candidate = folder.appendingPathComponent(file.filename)
                if let key = paths.currentKey(file), let recorded = recordedPaths[key],
                   ConflictResolver.destinationKey(recorded) == ConflictResolver.destinationKey(candidate) {
                    continue
                }
                verified[file.sourcePath] = verifiedCopy(of: file, at: candidate, using: CopyEngine())
            }
        }
        let original = folder.flatMap {
            PathValidator().validate(path: $0.path, purpose: .destination).isUsable ? $0 : nil
        }
        return Recording(allMastersPresent: true, originalFolder: original, verifiedCopies: verified)
    }

    private struct MatchingPaths {
        let previousPrefix: String
        let currentPrefix: String
        let usesRelativePaths: Bool

        init?(previous: ImportJob, current: ScanRequest) {
            let oldUUID = previous.volumeUUID.flatMap { $0.isEmpty ? nil : $0 }
            let newUUID = current.volumeUUID.flatMap { $0.isEmpty ? nil : $0 }
            guard oldUUID == newUUID else { return nil }
            usesRelativePaths = oldUUID != nil
            let oldRoot = previous.volumeMountPath ?? Self.legacyVolumeRoot(previous.mountPath)
            let newRoot = current.volumeMountPath ?? Self.legacyVolumeRoot(current.mountURL.path)
            if usesRelativePaths, let oldRoot, let newRoot {
                guard let oldPrefix = Self.scopePrefix(folder: previous.mountPath, root: oldRoot),
                      let newPrefix = Self.scopePrefix(folder: current.mountURL.path, root: newRoot)
                else { return nil }
                previousPrefix = oldPrefix
                currentPrefix = newPrefix
            } else {
                previousPrefix = ""
                currentPrefix = ""
            }
        }

        func previousKey(_ file: JobFileRecord) -> String? { key(file, prefix: previousPrefix) }
        func currentKey(_ file: JobFileRecord) -> String? { key(file, prefix: currentPrefix) }

        func previousKeyInScope(_ file: JobFileRecord, current: ScanRequest) -> String? {
            guard let key = previousKey(file) else { return nil }
            if usesRelativePaths {
                return key.hasPrefix(currentPrefix) ? key : nil
            }
            guard Self.scopePrefix(folder: key, root: current.mountURL.path) != nil else { return nil }
            return key
        }

        private func key(_ file: JobFileRecord, prefix: String) -> String? {
            guard usesRelativePaths else { return file.sourcePath }
            return file.relativePath.map { prefix + $0 }
        }

        private static func scopePrefix(folder: String, root: String) -> String? {
            // The old mount may be absent. Use the recorded relative names and
            // compare the scan folder to its volume root without filesystem lookups.
            let folderParts = URL(fileURLWithPath: folder).pathComponents
            let rootParts = URL(fileURLWithPath: root).pathComponents
            guard folderParts.starts(with: rootParts) else { return nil }
            let suffix = folderParts.dropFirst(rootParts.count)
            return suffix.isEmpty ? "" : suffix.joined(separator: "/") + "/"
        }

        private static func legacyVolumeRoot(_ path: String) -> String? {
            let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            guard components.count >= 3, components[1] == "Volumes" else { return nil }
            return "/Volumes/" + components[2]
        }
    }

    private static func parentFolder(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
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

    private static func verifiedCopy(
        of file: JobFileRecord, at destination: URL, using copyEngine: CopyEngine
    ) -> VerifiedCopy? {
        guard !Task.isCancelled,
              let info = try? CopyEngine.fileInfo(at: destination), info.st_size == file.size,
              let sourceDigest = try? copyEngine.readSourceDigest(at: URL(fileURLWithPath: file.sourcePath)),
              let digest = try? CopyEngine.readDigest(at: destination, identity: ImportCopyFileIdentity(info)),
              digest == sourceDigest,
              let current = try? CopyEngine.fileInfo(at: destination), FileRevision(info) == FileRevision(current)
        else { return nil }
        return VerifiedCopy(url: destination, revision: FileRevision(current))
    }

    static func matchesSource(_ file: JobFileRecord, at destination: URL, using copyEngine: CopyEngine) -> Bool {
        verifiedCopy(of: file, at: destination, using: copyEngine) != nil
    }
}
