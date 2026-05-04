import Foundation

enum DateCoding {
    private static let formatterKey = "SDImport.DateCoding.iso8601Formatter"

    static func optionalString(from date: Date?) -> String? {
        guard let date else {
            return nil
        }
        return string(from: date)
    }

    static func string(from date: Date) -> String {
        return formatter.string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else {
            return nil
        }
        return formatter.date(from: string)
    }

    private static var formatter: ISO8601DateFormatter {
        if let formatter = Thread.current.threadDictionary[formatterKey] as? ISO8601DateFormatter {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        Thread.current.threadDictionary[formatterKey] = formatter
        return formatter
    }
}
