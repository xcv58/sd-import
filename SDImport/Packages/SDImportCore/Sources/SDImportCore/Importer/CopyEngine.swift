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
            var reservation: ImportCopyFileIdentity?
            do {
                _ = try stageFile(
                    from: sourceURL, to: destinationURL, expectedSize: expectedSize,
                    modificationDate: modificationDate, onChunk: onChunk, shouldCancel: shouldCancel,
                    didCreate: { reservation = $0 }
                )
            } catch {
                if let reservation, let info = try? Self.fileInfo(at: destinationURL), reservation.matches(info) {
                    try? fileManager.removeItem(at: destinationURL)
                }
                throw error
            }
            return
        }

        let temporaryURL = destinationDirectory.appendingPathComponent(".sdimport-\(UUID().uuidString).part")

        do {
            _ = try stageFile(
                from: sourceURL, to: temporaryURL, expectedSize: expectedSize,
                modificationDate: modificationDate, onChunk: onChunk, shouldCancel: shouldCancel
            )
            try publishFile(
                from: temporaryURL, to: destinationURL, replacesExisting: replacesExisting
            )
            try verifyFinalCopy(at: destinationURL, expectedSize: expectedSize)
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
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
        let digest = try copyWithBoundedBuffer(
            from: source, to: staging, shouldCancel: shouldCancel, onChunk: onChunk, didCreate: didCreate
        )
        if let modificationDate {
            try fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: staging.path)
        }
        guard let info = try Self.fileInfo(at: staging), info.st_mode & S_IFMT == S_IFREG else {
            throw SDImportError.missingFileAttributes(staging)
        }
        guard info.st_size == expectedSize else {
            throw SDImportError.copySizeMismatch(expected: expectedSize, actual: info.st_size)
        }
        return StagedImportCopy(info: info, digest: digest)
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
        guard let staged = attempt.staged,
              let info = try fileInfo(at: attempt.destination),
              info.st_mode & S_IFMT == S_IFREG, staged.size == info.st_size,
              attempt.reservedDestination?.matches(info) != false else {
            return false
        }

        let descriptor = open(attempt.destinationPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SDImportError.fileSystemError(
                operation: "open published copy", path: attempt.destinationPath, code: errno
            )
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              ImportCopyFileIdentity(info).matches(opened), opened.st_size == staged.size else { return false }
        var digest = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            digest.update(data: bytes)
        }
        return Data(digest.finalize()) == staged.digest
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw SDImportError.missingFileAttributes(url)
        }
        return size.int64Value
    }

    private func verifyFinalCopy(at destinationURL: URL, expectedSize: Int64) throws {
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            throw SDImportError.fileSystemError(operation: "verify destination", path: destinationURL.path, code: ENOENT)
        }

        let finalSize = try fileSize(at: destinationURL)
        guard finalSize == expectedSize else {
            throw SDImportError.copySizeMismatch(expected: expectedSize, actual: finalSize)
        }
    }

    private func copyWithBoundedBuffer(
        from sourceURL: URL,
        to temporaryURL: URL,
        shouldCancel: () -> Bool,
        onChunk: ((Int) -> Void)?,
        didCreate: (ImportCopyFileIdentity) throws -> Void
    ) throws -> Data {
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
        try didCreate(ImportCopyFileIdentity(opened))

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

            digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: bytesRead))
            onChunk?(bytesRead)
        }
        return Data(digest.finalize())
    }
}
