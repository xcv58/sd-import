import Foundation

public struct FileEnumerator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func mediaCandidateFiles(
        in rootURL: URL,
        shouldCancel: () -> Bool = { false }
    ) throws -> [URL] {
        var rootError: Error?
        let rootPath = rootURL.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                guard url.standardizedFileURL.path == rootPath else { return true }
                rootError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: rootURL])
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if shouldCancel() {
                throw SDImportError.cancelled
            }
            if url.lastPathComponent.hasPrefix(".") {
                if isDirectory(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isDirectory(url) {
                continue
            }
            urls.append(url)
        }

        if let rootError {
            throw rootError
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
