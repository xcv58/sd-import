import Foundation

public struct Insta360ClipGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let masterFiles: [JobFileRecord]
    public let proxyFiles: [JobFileRecord]

    public var files: [JobFileRecord] {
        masterFiles + proxyFiles
    }

    public init(id: String, masterFiles: [JobFileRecord], proxyFiles: [JobFileRecord]) {
        self.id = id
        self.masterFiles = masterFiles
        self.proxyFiles = proxyFiles
    }
}

public struct RecordingPresentationUnit: Identifiable, Equatable, Sendable {
    public let id: String
    public let files: [JobFileRecord]
    public let isInsta360Recording: Bool

    public var primaryFile: JobFileRecord {
        files[0]
    }

    public var totalSize: Int64 {
        files.reduce(Int64(0)) { $0 + $1.size }
    }

    public init(id: String, files: [JobFileRecord], isInsta360Recording: Bool) {
        precondition(!files.isEmpty)
        self.id = id
        self.files = files
        self.isInsta360Recording = isInsta360Recording
    }
}

public enum RecordingPresentation {
    public static func units(files: [JobFileRecord]) -> [RecordingPresentationUnit] {
        let groups = Insta360ClipDetector().groups(files: files)
        let groupBySourcePath = Dictionary(
            uniqueKeysWithValues: groups.flatMap { group in
                group.files.map { ($0.sourcePath, group) }
            }
        )
        var emittedGroupIDs: Set<String> = []
        var result: [RecordingPresentationUnit] = []

        for file in files {
            if let group = groupBySourcePath[file.sourcePath] {
                guard emittedGroupIDs.insert(group.id).inserted else { continue }
                result.append(
                    RecordingPresentationUnit(
                        id: "insta360:\(group.id)",
                        files: group.files,
                        isInsta360Recording: true
                    )
                )
            } else {
                result.append(
                    RecordingPresentationUnit(
                        id: "file:\(file.sourcePath)",
                        files: [file],
                        isInsta360Recording: false
                    )
                )
            }
        }
        return result
    }
}

public struct Insta360ClipDetector: Sendable {
    private struct Candidate {
        let key: String
        let channel: String
        let file: JobFileRecord
        let isMaster: Bool
    }

    public init() {}

    public func groups(files: [JobFileRecord]) -> [Insta360ClipGroup] {
        let candidates = files.compactMap { file -> Candidate? in
            let ext = normalizedExtension(file)
            guard ext == "insv" || ext == "lrv",
                  let identity = recordingIdentity(file) else {
                return nil
            }
            let isMaster = ext == "insv"
            guard isMaster ? identity.channel.last == "0" : identity.channel.last == "1" else {
                return nil
            }
            return Candidate(
                key: identity.key,
                channel: identity.channel,
                file: file,
                isMaster: isMaster
            )
        }

        return Dictionary(grouping: candidates, by: \.key)
            .compactMap { key, members -> Insta360ClipGroup? in
                let masterCandidates = members.filter(\.isMaster)
                let masters = masterCandidates.map(\.file).sorted(by: Self.fileOrder)
                guard !masters.isEmpty else {
                    return nil
                }
                let masterChannels = Set(masterCandidates.map(\.channel))
                let proxies = members
                    .filter { candidate in
                        guard !candidate.isMaster,
                              let requiredMaster = Self.masterChannel(forProxyChannel: candidate.channel) else {
                            return false
                        }
                        return masterChannels.contains(requiredMaster)
                    }
                    .map(\.file)
                    .sorted(by: Self.fileOrder)
                return Insta360ClipGroup(id: key, masterFiles: masters, proxyFiles: proxies)
            }
            .sorted { $0.id < $1.id }
    }

    public func unitIDBySourcePath(files: [JobFileRecord]) -> [String: String] {
        var result = Dictionary(
            uniqueKeysWithValues: files.map { ($0.sourcePath, "file:\($0.sourcePath)") }
        )
        for group in groups(files: files) {
            for file in group.files {
                result[file.sourcePath] = "insta360:\(group.id)"
            }
        }
        return result
    }

