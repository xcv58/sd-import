import Darwin
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
    case symbolicLink
    case ready

    public var isUsable: Bool {
        self == .ready
    }

    public func message(for purpose: PathValidationPurpose) -> String {
        switch self {
        case .empty:
            return purpose == .source ? L10n.tr("Choose a card or source folder") : L10n.tr("Choose a destination folder")
        case .missing:
            return purpose == .source ? L10n.tr("Card is not mounted") : L10n.tr("Folder does not exist")
        case .notDirectory:
            return L10n.tr("Not a folder")
        case .unreadable:
            return L10n.tr("Permission needed")
        case .unwritable:
            return L10n.tr("Permission needed")
        case .placeholder:
            return L10n.tr("Choose a specific card or source folder")
        case .symbolicLink:
            return L10n.tr("Choose the original source folder instead of a symbolic link.")
        case .ready:
            return L10n.tr("Ready")
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

    public func validate(
        path: String, purpose: PathValidationPurpose, allowsWhitespaceFallback: Bool = true
    ) -> PathValidationResult {
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
        if exactResult.status != .missing || !allowsWhitespaceFallback {
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
        let path: String
        if purpose == .source {
            guard let sourcePath = sourcePathWithoutUserSymlinks(expandedPath) else {
                return PathValidationResult(
                    originalPath: originalPath, expandedPath: expandedPath, purpose: purpose, status: .symbolicLink
                )
            }
            path = sourcePath
            if URL(fileURLWithPath: path).standardizedFileURL.path == "/Volumes" {
                return PathValidationResult(
                    originalPath: originalPath, expandedPath: path, purpose: purpose, status: .placeholder
                )
            }
        } else {
            path = expandedPath
        }

        let denied: PathValidationStatus = purpose == .source ? .unreadable : .unwritable
        let status: PathValidationStatus
        var metadata = stat()
        // Follow symlinks and retain the lookup error when macOS hides the target.
        if stat(path, &metadata) != 0 {
            let lookupError = errno
            status = lookupError == EACCES || lookupError == EPERM ? denied : .missing
        } else if metadata.st_mode & S_IFMT != S_IFDIR {
            status = .notDirectory
        } else {
            let canTraverse = fileManager.isExecutableFile(atPath: path)
            let canUse = purpose == .source
                ? fileManager.isReadableFile(atPath: path)
                : fileManager.isWritableFile(atPath: path)
            status = canTraverse && canUse ? .ready : denied
        }

        return PathValidationResult(
            originalPath: originalPath,
            expandedPath: path,
            purpose: purpose,
            status: status
        )
    }

    private func sourcePathWithoutUserSymlinks(_ expandedPath: String) -> String? {
        let absolutePath = expandedPath.hasPrefix("/") ? expandedPath : fileManager.currentDirectoryPath + "/" + expandedPath
        var path = ""
        for component in absolutePath.split(separator: "/") where component != "." {
            path += "/" + component
            var metadata = stat()
            guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFLNK else { continue }
            // macOS exposes these aliases itself. Translate them before checking the rest of the path.
            let target = try? fileManager.destinationOfSymbolicLink(atPath: path)
            if ["/tmp", "/var", "/etc"].contains(path),
               target == "private" + path || target == "/private" + path {
                path = "/private" + path
            } else if path.hasPrefix("/Volumes/"), target == "/",
                      let bootName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName,
                      path == "/Volumes/" + bootName {
                path = ""
            } else {
                return nil
            }
        }
        return path.isEmpty ? "/" : path
    }
}
