import Foundation

public enum PathValidationPurpose: String, Codable, Sendable {
    case source
    case destination
}

public enum PathValidationStatus: Equatable, Sendable {
    case empty
    case missing
    case notDirectory
    case unreadable
    case unwritable
    case ready

    public var isUsable: Bool {
        self == .ready
    }

    public func message(for purpose: PathValidationPurpose) -> String {
        switch self {
        case .empty:
            return purpose == .source ? "Choose a card or source folder" : "Choose a destination folder"
        case .missing:
            return purpose == .source ? "Card is not mounted" : "Folder does not exist"
        case .notDirectory:
            return "Not a folder"
        case .unreadable:
            return "Permission needed"
        case .unwritable:
            return "Permission needed"
        case .ready:
            return "Ready"
        }
    }
}

public struct PathValidationResult: Equatable, Sendable {
    public let originalPath: String
    public let expandedPath: String
    public let purpose: PathValidationPurpose
    public let status: PathValidationStatus

    public var isUsable: Bool {
        status.isUsable
    }

    public var message: String {
        status.message(for: purpose)
    }

    public static func empty(purpose: PathValidationPurpose) -> PathValidationResult {
        PathValidationResult(
            originalPath: "",
            expandedPath: "",
            purpose: purpose,
            status: .empty
        )
    }
}

public struct PathValidator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validate(path: String, purpose: PathValidationPurpose) -> PathValidationResult {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath

        guard !expandedPath.isEmpty else {
            return PathValidationResult(
                originalPath: path,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .empty
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return PathValidationResult(
                originalPath: path,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .missing
            )
        }

        guard isDirectory.boolValue else {
            return PathValidationResult(
                originalPath: path,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .notDirectory
            )
        }

        if purpose == .source, !fileManager.isReadableFile(atPath: expandedPath) {
            return PathValidationResult(
                originalPath: path,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .unreadable
            )
        }

        if purpose == .destination, !fileManager.isWritableFile(atPath: expandedPath) {
            return PathValidationResult(
                originalPath: path,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .unwritable
            )
        }

        return PathValidationResult(
            originalPath: path,
            expandedPath: expandedPath,
            purpose: purpose,
            status: .ready
        )
    }
}
