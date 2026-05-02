import Foundation

public struct FileEnumerator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func mediaCandidateFiles(in rootURL: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
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

        return urls.sorted { $0.path < $1.path }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
