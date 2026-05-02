import Foundation

public enum JobID {
    public static func make(date: Date = Date(), uuid: UUID = UUID()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased())"
    }
}
