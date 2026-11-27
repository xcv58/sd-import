import Darwin
import Foundation
import os

struct ImportCopyAttempt: Codable {
    let id: UUID
    let fileID: Int64
    let jobID: String
    let sourcePath: String
    let destinationPath: String
    let fingerprint: FileFingerprint
    var destinationDirectory: ImportCopyDirectoryIdentity?
    var requiresDestinationReview: Bool? = nil
    var stagingIdentity: ImportCopyFileIdentity?
    var staged: StagedImportCopy?
    var reservedDestination: ImportCopyFileIdentity?
    var directCopyDigest: Data?
    var modificationDate: Date?
    var portableReceipt: CopyPortableReceipt?
    var localCopyCommitted: Bool? = nil

    var destination: URL { URL(fileURLWithPath: destinationPath) }

    var staging: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".sdimport-\(id.uuidString).part")
    }

    func destinationIsAccessible() -> Bool {
        destinationDirectory?.matches(at: destination.deletingLastPathComponent()) == true
    }
}

struct ImportCopyDirectoryIdentity: Codable, Sendable {
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let device: Int32
    let volumeUUID: String?

    init?(at url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        inode = info.st_ino
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        device = info.st_dev
        volumeUUID = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    func matches(at url: URL) -> Bool {
        guard let current = Self(at: url),
              inode == current.inode, birthSeconds == current.birthSeconds,
              birthNanoseconds == current.birthNanoseconds else { return false }
        return occupiesSameVolume(as: current)
    }

    func occupiesSameVolume(as other: Self) -> Bool {
        if let volumeUUID { return volumeUUID == other.volumeUUID }
        return device == other.device
    }

    func matchesOpenedDirectory(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && inode == info.st_ino && device == info.st_dev
            && birthSeconds == info.st_birthtimespec.tv_sec
            && birthNanoseconds == info.st_birthtimespec.tv_nsec
    }
}

final class OpenImportDestination {
    let descriptor: Int32

