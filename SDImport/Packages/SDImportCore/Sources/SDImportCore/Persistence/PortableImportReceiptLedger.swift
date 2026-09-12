import CryptoKit
import Darwin
import Foundation

public struct PortableFileIdentity: Hashable, Sendable {
    public let size: Int64
    public let modificationTimeEpochSeconds: Int64
    public let relativePath: String

    public init(size: Int64, modificationDate: Date, relativePath: String) {
        self.init(
            size: size,
            modificationTimeEpochSeconds: Int64(floor(modificationDate.timeIntervalSince1970)),
            relativePath: relativePath
        )
    }

    public init(size: Int64, modificationTimeEpochSeconds: Int64, relativePath: String) {
        self.size = size
        self.modificationTimeEpochSeconds = modificationTimeEpochSeconds
        self.relativePath = relativePath
    }
}

public struct PortableImportReceiptSnapshot: Sendable {
    public let fingerprints: Set<String>
    public let invalidRecordCount: Int
    let revision: PortableImportReceiptLedgerRevision?
    let advisoryLockUnavailable: Bool

    public init(fingerprints: Set<String>, invalidRecordCount: Int) {
        self.fingerprints = fingerprints
        self.invalidRecordCount = invalidRecordCount
        self.revision = nil
        self.advisoryLockUnavailable = false
    }

    init(
        fingerprints: Set<String>,
        invalidRecordCount: Int,
        revision: PortableImportReceiptLedgerRevision,
        advisoryLockUnavailable: Bool = false
    ) {
        self.fingerprints = fingerprints
        self.invalidRecordCount = invalidRecordCount
        self.revision = revision
        self.advisoryLockUnavailable = advisoryLockUnavailable
    }

    public var warning: String? {
        var warnings: [String] = []
        if invalidRecordCount > 0 {
            warnings.append(invalidRecordCount == 1
                ? L10n.tr("Ignored 1 invalid or corrupted portable import record")
                : L10n.tr("Ignored \(invalidRecordCount) invalid or corrupted portable import records"))
        }
        if advisoryLockUnavailable {
            warnings.append(L10n.tr("Portable import history cannot coordinate with other apps because this source does not support file locking"))
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: ". ")
    }
}

enum PortableImportReceiptLedgerRevision: Equatable, Sendable {
    case missing
    case file(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64
    )
}

struct PortableImportReceiptLedgerAppendResult: Sendable {
    let previousRevision: PortableImportReceiptLedgerRevision
    let revision: PortableImportReceiptLedgerRevision
    let advisoryLockUnavailable: Bool

    var warning: String? {
        advisoryLockUnavailable
            ? L10n.tr("Portable import history cannot coordinate with other apps because this source does not support file locking")
            : nil
    }
}

public enum PortableImportReceiptLedgerError: LocalizedError, Sendable {
    case sourceUnavailable(String)
    case sourceNotDirectory(String)
    case ledgerTooLarge(Int64)
    case recordTooLarge(Int)
    case invalidReceipt
    case ledgerIsNotAFile(String)
    case unsafeLedgerPath(String)

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let path):
            return L10n.tr("The source is no longer available at \(path)")
        case .sourceNotDirectory(let path):
            return L10n.tr("The source is not a directory at \(path)")
        case .ledgerTooLarge(let size):
            return L10n.tr("The portable import ledger is too large (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
        case .recordTooLarge(let size):
            return L10n.tr("The portable import receipt is too large (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        case .invalidReceipt:
            return L10n.tr("The portable import receipt contains invalid or inconsistent file identity data")
        case .ledgerIsNotAFile(let path):
            return L10n.tr("The portable import ledger is not a regular file at \(path)")
        case .unsafeLedgerPath(let path):
            return L10n.tr("The portable import ledger path is unsafe at \(path)")
        }
    }
}

typealias PortableFileLockOperation = @Sendable (
    Int32,
    Int32,
    UnsafeMutablePointer<Darwin.flock>
) -> Int32

