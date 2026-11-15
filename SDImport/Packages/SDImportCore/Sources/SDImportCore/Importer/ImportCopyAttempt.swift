import Darwin
import Foundation

struct ImportCopyAttempt: Codable {
    let id: UUID
    let fileID: Int64
    let jobID: String
    let sourcePath: String
    let destinationPath: String
    let fingerprint: FileFingerprint
    var destinationDirectory: ImportCopyDirectoryIdentity?
    var requiresDestinationReview = false
    var stagingIdentity: ImportCopyFileIdentity?
    var staged: StagedImportCopy?
    var reservedDestination: ImportCopyFileIdentity?
    var directCopyDigest: Data?
    var portableReceipt: CopyPortableReceipt?
    var localCopyCommitted = false

    var destination: URL { URL(fileURLWithPath: destinationPath) }

    var staging: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".sdimport-\(id.uuidString).part")
    }

    func destinationIsAccessible() -> Bool {
        destinationDirectory?.matches(at: destination.deletingLastPathComponent()) == true
    }
}

struct ImportCopyDirectoryIdentity: Codable {
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
        if let volumeUUID { return volumeUUID == current.volumeUUID }
        return device == current.device
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

    func replay(sourcePath: String) throws -> Bool {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard rootIdentity.matches(at: root),
              let info = try CopyEngine.fileInfo(at: URL(fileURLWithPath: sourcePath)),
              info.st_mode & S_IFMT == S_IFREG, info.st_size == fileIdentity.size,
              Int64(info.st_mtimespec.tv_sec) == fileIdentity.modificationTimeEpochSeconds else {
            return false
        }
        let ledger = PortableImportReceiptLedger(sourceRootURL: root)
        let snapshot = try ledger.load()
        if !snapshot.fingerprints.contains(PortableImportReceiptLedger.portableFingerprint(for: fileIdentity)) {
            try ledger.append(identity: fileIdentity)
        }
        return true
    }
}
