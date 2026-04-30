import Foundation

public enum FileDecision: String, Codable, CaseIterable, Sendable {
    case new
    case known
    case conflict
    case unsupported

    public var databaseValue: String {
        switch self {
        case .new:
            return "NEW"
        case .known:
            return "KNOWN"
        case .conflict:
            return "CONFLICT"
        case .unsupported:
            return "UNSUPPORTED"
        }
    }

    public init?(databaseValue: String) {
        switch databaseValue.uppercased() {
        case "NEW":
            self = .new
        case "KNOWN":
            self = .known
        case "CONFLICT":
            self = .conflict
        case "UNSUPPORTED":
            self = .unsupported
        default:
            return nil
        }
    }
}