private final class PortableImportReceiptProcessLockRegistry: @unchecked Sendable {
    static let shared = PortableImportReceiptProcessLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for sourceRootPath: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[sourceRootPath] {
            return existing
        }
        let created = NSLock()
        locks[sourceRootPath] = created
        return created
    }
}

public struct PortableImportReceiptLedger: Sendable {
    public static let directoryName = ".sd-import"
    public static let fileName = "imported-v1.jsonl"

    private static let schemaVersion = 1
    private static let fingerprintAlgorithm = "sdimport-portable-v2"
    private static let maximumLedgerBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumRecordBytes = 16 * 1_024
    private static let maximumRelativePathLength = 4_096
    private static let readBufferSize = 64 * 1_024

    public let sourceRootURL: URL
    private let processLock: NSLock
    private let fileLockOperation: PortableFileLockOperation

    public init(sourceRootURL: URL) {
        let standardizedSourceRootURL = sourceRootURL.standardizedFileURL
        self.sourceRootURL = standardizedSourceRootURL
        self.processLock = PortableImportReceiptProcessLockRegistry.shared.lock(
            for: standardizedSourceRootURL.path
        )
        self.fileLockOperation = { descriptor, command, fileLock in
            Darwin.fcntl(descriptor, command, fileLock)
        }
    }

    init(
        sourceRootURL: URL,
        fileLockOperation: @escaping PortableFileLockOperation
    ) {
        let standardizedSourceRootURL = sourceRootURL.standardizedFileURL
        self.sourceRootURL = standardizedSourceRootURL
        self.processLock = PortableImportReceiptProcessLockRegistry.shared.lock(
            for: standardizedSourceRootURL.path
        )
        self.fileLockOperation = fileLockOperation
    }

    public var ledgerURL: URL {
        sourceRootURL
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public static func portableFingerprint(for identity: PortableFileIdentity) -> String {
        portableFingerprint(
            size: identity.size,
            modificationTimeEpochSeconds: identity.modificationTimeEpochSeconds,
            relativePath: identity.relativePath
        )
    }

    public func load() throws -> PortableImportReceiptSnapshot {
        guard let snapshot = try load(ifChangedSince: nil) else {
            preconditionFailure("A forced portable receipt load must return a snapshot")
        }
        return snapshot
    }

    func load(
        ifChangedSince previousRevision: PortableImportReceiptLedgerRevision?
    ) throws -> PortableImportReceiptSnapshot? {
        processLock.lock()
        defer { processLock.unlock() }

        let sourceDescriptor = try openSourceDirectory()
        defer { Darwin.close(sourceDescriptor) }

        guard let ledgerDescriptor = try openLedgerForReading(sourceDescriptor: sourceDescriptor) else {
            let revision = PortableImportReceiptLedgerRevision.missing
            guard revision != previousRevision else {
                return nil
            }
            return PortableImportReceiptSnapshot(
                fingerprints: [],
                invalidRecordCount: 0,
                revision: revision
            )
        }
        defer { Darwin.close(ledgerDescriptor) }

        let advisoryLockAcquired = try lock(ledgerDescriptor, type: F_RDLCK)
        defer {
            if advisoryLockAcquired {
                unlock(ledgerDescriptor)
            }
        }

        let metadata = try regularFileMetadata(descriptor: ledgerDescriptor)
        guard metadata.revision != previousRevision else {
            return nil
        }
        guard metadata.size <= Self.maximumLedgerBytes else {
            throw PortableImportReceiptLedgerError.ledgerTooLarge(metadata.size)
        }
        let data = try readAll(descriptor: ledgerDescriptor, expectedSize: metadata.size)

        let decoder = JSONDecoder()
        var fingerprints: Set<String> = []
        var invalidRecordCount = 0

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let lineData = Data(line)
            guard lineData.count <= Self.maximumRecordBytes else {
                invalidRecordCount += 1
                continue
            }
            guard
                let receipt = try? decoder.decode(Receipt.self, from: lineData),
                Self.isValid(receipt)
            else {
                invalidRecordCount += 1
                continue
            }
            fingerprints.insert(receipt.fingerprint)
        }

        return PortableImportReceiptSnapshot(
            fingerprints: fingerprints,
            invalidRecordCount: invalidRecordCount,
            revision: metadata.revision,
            advisoryLockUnavailable: !advisoryLockAcquired
        )
    }

