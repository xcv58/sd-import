import Foundation

public enum CopyStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case copied
    case skipped
    case failed

    public var databaseValue: String {
        switch self {
        case .pending:
            return "PENDING"
        case .copied:
            return "COPIED"
        case .skipped:
            return "SKIPPED"
        case .failed:
            return "FAILED"
        }
    }

    public init?(databaseValue: String) {
        switch databaseValue.uppercased() {
        case "PENDING":
            self = .pending
        case "COPIED":
            self = .copied
        case "SKIPPED":
            self = .skipped
        case "FAILED":
            self = .failed
        default:
            return nil
        }
    }
}
