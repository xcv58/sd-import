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
        onChunk: ((Int) -> Void)? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws {
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let temporaryURL = URL(fileURLWithPath: destinationURL.path + ".part")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        do {
            try copyWithBoundedBuffer(
                from: sourceURL,
                to: temporaryURL,
                shouldCancel: shouldCancel,
                onChunk: onChunk
            )

            let copiedSize = try fileSize(at: temporaryURL)
            guard copiedSize == expectedSize else {
                throw SDImportError.copySizeMismatch(expected: expectedSize, actual: copiedSize)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)

            if let modificationDate {
                try fileManager.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: destinationURL.path
                )
            }
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw SDImportError.missingFileAttributes(url)
        }
        return size.int64Value
    }

    private func copyWithBoundedBuffer(
        from sourceURL: URL,
        to temporaryURL: URL,
        shouldCancel: () -> Bool,
        onChunk: ((Int) -> Void)?
    ) throws {
        let sourcePath = sourceURL.path
        let destinationPath = temporaryURL.path
        let inputFD = open(sourcePath, O_RDONLY)
        guard inputFD >= 0 else {
            throw SDImportError.fileSystemError(operation: "open source", path: sourcePath, code: errno)
        }
        defer {
            close(inputFD)
        }

        let outputFD = open(destinationPath, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard outputFD >= 0 else {
            throw SDImportError.fileSystemError(operation: "open destination", path: destinationPath, code: errno)
        }
        defer {
            close(outputFD)
        }

        let boundedChunkSize = max(64 * 1024, min(chunkSize, 1024 * 1024))
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: boundedChunkSize, alignment: MemoryLayout<UInt8>.alignment)
        defer {
            buffer.deallocate()
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

            onChunk?(bytesRead)
        }
    }
}