    public func append(
        identity: PortableFileIdentity,
        importedAt: Date = Date()
    ) throws {
        _ = try appendReturningRevision(identity: identity, importedAt: importedAt)
    }

    public func append(
        identities: [PortableFileIdentity],
        importedAt: Date = Date()
    ) throws {
        guard !identities.isEmpty else {
            return
        }
        _ = try appendReturningRevision(identities: identities, importedAt: importedAt)
    }

    func appendReturningRevision(
        identity: PortableFileIdentity,
        importedAt: Date = Date()
    ) throws -> PortableImportReceiptLedgerAppendResult {
        try appendReturningRevision(identities: [identity], importedAt: importedAt)
    }

    func appendReturningRevision(
        identities: [PortableFileIdentity],
        importedAt: Date = Date()
    ) throws -> PortableImportReceiptLedgerAppendResult {
        precondition(!identities.isEmpty, "A portable receipt append requires at least one identity")

        let records = try identities.map { identity in
            try Self.encodedRecord(identity: identity, importedAt: importedAt)
        }

        processLock.lock()
        defer { processLock.unlock() }

        let sourceDescriptor = try openSourceDirectory()
        defer { Darwin.close(sourceDescriptor) }
        let directoryDescriptor = try openOrCreateLedgerDirectory(sourceDescriptor: sourceDescriptor)
        defer { Darwin.close(directoryDescriptor) }
        let openedLedger = try openLedgerForAppending(directoryDescriptor: directoryDescriptor)
        let ledgerDescriptor = openedLedger.descriptor
        defer { Darwin.close(ledgerDescriptor) }

        let advisoryLockAcquired = try lock(ledgerDescriptor, type: F_WRLCK)
        defer {
            if advisoryLockAcquired {
                unlock(ledgerDescriptor)
            }
        }

        let previousMetadata = try regularFileMetadata(descriptor: ledgerDescriptor)
        let currentSize = previousMetadata.size
        guard currentSize <= Self.maximumLedgerBytes else {
            throw PortableImportReceiptLedgerError.ledgerTooLarge(currentSize)
        }

        var appendData = Data()
        if currentSize > 0, try lastByte(descriptor: ledgerDescriptor, size: currentSize) != 0x0A {
            appendData.append(0x0A)
        }
        for record in records {
            appendData.append(record)
        }

        let finalSize = currentSize + Int64(appendData.count)
        guard finalSize <= Self.maximumLedgerBytes else {
            throw PortableImportReceiptLedgerError.ledgerTooLarge(finalSize)
        }
        try writeAll(appendData, descriptor: ledgerDescriptor)
        guard Darwin.fsync(ledgerDescriptor) == 0 else {
            throw Self.posixError(path: ledgerURL.path)
        }
        if openedLedger.created, Darwin.fsync(directoryDescriptor) != 0 {
            throw Self.posixError(path: ledgerURL.deletingLastPathComponent().path)
        }
        return PortableImportReceiptLedgerAppendResult(
            previousRevision: previousMetadata.revision,
            revision: try regularFileMetadata(descriptor: ledgerDescriptor).revision,
            advisoryLockUnavailable: !advisoryLockAcquired
        )
    }