    init?(at directory: URL, identity: ImportCopyDirectoryIdentity) {
        let descriptor = open(directory.path, O_SEARCH | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard identity.matchesOpenedDirectory(descriptor) else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}

/// Keeps the approved path and the identity of its deepest existing directory.
/// New subfolders may appear under that directory without changing the approval.
public struct ReviewedImportDestinations: Sendable {
    private struct Directory: Sendable {
        let path: URL
        let ancestor: URL
        let resolvedAncestor: URL
        let resolvedPath: URL
        let identity: ImportCopyDirectoryIdentity

        func matches() -> Bool {
            guard identity.matches(at: ancestor), let current = Self.resolve(path) else { return false }
            return current.resolvedPath.path == resolvedPath.path && identity.occupiesSameVolume(as: current.identity)
        }

        static func resolve(_ path: URL) -> Directory? {
            var ancestor = path
            var missing: [String] = []
            while true {
                if let identity = ImportCopyDirectoryIdentity(at: ancestor) {
                    guard let canonicalPath = realpath(ancestor.path, nil) else { return nil }
                    defer { free(canonicalPath) }
                    let canonicalAncestor = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
                    let resolved = missing.reversed().reduce(canonicalAncestor) { url, name in
                        url.appendingPathComponent(name, isDirectory: true)
                    }
                    return Directory(
                        path: path, ancestor: ancestor, resolvedAncestor: canonicalAncestor,
                        resolvedPath: resolved, identity: identity
                    )
                }
                // Only an absent component can be created beneath an approved directory.
                var entry = stat()
                guard lstat(ancestor.path, &entry) == -1, errno == ENOENT,
                      ancestor.path != "/" else { return nil }
                missing.append(ancestor.lastPathComponent)
                ancestor.deleteLastPathComponent()
            }
        }
    }

    private let directories: [String: Directory]
    private let skippedFiles: [String: ReviewedFileIdentity]
    private typealias MaterializedDirectories = OSAllocatedUnfairLock<[String: ImportCopyDirectoryIdentity]>
    private let materialized: MaterializedDirectories
    private let otherApprovals: [MaterializedDirectories]

    private init(
        directories: [String: Directory], skippedFiles: [String: ReviewedFileIdentity],
        materialized: MaterializedDirectories, otherApprovals: [MaterializedDirectories]
    ) {
        self.directories = directories
        self.skippedFiles = skippedFiles
        self.materialized = materialized
        self.otherApprovals = otherApprovals
    }

    public init?(plans: [ImportFilePlan]) {
        var directories: [String: Directory] = [:]
        var skippedFiles: [String: ReviewedFileIdentity] = [:]
        for plan in plans where plan.willCopy {
            guard let path = plan.destinationPath else { return nil }
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            if directories[directory.path] == nil {
                guard let approved = Directory.resolve(directory) else { return nil }
                directories[directory.path] = approved
            }
        }
        for plan in plans where plan.disposition == .alreadyExists {
            guard let path = plan.destinationPath, let identity = ReviewedFileIdentity(path: path) else { return nil }
            skippedFiles[path] = identity
        }
        self.init(
            directories: directories, skippedFiles: skippedFiles,
            materialized: MaterializedDirectories(initialState: [:]), otherApprovals: []
        )
    }

    /// Record newly created folders in the other confirmed plans, even if copying stops before they run.
    public func sharingMaterializedDirectories(with approvals: [Self]) -> Self {
        Self(
            directories: directories, skippedFiles: skippedFiles,
            materialized: materialized, otherApprovals: approvals.map(\.materialized)
        )
    }

    public func matches() -> Bool {
        directories.values.allSatisfy { matches($0.path) }
            && skippedFiles.allSatisfy { $0.value.matches(path: $0.key) }
    }

    func matches(_ directory: URL) -> Bool {
        guard let approved = directories[directory.path], approved.matches() else { return false }
        let observed = materialized.withLock { $0 }
        var current = approved.resolvedPath
        while current.path != "/" {
            if let identity = observed[current.path], !identity.matches(at: current) { return false }
            current.deleteLastPathComponent()
        }
        return true
    }

    func matchesSkippedFile(at path: String) -> Bool {
        skippedFiles[path]?.matches(path: path) == true
    }

    func remember(_ identity: ImportCopyDirectoryIdentity, at directory: URL) -> Bool {
        guard let approved = directories[directory.path], matches(directory) else { return false }
        var current = approved.resolvedPath
        var observed = [current.path: identity]
        while current.path != approved.resolvedAncestor.path {
            current.deleteLastPathComponent()
            if current.path == approved.resolvedAncestor.path { break }
            guard let parent = ImportCopyDirectoryIdentity(at: current) else { return false }
            observed[current.path] = parent
        }
        let identities = observed
        materialized.withLock { $0.merge(identities) { existing, _ in existing } }
        guard matches(directory), identity.matches(at: directory) else { return false }
        for approval in otherApprovals {
            approval.withLock { $0.merge(identities) { existing, _ in existing } }
        }
        return true
    }
}

struct ImportCopyFileIdentity: Codable {
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(_ info: stat) {
        inode = info.st_ino
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    }

    func matchesInode(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && inode == info.st_ino
    }

    func matches(_ info: stat) -> Bool {
        matchesInode(info)
            && birthSeconds == Int64(info.st_birthtimespec.tv_sec)
            && birthNanoseconds == Int64(info.st_birthtimespec.tv_nsec)
    }
}

struct StagedImportCopy: Codable {
    let identity: ImportCopyFileIdentity
    let size: Int64
    let digest: Data

    init(info: stat, digest: Data) {
        identity = ImportCopyFileIdentity(info)
        size = info.st_size
        self.digest = digest
    }

    func matches(_ info: stat) -> Bool {
        identity.matches(info) && size == info.st_size
    }
}

struct CopyPortableReceipt: Codable {
    let rootPath: String
    let rootIdentity: ImportCopyDirectoryIdentity
    let fileIdentity: PortableFileIdentity

    func replay(sourcePath: String, copiedDigest: Data?) throws -> Bool {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard rootIdentity.matches(at: root),
              let info = try CopyEngine.fileInfo(at: URL(fileURLWithPath: sourcePath)),
              info.st_mode & S_IFMT == S_IFREG, info.st_size == fileIdentity.size,
              Int64(info.st_mtimespec.tv_sec) == fileIdentity.modificationTimeEpochSeconds else {
            return false
        }
        guard let copiedDigest,
              try CopyEngine.readDigest(at: URL(fileURLWithPath: sourcePath), identity: ImportCopyFileIdentity(info))
                == copiedDigest else { return false }
        let ledger = PortableImportReceiptLedger(sourceRootURL: root)
        let snapshot = try ledger.load()
        if !snapshot.fingerprints.contains(PortableImportReceiptLedger.portableFingerprint(for: fileIdentity)) {
            try ledger.append(identity: fileIdentity)
        }
        return true
    }
}
