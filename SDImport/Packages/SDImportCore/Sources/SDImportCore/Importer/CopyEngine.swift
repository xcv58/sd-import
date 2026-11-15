import CryptoKit
import Darwin
import Foundation

public struct CopyEngine {
    private let fileManager: FileManager
    private let chunkSize: Int

    public init(fileManager: FileManager = .default, chunkSize: Int = 16 * 1024 * 1024) {
        self.fileManager = fileManager
        self.chunkSize = chunkSize
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
           Self.supportsExclusiveRename(in: destinationDirectory) == false {
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
        onChunk: ((Int) -> Void)?,
        shouldCancel: () -> Bool,
        didCreate: (ImportCopyFileIdentity) throws -> Void = { _ in }
    ) throws -> StagedImportCopy {
        let verified = try copyWithBoundedBuffer(
            from: source, to: staging, expectedSize: expectedSize, modificationDate: modificationDate,
            shouldCancel: shouldCancel, onChunk: onChunk, didCreate: didCreate
        )
        guard let info = try Self.fileInfo(at: staging), verified.matches(info) else {
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

    func publishFile(from staging: URL, to destination: URL, replacesExisting: Bool = false) throws {
        if replacesExisting && fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination, withItemAt: staging, backupItemName: nil, options: [.usingNewMetadataOnly]
            )
            return
        }
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
            throw SDImportError.fileSystemError(operation: "publish copy", path: destination.path, code: code)
        }
    }

    static func fileInfo(at url: URL) throws -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw SDImportError.fileSystemError(operation: "inspect copy", path: url.path, code: code)
        }
        return info
    }

    static func publishedFileMatches(_ attempt: ImportCopyAttempt) throws -> Bool {
        guard let info = try fileInfo(at: attempt.destination),
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
        return try readDigest(at: attempt.destination, identity: ImportCopyFileIdentity(info)) == expected
    }

    static func restoreCopyDate(_ date: Date, at url: URL, identity: ImportCopyFileIdentity) throws {
        let file = try openVerifiedCopy(at: url, identity: identity)
        defer { try? file.close() }
        try setModificationDate(date, descriptor: file.fileDescriptor, path: url.path)
    }

    private static func openVerifiedCopy(at url: URL, identity: ImportCopyFileIdentity?) throws -> FileHandle {
        let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | (identity == nil ? 0 : O_NOFOLLOW)
        let descriptor = open(url.path, flags)
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

    static func readDigest(at url: URL, identity: ImportCopyFileIdentity? = nil) throws -> Data {
        let file = try openVerifiedCopy(at: url, identity: identity)
        defer { try? file.close() }
        var opened = stat()
        guard fstat(file.fileDescriptor, &opened) == 0 else { throw SDImportError.missingFileAttributes(url) }
        var digest = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            if Task.isCancelled { throw SDImportError.cancelled }
            digest.update(data: bytes)
        }
        if let identity {
            guard let current = try fileInfo(at: url), identity.matches(current),
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
        shouldCancel: () -> Bool,
        onChunk: ((Int) -> Void)?,
        didCreate: (ImportCopyFileIdentity) throws -> Void
    ) throws -> StagedImportCopy {
        if shouldCancel() { throw SDImportError.cancelled }
        let sourcePath = sourceURL.path
        let destinationPath = temporaryURL.path
        let inputFD = open(sourcePath, O_RDONLY)
        guard inputFD >= 0 else {
            throw SDImportError.fileSystemError(operation: "open source", path: sourcePath, code: errno)
        }
        defer {
            close(inputFD)
        }

        let outputFD = open(destinationPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
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
            onChunk?(bytesRead)
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
        return StagedImportCopy(info: finished, digest: Data(digest.finalize()))
    }
}