    private func openSourceDirectory() throws -> Int32 {
        let descriptor = Darwin.open(
            sourceRootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT:
                throw PortableImportReceiptLedgerError.sourceUnavailable(sourceRootURL.path)
            case ENOTDIR:
                throw PortableImportReceiptLedgerError.sourceNotDirectory(sourceRootURL.path)
            case ELOOP:
                throw PortableImportReceiptLedgerError.unsafeLedgerPath(sourceRootURL.path)
            default:
                throw Self.posixError(code: code, path: sourceRootURL.path)
            }
        }
        return descriptor
    }

    private func openLedgerForReading(sourceDescriptor: Int32) throws -> Int32? {
        let directoryDescriptor = Darwin.openat(
            sourceDescriptor,
            Self.directoryName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            if code == ELOOP || code == ENOTDIR {
                throw PortableImportReceiptLedgerError.unsafeLedgerPath(
                    ledgerURL.deletingLastPathComponent().path
                )
            }
            throw Self.posixError(code: code, path: ledgerURL.deletingLastPathComponent().path)
        }
        defer { Darwin.close(directoryDescriptor) }

        let descriptor = Darwin.openat(
            directoryDescriptor,
            Self.fileName,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            if code == ELOOP {
                throw PortableImportReceiptLedgerError.unsafeLedgerPath(ledgerURL.path)
            }
            throw Self.posixError(code: code, path: ledgerURL.path)
        }
        do {
            _ = try regularFileSize(descriptor: descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openOrCreateLedgerDirectory(sourceDescriptor: Int32) throws -> Int32 {
        if Darwin.mkdirat(sourceDescriptor, Self.directoryName, 0o700) != 0, errno != EEXIST {
            throw Self.posixError(path: ledgerURL.deletingLastPathComponent().path)
        }
        let descriptor = Darwin.openat(
            sourceDescriptor,
            Self.directoryName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw PortableImportReceiptLedgerError.unsafeLedgerPath(
                    ledgerURL.deletingLastPathComponent().path
                )
            }
            throw Self.posixError(code: code, path: ledgerURL.deletingLastPathComponent().path)
        }
        return descriptor
    }

    private func openLedgerForAppending(directoryDescriptor: Int32) throws -> OpenedLedger {
        var descriptor = Darwin.openat(
            directoryDescriptor,
            Self.fileName,
            O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        if descriptor >= 0 {
            return OpenedLedger(descriptor: descriptor, created: true)
        }

        let creationError = errno
        guard creationError == EEXIST else {
            if creationError == ELOOP {
                throw PortableImportReceiptLedgerError.unsafeLedgerPath(ledgerURL.path)
            }
            if creationError == EISDIR {
                throw PortableImportReceiptLedgerError.ledgerIsNotAFile(ledgerURL.path)
            }
            throw Self.posixError(code: creationError, path: ledgerURL.path)
        }

        descriptor = Darwin.openat(
            directoryDescriptor,
            Self.fileName,
            O_RDWR | O_APPEND | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw PortableImportReceiptLedgerError.unsafeLedgerPath(ledgerURL.path)
            }
            if code == EISDIR {
                throw PortableImportReceiptLedgerError.ledgerIsNotAFile(ledgerURL.path)
            }
            throw Self.posixError(code: code, path: ledgerURL.path)
        }
        do {
            _ = try regularFileSize(descriptor: descriptor)
            return OpenedLedger(descriptor: descriptor, created: false)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func regularFileSize(descriptor: Int32) throws -> Int64 {
        try regularFileMetadata(descriptor: descriptor).size
    }

    private func regularFileMetadata(descriptor: Int32) throws -> RegularFileMetadata {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw Self.posixError(path: ledgerURL.path)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw PortableImportReceiptLedgerError.ledgerIsNotAFile(ledgerURL.path)
        }
        let size = Int64(status.st_size)
        return RegularFileMetadata(
            size: size,
            revision: .file(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino),
                size: size,
                modificationSeconds: Int64(status.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
            )
        )
    }

    private func lock(_ descriptor: Int32, type: Int32) throws -> Bool {
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(type)
        fileLock.l_whence = Int16(SEEK_SET)
        while fileLockOperation(descriptor, F_SETLKW, &fileLock) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            if code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL {
                return false
            }
            throw Self.posixError(code: code, path: ledgerURL.path)
        }
        return true
    }

    private func unlock(_ descriptor: Int32) {
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        _ = fileLockOperation(descriptor, F_SETLK, &fileLock)
    }

    private func readAll(descriptor: Int32, expectedSize: Int64) throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(expectedSize))
        var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw Self.posixError(path: ledgerURL.path)
            }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumLedgerBytes else {
                throw PortableImportReceiptLedgerError.ledgerTooLarge(Int64(data.count))
            }
        }
    }

    private func lastByte(descriptor: Int32, size: Int64) throws -> UInt8 {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.pread(descriptor, &byte, 1, off_t(size - 1))
            if count == 1 {
                return byte
            }
            if count < 0, errno == EINTR {
                continue
            }
            throw Self.posixError(path: ledgerURL.path)
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw Self.posixError(path: ledgerURL.path)
                }
                guard count > 0 else {
                    throw Self.posixError(code: EIO, path: ledgerURL.path)
                }
                written += count
            }
        }
    }

    private static func posixError(code: Int32 = errno, path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private static func isValid(_ receipt: Receipt) -> Bool {
        guard
            receipt.schemaVersion == schemaVersion,
            receipt.fingerprintAlgorithm == fingerprintAlgorithm,
            receipt.size >= 0,
            isValidRelativePath(receipt.relativePath),
            DateCoding.date(from: receipt.importedAt) != nil,
            receipt.checksum.count == 64,
            receipt.checksum.allSatisfy({ $0.isHexDigit }),
            (try? checksum(for: receipt)) == receipt.checksum
        else {
            return false
        }

        let expected = portableFingerprint(
            size: receipt.size,
            modificationTimeEpochSeconds: receipt.modificationTimeEpochSeconds,
            relativePath: receipt.relativePath
        )
        return receipt.fingerprint == expected
    }

    private static func isValidRelativePath(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            path.count <= maximumRelativePathLength,
            !path.hasPrefix("/"),
            !path.hasPrefix("\\")
        else {
            return false
        }

        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func portableFingerprint(
        size: Int64,
        modificationTimeEpochSeconds: Int64,
        relativePath: String
    ) -> String {
        let canonicalPath = relativePath.precomposedStringWithCanonicalMapping
        let payload = "p2|\(canonicalPath)|\(size)|\(modificationTimeEpochSeconds)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return "p2:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodedRecord(
        identity: PortableFileIdentity,
        importedAt: Date
    ) throws -> Data {
        var receipt = Receipt(
            schemaVersion: schemaVersion,
            fingerprintAlgorithm: fingerprintAlgorithm,
            fingerprint: portableFingerprint(for: identity),
            size: identity.size,
            modificationTimeEpochSeconds: identity.modificationTimeEpochSeconds,
            relativePath: identity.relativePath,
            importedAt: DateCoding.string(from: importedAt),
            checksum: ""
        )
        receipt.checksum = try checksum(for: receipt)
        guard isValid(receipt) else {
            throw PortableImportReceiptLedgerError.invalidReceipt
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var recordData = try encoder.encode(receipt)
        recordData.append(0x0A)
        guard recordData.count <= maximumRecordBytes else {
            throw PortableImportReceiptLedgerError.recordTooLarge(recordData.count)
        }
        return recordData
    }

    private static func checksum(for receipt: Receipt) throws -> String {
        let payload = ReceiptPayload(
            schemaVersion: receipt.schemaVersion,
            fingerprintAlgorithm: receipt.fingerprintAlgorithm,
            fingerprint: receipt.fingerprint,
            size: receipt.size,
            modificationTimeEpochSeconds: receipt.modificationTimeEpochSeconds,
            relativePath: receipt.relativePath,
            importedAt: receipt.importedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct Receipt: Codable {
    let schemaVersion: Int
    let fingerprintAlgorithm: String
    let fingerprint: String
    let size: Int64
    let modificationTimeEpochSeconds: Int64
    let relativePath: String
    let importedAt: String
    var checksum: String
}

private struct ReceiptPayload: Encodable {
    let schemaVersion: Int
    let fingerprintAlgorithm: String
    let fingerprint: String
    let size: Int64
    let modificationTimeEpochSeconds: Int64
    let relativePath: String
    let importedAt: String
}

private struct RegularFileMetadata {
    let size: Int64
    let revision: PortableImportReceiptLedgerRevision
}

private struct OpenedLedger {
    let descriptor: Int32
    let created: Bool
}
