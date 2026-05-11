import Foundation

public struct DiagnosticsReportSnapshot: Sendable {
    public let generatedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let architecture: String
    public let updateFeedConfigured: Bool
    public let sourcePath: String
    public let photosPath: String
    public let videosPath: String
    public let sourceStatus: String
    public let photosStatus: String
    public let videosStatus: String
    public let autoPromptEnabled: Bool
    public let historyRetention: String
    public let statusMessage: String
    public let setupError: String?
    public let recentJobs: [DiagnosticsJobSummary]
    public let selectedFiles: [DiagnosticsFileSummary]

    public init(
        generatedAt: Date,
        appVersion: String,
        appBuild: String,
        osVersion: String,
        architecture: String,
        updateFeedConfigured: Bool,
        sourcePath: String,
        photosPath: String,
        videosPath: String,
        sourceStatus: String,
        photosStatus: String,
        videosStatus: String,
        autoPromptEnabled: Bool,
        historyRetention: String,
        statusMessage: String,
        setupError: String?,
        recentJobs: [DiagnosticsJobSummary],
        selectedFiles: [DiagnosticsFileSummary]
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.architecture = architecture
        self.updateFeedConfigured = updateFeedConfigured
        self.sourcePath = sourcePath
        self.photosPath = photosPath
        self.videosPath = videosPath
        self.sourceStatus = sourceStatus
        self.photosStatus = photosStatus
        self.videosStatus = videosStatus
        self.autoPromptEnabled = autoPromptEnabled
        self.historyRetention = historyRetention
        self.statusMessage = statusMessage
        self.setupError = setupError
        self.recentJobs = recentJobs
        self.selectedFiles = selectedFiles
    }
}

public struct DiagnosticsJobSummary: Sendable {
    public let id: String
    public let createdAt: Date
    public let status: ImportJobStatus
    public let scannedFiles: Int
    public let newFiles: Int
    public let knownFiles: Int
    public let unsupportedFiles: Int
    public let conflictFiles: Int
    public let importedFiles: Int
    public let skippedFiles: Int
    public let failedFiles: Int

    public init(job: ImportJob) {
        self.id = job.id
        self.createdAt = job.createdAt
        self.status = job.status
        self.scannedFiles = job.scannedFiles
        self.newFiles = job.newFiles
        self.knownFiles = job.knownFiles
        self.unsupportedFiles = job.unsupportedFiles
        self.conflictFiles = job.conflictFiles
        self.importedFiles = job.importedFiles
        self.skippedFiles = job.skippedFiles
        self.failedFiles = job.failedFiles
    }
}

public struct DiagnosticsFileSummary: Sendable {
    public let ext: String
    public let mediaKind: MediaKind
    public let decision: FileDecision
    public let copyStatus: CopyStatus
    public let size: Int64
    public let error: String?

    public init(file: JobFileRecord) {
        self.ext = file.ext
        self.mediaKind = file.mediaKind
        self.decision = file.decision
        self.copyStatus = file.copyStatus
        self.size = file.size
        self.error = file.error
    }
}

public enum DiagnosticsReportBuilder {
    public static func markdown(
        snapshot: DiagnosticsReportSnapshot,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        var lines: [String] = [
            "# SD Import Diagnostics",
            "",
            "- generated: `\(isoString(from: snapshot.generatedAt))`",
            "- app: `\(snapshot.appVersion) (\(snapshot.appBuild))`",
            "- macOS: `\(snapshot.osVersion)`",
            "- architecture: `\(snapshot.architecture)`",
            "- update feed configured: `\(snapshot.updateFeedConfigured ? "yes" : "no")`",
            "- prompt on card mount: `\(snapshot.autoPromptEnabled ? "enabled" : "disabled")`",
            "- history retention: `\(snapshot.historyRetention)`",
            "- status: `\(snapshot.statusMessage)`"
        ]

        if let setupError = snapshot.setupError, !setupError.isEmpty {
            lines.append("- setup error: `\(setupError)`")
        }

        lines.append(contentsOf: [
            "",
            "## Paths",
            "",
            "- source: `\(redactedPath(snapshot.sourcePath, homeDirectory: homeDirectory))` (\(snapshot.sourceStatus))",
            "- photos: `\(redactedPath(snapshot.photosPath, homeDirectory: homeDirectory))` (\(snapshot.photosStatus))",
            "- videos: `\(redactedPath(snapshot.videosPath, homeDirectory: homeDirectory))` (\(snapshot.videosStatus))",
            "",
            "## Recent Jobs",
            ""
        ])

        if snapshot.recentJobs.isEmpty {
            lines.append("No recent jobs loaded.")
        } else {
            lines.append("| Created | Job | Status | Scanned | New | Known | Sidecars | Conflicts | Imported | Skipped | Failed |")
            lines.append("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
            for job in snapshot.recentJobs {
                lines.append(
                    "| \(isoString(from: job.createdAt)) | `\(job.id)` | \(job.status.rawValue) | \(job.scannedFiles) | \(job.newFiles) | \(job.knownFiles) | \(job.unsupportedFiles) | \(job.conflictFiles) | \(job.importedFiles) | \(job.skippedFiles) | \(job.failedFiles) |"
                )
            }
        }

        lines.append(contentsOf: [
            "",
            "## Selected Job File Summary",
            "",
            "File names and full paths are intentionally omitted."
        ])

        if snapshot.selectedFiles.isEmpty {
            lines.append("")
            lines.append("No selected job files loaded.")
        } else {
            lines.append("")
            lines.append("| Extension | Kind | Decision | Copy Status | Size | Error |")
            lines.append("| --- | --- | --- | --- | ---: | --- |")
            for file in snapshot.selectedFiles {
                lines.append(
                    "| \(file.ext.uppercased()) | \(file.mediaKind.rawValue) | \(file.decision.databaseValue) | \(file.copyStatus.databaseValue) | \(file.size) | \(file.error ?? "") |"
                )
            }
        }

        lines.append(contentsOf: [
            "",
            "## Privacy Note",
            "",
            "This export excludes media files, file names, and full source/destination paths. Review it before attaching it to a public issue."
        ])

        return lines.joined(separator: "\n") + "\n"
    }

    public static func redactedPath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let homePath = homeDirectory.path
        if expanded == homePath {
            return "~"
        }
        if expanded.hasPrefix(homePath + "/") {
            return "~/" + String(expanded.dropFirst(homePath.count + 1))
        }
        if expanded.hasPrefix("/Volumes/") {
            let components = expanded.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count > 1 else {
                return "/Volumes/<volume>"
            }
            return "/Volumes/\(components[1])" + (components.count > 2 ? "/..." : "")
        }
        return expanded
    }

    private static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
