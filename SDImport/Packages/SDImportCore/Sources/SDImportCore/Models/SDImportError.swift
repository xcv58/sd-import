import Foundation

public enum SDImportError: Error, Equatable, Sendable {
    case missingApplicationSupportDirectory
    case missingApplicationGroupContainer(String)
    case invalidLegacyState(URL)
    case invalidDatabaseValue(column: String, value: String)
    case unsupportedMediaExtension(String)
    case missingFileAttributes(URL)
    case sourceFileMissing(URL)
    case missingDestinationDirectory(Int64?)
    case insufficientDestinationSpace(path: String, requiredBytes: Int64, availableBytes: Int64)
    case copySizeMismatch(expected: Int64, actual: Int64)
    case jobNotFound(String)
    case invalidArgument(String)
    case fileSystemError(operation: String, path: String, code: Int32)
    case cancelled
}

extension SDImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            L10n.tr("The application support folder is unavailable.")
        case .missingApplicationGroupContainer:
            L10n.tr("The shared application folder is unavailable.")
        case .invalidLegacyState:
            L10n.tr("The previous import history could not be read.")
        case .invalidDatabaseValue:
            L10n.tr("The import database contains an invalid value.")
        case .unsupportedMediaExtension(let value):
            L10n.tr("Unsupported media extension: \(value)")
        case .missingFileAttributes(let url):
            L10n.tr("Could not read file information: \(url.path)")
        case .sourceFileMissing(let url):
            L10n.tr("Source file missing: \(url.path)")
        case .missingDestinationDirectory:
            L10n.tr("The destination folder is unavailable.")
        case .insufficientDestinationSpace(let path, let required, let available):
            L10n.tr("Not enough space in \(path). Need \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)), available \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)).")
        case .copySizeMismatch(let expected, let actual):
            L10n.tr("Copy verification failed: expected \(expected) bytes, found \(actual) bytes.")
        case .jobNotFound(let id):
            L10n.tr("Import job not found: \(id)")
        case .invalidArgument(let message):
            L10n.storedMessage(message)
        case .fileSystemError(_, let path, let code):
            L10n.tr("Could not access \(path): \(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)")
        case .cancelled:
            L10n.tr("Operation cancelled")
        }
    }
}
