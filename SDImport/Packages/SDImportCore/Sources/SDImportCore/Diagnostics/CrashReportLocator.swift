import Foundation

public struct CrashReportCandidate: Equatable, Sendable {
    public let url: URL
    public let modifiedAt: Date
    public let byteCount: Int64

    public init(url: URL, modifiedAt: Date, byteCount: Int64) {
        self.url = url
        self.modifiedAt = modifiedAt
        self.byteCount = byteCount
    }
}

public enum CrashReportLocator {
    public static func defaultDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DiagnosticReports", isDirectory: true)
    }

    public static func findReports(
        in directory: URL = defaultDirectory(),
        fileManager: FileManager = .default,
        limit: Int = 5
    ) -> [CrashReportCandidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard isLikelySDImportCrashReport(url) else {
                return nil
            }

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                return nil
            }

            return CrashReportCandidate(
                url: url,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func isLikelySDImportCrashReport(_ url: URL) -> Bool {
        let allowedExtensions: Set<String> = ["crash", "ips", "diag"]
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }

        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.hasPrefix("sd import")
            || name.hasPrefix("sdimport")
            || name.contains("com.xcv58.sdimport")
    }
}
