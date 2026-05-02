import Foundation

public enum SDImportError: Error, Equatable, Sendable {
    case missingApplicationSupportDirectory
    case invalidLegacyState(URL)
    case invalidDatabaseValue(column: String, value: String)
    case unsupportedMediaExtension(String)
    case missingFileAttributes(URL)
    case sourceFileMissing(URL)
    case missingDestinationDirectory(Int64?)
    case copySizeMismatch(expected: Int64, actual: Int64)
    case jobNotFound(String)
    case invalidArgument(String)
    case fileSystemError(operation: String, path: String, code: Int32)
    case cancelled
}
