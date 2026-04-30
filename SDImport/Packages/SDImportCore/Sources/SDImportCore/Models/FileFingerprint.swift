import CryptoKit
import Foundation

public struct FileFingerprint: Hashable, Codable, Sendable {
    public let size: Int64
    public let modificationDate: Date
    public let modificationDateString: String
    public let identityHint: String?
    public let value: String

    public init(
        size: Int64,
        modificationDate: Date,
        modificationDateString: String,
        identityHint: String? = nil,
        value: String
    ) {
        self.size = size
        self.modificationDate = modificationDate
        self.modificationDateString = modificationDateString
        self.identityHint = Self.normalizedIdentity(identityHint)
        self.value = value
    }

    public static func compute(
        size: Int64,
        modificationDate: Date,
        timeZone: TimeZone = .current,
        identityHint: String? = nil
    ) -> FileFingerprint {
        let mtimeString = pythonCompatibleModificationDateString(
            modificationDate,
            timeZone: timeZone
        )
        return compute(
            size: size,
            modificationDate: modificationDate,
            modificationDateString: mtimeString,
            identityHint: identityHint
        )
    }

    public static func compute(
        size: Int64,
        modificationDate: Date = Date(timeIntervalSince1970: 0),
        modificationDateString: String,
        identityHint: String? = nil
    ) -> FileFingerprint {
        let identity = normalizedIdentity(identityHint)
        let value: String
        if let identity {
            let payload = "v2|\(identity)|\(size)|\(modificationDateString)"
            let digest = SHA256.hash(data: Data(payload.utf8))
            value = "v2:" + digest.map { String(format: "%02x", $0) }.joined()
        } else {
            let payload = "\(size)|\(modificationDateString)"
            let digest = Insecure.SHA1.hash(data: Data(payload.utf8))
            value = digest.map { String(format: "%02x", $0) }.joined()
        }
        return FileFingerprint(
            size: size,
            modificationDate: modificationDate,
            modificationDateString: modificationDateString,
            identityHint: identity,
            value: value
        )
    }

    public static func pythonCompatibleModificationDateString(
        _ date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func normalizedIdentity(_ identityHint: String?) -> String? {
        guard let identityHint else {
            return nil
        }

        let normalized = identityHint
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))

        return normalized.isEmpty ? nil : normalized
    }
}
