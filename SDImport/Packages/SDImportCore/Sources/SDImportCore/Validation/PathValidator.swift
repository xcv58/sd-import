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
    case placeholder
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
        case .placeholder:
            return "Choose a specific card or source folder"
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

        guard !trimmedPath.isEmpty else {
            return PathValidationResult(
                originalPath: path,
                expandedPath: "",
                purpose: purpose,
                status: .empty
            )
        }

        let expandedPath = (path as NSString).expandingTildeInPath
        let exactResult = validateExpandedPath(expandedPath, originalPath: path, purpose: purpose)
        if exactResult.status != .missing {
            return exactResult
        }

        let trimmedExpandedPath = (trimmedPath as NSString).expandingTildeInPath
        if trimmedExpandedPath != expandedPath {
            let trimmedResult = validateExpandedPath(trimmedExpandedPath, originalPath: path, purpose: purpose)
            if trimmedResult.status != .missing {
                return trimmedResult
            }
        }

        if let whitespaceVariantPath = resolveWhitespaceVariantPath(expandedPath) {
            let whitespaceVariantResult = validateExpandedPath(
                whitespaceVariantPath,
                originalPath: path,
                purpose: purpose
            )
            if whitespaceVariantResult.status != .missing {
                return whitespaceVariantResult
            }
        }

        return exactResult
    }

    private func resolveWhitespaceVariantPath(_ expandedPath: String) -> String? {
        let components = URL(fileURLWithPath: expandedPath).pathComponents
        guard let firstComponent = components.first, firstComponent == "/" else {
            return nil
        }

        var currentURL = URL(fileURLWithPath: firstComponent, isDirectory: true)
        for component in components.dropFirst() {
            let exactURL = currentURL.appendingPathComponent(component)
            if fileManager.fileExists(atPath: exactURL.path) {
                currentURL = exactURL
                continue
            }

            let trimmedComponent = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmedComponent.isEmpty,
                let siblingNames = try? fileManager.contentsOfDirectory(atPath: currentURL.path)
            else {
                return nil
            }

            let matchingNames = siblingNames.filter {
                $0 != component && $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedComponent
            }
            guard matchingNames.count == 1, let matchingName = matchingNames.first else {
                return nil
            }

            currentURL = currentURL.appendingPathComponent(matchingName)
        }

        return currentURL.path
    }

    private func validateExpandedPath(
        _ expandedPath: String,
        originalPath: String,
        purpose: PathValidationPurpose
    ) -> PathValidationResult {
        if purpose == .source, URL(fileURLWithPath: expandedPath).standardizedFileURL.path == "/Volumes" {
            return PathValidationResult(
                originalPath: originalPath,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .placeholder
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return PathValidationResult(
                originalPath: originalPath,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .missing
            )
        }

        guard isDirectory.boolValue else {
            return PathValidationResult(
                originalPath: originalPath,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .notDirectory
            )
        }

        if purpose == .source, !fileManager.isReadableFile(atPath: expandedPath) {
            return PathValidationResult(
                originalPath: originalPath,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .unreadable
            )
        }

        if purpose == .destination, !fileManager.isWritableFile(atPath: expandedPath) {
            return PathValidationResult(
                originalPath: originalPath,
                expandedPath: expandedPath,
                purpose: purpose,
                status: .unwritable
            )
        }

        return PathValidationResult(
            originalPath: originalPath,
            expandedPath: expandedPath,
            purpose: purpose,
            status: .ready
        )
    }
}
