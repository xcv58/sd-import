import Foundation

enum DateCoding {
    static func optionalString(from date: Date?) -> String? {
        guard let date else {
            return nil
        }
        return string(from: date)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
