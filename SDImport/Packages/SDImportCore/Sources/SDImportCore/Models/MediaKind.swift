import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case unsupported
}