    public static func isProprietaryRecordingFile(_ file: JobFileRecord) -> Bool {
        let ext = file.ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return ext == "insv" || ext == "lrv"
    }

    private func recordingIdentity(_ file: JobFileRecord) -> (key: String, channel: String)? {
        let relativePath = (file.relativePath ?? file.filename)
            .replacingOccurrences(of: "\\", with: "/")
        let url = URL(fileURLWithPath: relativePath)
        let components = url.deletingPathExtension().lastPathComponent.split(separator: "_").map(String.init)
        guard components.count >= 4 else {
            return nil
        }
        let suffix = Array(components.suffix(4))
        guard isDigits(suffix[0], count: 8),
              isDigits(suffix[1], count: 6),
              isDigits(suffix[2], count: 2),
              isDigits(suffix[3]) else {
            return nil
        }
        let directory = url.deletingLastPathComponent().path
        let key = [directory, suffix[0], suffix[1], suffix[3]].joined(separator: "|")
        return (key, suffix[2])
    }

    private static func masterChannel(forProxyChannel channel: String) -> String? {
        guard channel.count == 2, channel.last == "1" else {
            return nil
        }
        return String(channel.dropLast()) + "0"
    }

    private func isDigits(_ value: String, count: Int? = nil) -> Bool {
        (count == nil || value.count == count)
            && !value.isEmpty
            && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func normalizedExtension(_ file: JobFileRecord) -> String {
        let storedExtension = file.ext.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = storedExtension.isEmpty ? URL(fileURLWithPath: file.filename).pathExtension : storedExtension
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func fileOrder(_ lhs: JobFileRecord, _ rhs: JobFileRecord) -> Bool {
        lhs.sourcePath.localizedStandardCompare(rhs.sourcePath) == .orderedAscending
    }
}

struct RecordingAwareScanCounts: Equatable, Sendable {
    var scannedFiles = 0
    var newFiles = 0
    var knownFiles = 0
    var unsupportedFiles = 0
    var conflictFiles = 0
    var portableKnownFiles = 0
    var importedFiles = 0
    var skippedFiles = 0
    var failedFiles = 0
}

enum RecordingAwareScanSummary {
    static func counts(files: [JobFileRecord]) -> RecordingAwareScanCounts {
        let groups = Insta360ClipDetector().groups(files: files)
        let groupedPaths = Set(groups.flatMap(\.files).map(\.sourcePath))
        var result = RecordingAwareScanCounts()

        for file in files where !groupedPaths.contains(file.sourcePath) {
            add(file: file, to: &result)
        }

        for group in groups {
            result.scannedFiles += 1
            if group.files.contains(where: { $0.decision == .conflict }) {
                result.conflictFiles += 1
            } else if group.files.allSatisfy({ $0.decision == .known }) {
                result.knownFiles += 1
                if group.files.contains(where: { $0.knownSource == .portableLedger }) {
                    result.portableKnownFiles += 1
                }
            } else {
                result.newFiles += 1
            }
            addCopyStatus(files: group.files, to: &result)
        }
        return result
    }

    private static func add(file: JobFileRecord, to result: inout RecordingAwareScanCounts) {
        result.scannedFiles += 1
        switch file.decision {
        case .new:
            result.newFiles += 1
        case .known:
            result.knownFiles += 1
            if file.knownSource == .portableLedger {
                result.portableKnownFiles += 1
            }
        case .unsupported:
            result.unsupportedFiles += 1
        case .conflict:
            result.conflictFiles += 1
        }
        addCopyStatus(files: [file], to: &result)
    }

    private static func addCopyStatus(
        files: [JobFileRecord],
        to result: inout RecordingAwareScanCounts
    ) {
        if files.contains(where: { $0.copyStatus == .failed }) {
            result.failedFiles += 1
        } else if files.contains(where: { $0.copyStatus == .copied }) {
            result.importedFiles += 1
        } else if !files.isEmpty && files.allSatisfy({ $0.copyStatus == .skipped }) {
            result.skippedFiles += 1
        }
    }
}
