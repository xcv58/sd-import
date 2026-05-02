import Foundation

public enum RetentionPolicy: Hashable, Codable, Sendable {
    case days(Int)
    case forever

    public static let defaultPolicy: RetentionPolicy = .days(90)

    public var dayCount: Int? {
        switch self {
        case .days(let days):
            return days
        case .forever:
            return nil
        }
    }

    public static let supportedValues: [RetentionPolicy] = [
        .days(30),
        .days(90),
        .days(365),
        .forever
    ]
}
