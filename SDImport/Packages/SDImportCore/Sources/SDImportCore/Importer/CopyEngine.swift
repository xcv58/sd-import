import CryptoKit
import Darwin
import Foundation

/// Keeps source opens anchored to the directory that was approved for this import.
public final class CopySourceDirectory {
    private let descriptor: Int32
    private let components: [String]
    private let root: URL
    private let device: dev_t
    private let inode: ino_t

    public init(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let error = errno
            if error == ENOENT || error == ENODEV || error == ESTALE || error == ENOTDIR {
                throw SDImportError.sourceVolumeUnavailable
            }
            throw SDImportError.fileSystemError(operation: "open source directory", path: url.path, code: error)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = errno
            close(descriptor)
            throw SDImportError.fileSystemError(operation: "inspect source directory", path: url.path, code: error)
        }
        self.descriptor = descriptor
        root = url.standardizedFileURL
        components = url.standardizedFileURL.pathComponents
        device = info.st_dev
        inode = info.st_ino
    }

    deinit { close(descriptor) }

    fileprivate func verify() throws {
        var current = stat()
        guard stat(root.path, &current) == 0, current.st_dev == device, current.st_ino == inode else {
            throw SDImportError.sourceVolumeUnavailable
        }
    }

    fileprivate func openFile(at url: URL) throws -> FileHandle {
        try verify()
        let path = url.standardizedFileURL.pathComponents
        guard path.starts(with: components), path.count > components.count else {
            throw SDImportError.missingFileAttributes(url)
        }
        let relativePath = path.dropFirst(components.count).joined(separator: "/")
        let file = openat(descriptor, relativePath, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard file >= 0 else {
            throw SDImportError.fileSystemError(operation: "open source", path: url.path, code: errno)
        }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(file)
            throw SDImportError.missingFileAttributes(url)
        }
        guard info.st_dev == device else {
            close(file)
            throw SDImportError.sourceVolumeUnavailable
        }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }
}

public struct CopyEngine {
    private let fileManager: FileManager
    private let chunkSize: Int
    private let sourceDirectory: CopySourceDirectory?
    let canRenameExclusively: (URL) -> Bool?

    public init(
        fileManager: FileManager = .default,
        chunkSize: Int = 16 * 1024 * 1024,
        sourceDirectory: CopySourceDirectory? = nil
    ) {
        self.init(fileManager: fileManager, chunkSize: chunkSize, sourceDirectory: sourceDirectory,
                  canRenameExclusively: Self.supportsExclusiveRename(in:))
    }

    init(
        fileManager: FileManager = .default,
        chunkSize: Int = 16 * 1024 * 1024,
        sourceDirectory: CopySourceDirectory? = nil,
        canRenameExclusively: @escaping (URL) -> Bool?
    ) {
        self.fileManager = fileManager
        self.chunkSize = chunkSize
        self.sourceDirectory = sourceDirectory
        self.canRenameExclusively = canRenameExclusively
    }

