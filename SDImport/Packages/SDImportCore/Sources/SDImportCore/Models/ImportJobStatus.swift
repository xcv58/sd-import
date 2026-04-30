import Foundation

public enum ImportJobStatus: String, Codable, CaseIterable, Sendable {
    case scanned
    case importing
    case imported
    case importedWithErrors
    case skipped
    case cancelled
    case failed

    public var databaseValue: String {
        switch self {
        case .scanned:
            return "SCANNED"
        case .importing:
            return "IMPORTING"
        case .imported:
            return "IMPORTED"
        case .importedWithErrors:
            return "IMPORTED_WITH_ERRORS"
        case .skipped:
            return "SKIPPED"
        case .cancelled:
            return "CANCELLED"
        case .failed:
            return "FAILED"
        }
    }

    public init?(databaseValue: String) {
        switch databaseValue.uppercased() {
        case "SCANNED":
            self = .scanned
        case "IMPORTING":
            self = .importing
        case "IMPORTED":
            self = .imported
        case "IMPORTED_WITH_ERRORS":
            self = .importedWithErrors
        case "SKIPPED":
            self = .skipped
        case "CANCELLED":
            self = .cancelled
        case "FAILED":
            self = .failed
        default:
            return nil
        }
    }
}
