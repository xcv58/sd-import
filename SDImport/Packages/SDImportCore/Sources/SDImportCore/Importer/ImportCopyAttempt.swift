import Darwin
import Foundation

struct ImportCopyAttempt: Codable {
    let id: UUID
    let fileID: Int64
    let jobID: String
    let sourcePath: String
    let destinationPath: String
    let fingerprint: FileFingerprint
    var staged: StagedImportCopy?
    var reservedDestination: ImportCopyFileIdentity?

    var destination: URL { URL(fileURLWithPath: destinationPath) }

    var staging: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".sdimport-\(id.uuidString).part")
    }

    // A missing file can be interpreted only while its parent is available.
    func destinationIsAccessible() -> Bool {
        var info = stat()
        return stat(destination.deletingLastPathComponent().path, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
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

    func matches(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG
            && inode == info.st_ino
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