    public func copyFile(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedSize: Int64,
        modificationDate: Date?,
        replacesExisting: Bool = true,
        onChunk: ((Int) -> Void)? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws {
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        if !replacesExisting || !fileManager.fileExists(atPath: destinationURL.path),
           canRenameExclusively(destinationDirectory) == false {
            let staged = try stageFile(
                from: sourceURL, to: destinationURL, expectedSize: expectedSize,
                modificationDate: modificationDate, onChunk: onChunk, shouldCancel: shouldCancel
            )
            guard try Self.readDigest(at: destinationURL, identity: staged.identity) == staged.digest else {
                throw SDImportError.reviewedDestinationChanged
            }
            return
        }

        let temporaryURL = destinationDirectory.appendingPathComponent(".sdimport-\(UUID().uuidString).part")
        var stageIdentity: ImportCopyFileIdentity?
        do {
            let staged = try stageFile(
                from: sourceURL, to: temporaryURL, expectedSize: expectedSize,
                modificationDate: modificationDate, onChunk: onChunk, shouldCancel: shouldCancel,
                didCreate: { stageIdentity = $0 }
            )
            try publishFile(
                from: temporaryURL, to: destinationURL, replacesExisting: replacesExisting
            )
            guard let info = try Self.fileInfo(at: destinationURL), staged.matches(info) else {
                throw SDImportError.reviewedDestinationChanged
            }
        } catch {
            if let stageIdentity, let info = try? Self.fileInfo(at: temporaryURL), stageIdentity.matches(info) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    func stageFile(
        from source: URL,
        to staging: URL,
        expectedSize: Int64,
        modificationDate: Date?,
        expectedSourceEpoch: Int64? = nil,
        reviewedSource: ReviewedFileIdentity? = nil,
        directoryFD: Int32 = AT_FDCWD,
        onChunk: ((Int) -> Void)?,
        shouldCancel: () -> Bool,
        didCreate: (ImportCopyFileIdentity) throws -> Void = { _ in },
        didInterrupt: ((StagedImportCopy) -> Void)? = nil
    ) throws -> StagedImportCopy {
        let verified = try copyWithBoundedBuffer(
            from: source, to: staging, expectedSize: expectedSize, modificationDate: modificationDate,
            expectedSourceEpoch: expectedSourceEpoch, reviewedSource: reviewedSource, directoryFD: directoryFD,
            shouldCancel: shouldCancel, onChunk: onChunk, didCreate: didCreate, didInterrupt: didInterrupt
        )
        guard let info = try Self.fileInfo(at: staging, directoryFD: directoryFD), verified.matches(info) else {
            didInterrupt?(verified)
            throw SDImportError.reviewedDestinationChanged
        }
        return verified
    }

    static func supportsExclusiveRename(in directory: URL) -> Bool? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES)
        // getattrlist returns the byte count followed by four capability words and four validity words.
        var result = [UInt32](repeating: 0, count: 9)
        let read = result.withUnsafeMutableBytes {
            getattrlist(directory.path, &attributes, $0.baseAddress, $0.count, 0)
        }
        guard read == 0, result[0] >= 36 else { return nil }
        let index = Int(VOL_CAPABILITIES_INTERFACES)
        let bit = UInt32(VOL_CAP_INT_RENAME_EXCL)
        guard result[5 + index] & bit != 0 else { return nil }
        return result[1 + index] & bit != 0
    }

    func publishFile(
        from staging: URL, to destination: URL, replacesExisting: Bool = false, directoryFD: Int32 = AT_FDCWD
    ) throws {
        if replacesExisting && fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination, withItemAt: staging, backupItemName: nil, options: [.usingNewMetadataOnly]
            )
            return
        }
        let stagePath = Self.copyPath(staging, directoryFD: directoryFD)
        let finalPath = Self.copyPath(destination, directoryFD: directoryFD)
        guard renameatx_np(directoryFD, stagePath, directoryFD, finalPath, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
            throw SDImportError.fileSystemError(operation: "publish copy", path: destination.path, code: code)
        }
    }

    private static func copyPath(_ url: URL, directoryFD: Int32) -> String {
        directoryFD == AT_FDCWD ? url.path : url.lastPathComponent
    }

    static func fileInfo(at url: URL, directoryFD: Int32 = AT_FDCWD) throws -> stat? {
        var info = stat()
        guard fstatat(directoryFD, copyPath(url, directoryFD: directoryFD), &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw SDImportError.fileSystemError(operation: "inspect copy", path: url.path, code: code)
        }
        return info
    }

    static func publishedFileMatches(
        _ attempt: ImportCopyAttempt,
        directoryFD: Int32 = AT_FDCWD,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) throws -> Bool {
        guard let info = try fileInfo(at: attempt.destination, directoryFD: directoryFD),
              info.st_size == attempt.fingerprint.size else {
            return false
        }

        let expected: Data
        if let staged = attempt.staged, staged.matches(info) {
            expected = staged.digest
        } else if let reservation = attempt.reservedDestination, reservation.matchesInode(info),
                  let digest = attempt.directCopyDigest {
            expected = digest
        } else {
            return false
        }
        return try readDigest(at: attempt.destination, identity: ImportCopyFileIdentity(info),
                              directoryFD: directoryFD, shouldCancel: shouldCancel) == expected
    }

    static func restoreCopyDate(_ date: Date, at url: URL, identity: ImportCopyFileIdentity) throws {
        let file = try openVerifiedCopy(at: url, identity: identity)
        defer { try? file.close() }
        try setModificationDate(date, descriptor: file.fileDescriptor, path: url.path)
    }

    private static func openVerifiedCopy(
        at url: URL, identity: ImportCopyFileIdentity?, directoryFD: Int32 = AT_FDCWD
    ) throws -> FileHandle {
        let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | (identity == nil ? 0 : O_NOFOLLOW)
        let descriptor = openat(directoryFD, copyPath(url, directoryFD: directoryFD), flags)
        guard descriptor >= 0 else {
            throw SDImportError.fileSystemError(operation: "open copy for verification", path: url.path, code: errno)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              identity?.matches(info) != false else {
            close(descriptor)
            throw SDImportError.missingFileAttributes(url)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func setModificationDate(_ date: Date, descriptor: Int32, path: String) throws {
        let interval = date.timeIntervalSince1970
        let seconds = floor(interval)
        let times = [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: Int(seconds), tv_nsec: Int((interval - seconds) * 1_000_000_000))
        ]
        guard futimens(descriptor, times) == 0 else {
            throw SDImportError.fileSystemError(operation: "set copy date", path: path, code: errno)
        }
    }

    private static func unchangedFileContents(_ initial: stat, _ current: stat) -> Bool {
        initial.st_size == current.st_size
            && initial.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec
            && initial.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec
    }

    static func readDigest(
        at url: URL, identity: ImportCopyFileIdentity? = nil, directoryFD: Int32 = AT_FDCWD,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        let file = try openVerifiedCopy(at: url, identity: identity, directoryFD: directoryFD)
        return try readDigest(from: file, at: url, identity: identity, directoryFD: directoryFD,
                              shouldCancel: shouldCancel)
    }

    func readSourceDigest(at url: URL) throws -> Data {
        guard let sourceDirectory else { return try Self.readDigest(at: url) }
        let file = try sourceDirectory.openFile(at: url)
        return try Self.readDigest(from: file, at: url, identity: nil)
    }

    func verifySourceDirectory() throws {
        try sourceDirectory?.verify()
    }

    private static func readDigest(
        from file: FileHandle, at url: URL, identity: ImportCopyFileIdentity?, directoryFD: Int32 = AT_FDCWD,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        defer { try? file.close() }
        var opened = stat()
        guard fstat(file.fileDescriptor, &opened) == 0 else { throw SDImportError.missingFileAttributes(url) }
        var digest = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            if shouldCancel() { throw SDImportError.cancelled }
            digest.update(data: bytes)
        }
        if let identity {
            guard let current = try fileInfo(at: url, directoryFD: directoryFD), identity.matches(current),
                  unchangedFileContents(opened, current) else {
                throw SDImportError.reviewedDestinationChanged
            }
        }
        return Data(digest.finalize())
    }

    private func copyWithBoundedBuffer(
        from sourceURL: URL,
        to temporaryURL: URL,
        expectedSize: Int64,
        modificationDate: Date?,
        expectedSourceEpoch: Int64?,
        reviewedSource: ReviewedFileIdentity?,
        directoryFD: Int32,
        shouldCancel: () -> Bool,
        onChunk: ((Int) -> Void)?,
        didCreate: (ImportCopyFileIdentity) throws -> Void,
        didInterrupt: ((StagedImportCopy) -> Void)?
    ) throws -> StagedImportCopy {
        if shouldCancel() { throw SDImportError.cancelled }
        let sourcePath = sourceURL.path
        let destinationPath = temporaryURL.path
        let inputFile = try sourceDirectory?.openFile(at: sourceURL)
        let inputFD = inputFile?.fileDescriptor ?? open(sourcePath, O_RDONLY)
        guard inputFD >= 0 else {
            throw SDImportError.fileSystemError(operation: "open source", path: sourcePath, code: errno)
        }
        defer {
            if let inputFile {
                try? inputFile.close()
            } else {
                close(inputFD)
            }
        }

        func reviewedSourceInfo() throws -> stat? {
            guard expectedSourceEpoch != nil || reviewedSource != nil else { return nil }
            var source = stat()
            guard fstat(inputFD, &source) == 0, source.st_size == expectedSize,
                  expectedSourceEpoch == nil || Int64(source.st_mtimespec.tv_sec) == expectedSourceEpoch,
                  reviewedSource?.matches(source) != false else {
                throw SDImportError.reviewedSourceChanged
            }
            return source
        }
        let initialSource = try reviewedSourceInfo()
        let outputFD = openat(
            directoryFD, Self.copyPath(temporaryURL, directoryFD: directoryFD),
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard outputFD >= 0 else {
            let code = errno
            if code == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destinationPath])
            }
            throw SDImportError.fileSystemError(operation: "open destination", path: destinationPath, code: code)
        }
        defer {
            close(outputFD)
        }

        var opened = stat()
        guard fstat(outputFD, &opened) == 0 else {
            throw SDImportError.fileSystemError(operation: "inspect new copy", path: destinationPath, code: errno)
        }
        let initialIdentity = ImportCopyFileIdentity(opened)
        try didCreate(initialIdentity)
        var hasAllocatedData = false

        let boundedChunkSize = max(64 * 1024, min(chunkSize, 1024 * 1024))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: boundedChunkSize, alignment: MemoryLayout<UInt8>.alignment)
        defer {
            buffer.deallocate()
        }

        var digest = SHA256()
        var bytesWritten: Int64 = 0
        var finishedWriting = false
        defer {
            if let didInterrupt, !finishedWriting {
                var current = stat()
                if fstat(outputFD, &current) == 0, current.st_size == bytesWritten {
                    didInterrupt(StagedImportCopy(info: current, digest: Data(digest.finalize())))
                }
            }
        }
        while true {
            if shouldCancel() {
                throw SDImportError.cancelled
            }

            let bytesRead = read(inputFD, buffer, boundedChunkSize)
            if bytesRead == 0 {
                break
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw SDImportError.fileSystemError(operation: "read", path: sourcePath, code: errno)
            }

            var written = 0
            while written < bytesRead {
                let bytesWritten = write(outputFD, buffer.advanced(by: written), bytesRead - written)
                if bytesWritten < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SDImportError.fileSystemError(operation: "write", path: destinationPath, code: errno)
                }
                written += bytesWritten
            }

            if !hasAllocatedData {
                var allocated = stat()
                if fstat(outputFD, &allocated) == 0, !initialIdentity.matches(allocated) {
                    try didCreate(ImportCopyFileIdentity(allocated))
                }
                hasAllocatedData = true
            }
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: bytesRead))
            bytesWritten += Int64(bytesRead)
            onChunk?(bytesRead)
        }
        if let initialSource, let currentSource = try reviewedSourceInfo(),
           !Self.unchangedFileContents(initialSource, currentSource) {
            throw SDImportError.reviewedSourceChanged
        }
        if let modificationDate {
            try Self.setModificationDate(modificationDate, descriptor: outputFD, path: destinationPath)
        }
        var finished = stat()
        guard fstat(outputFD, &finished) == 0 else {
            throw SDImportError.fileSystemError(operation: "verify new copy", path: destinationPath, code: errno)
        }
        guard finished.st_size == expectedSize else {
            throw SDImportError.copySizeMismatch(expected: expectedSize, actual: finished.st_size)
        }
        finishedWriting = true
        return StagedImportCopy(info: finished, digest: Data(digest.finalize()))
    }
}
