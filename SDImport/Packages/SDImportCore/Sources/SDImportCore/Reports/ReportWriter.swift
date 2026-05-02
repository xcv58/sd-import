import Foundation

public struct ReportPaths: Hashable, Codable, Sendable {
    public let jsonURL: URL
    public let markdownURL: URL
}

public struct ReportWriter {
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func writeReport(
        summary: ScanSummary,
        files: [JobFileRecord],
        baseURL: URL
    ) throws -> ReportPaths {
        try fileManager.createDirectory(
            at: baseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let jsonURL = baseURL.appendingPathExtension("json")
        let markdownURL = baseURL.appendingPathExtension("md")

        let payload = ReportPayload(summary: summary, files: files)
        let data = try encoder.encode(payload)
        try data.write(to: jsonURL, options: .atomic)
        try markdown(summary: summary, files: files).write(to: markdownURL, atomically: true, encoding: .utf8)

        return ReportPaths(jsonURL: jsonURL, markdownURL: markdownURL)
    }

    private func markdown(summary: ScanSummary, files: [JobFileRecord]) -> String {
        var lines: [String] = [
            "# SD Import Report \(summary.jobID)",
            "",
            "- mount: `\(summary.mountPath)`",
            "- volume: `\(summary.volumeName ?? "")`",
            "- location: `\(summary.location)`",
            "- scanned: `\(summary.scannedFiles)`",
            "- new: `\(summary.newFiles)`",
            "- known: `\(summary.knownFiles)`",
            "- unsupported: `\(summary.unsupportedFiles)`",
            "- conflicts: `\(summary.conflictFiles)`",
            "",
            "## New Files",
            ""
        ]

        for file in files where file.decision == .new {
            lines.append("- `\(file.sourcePath)` -> `\(file.plannedDestinationPath ?? file.destinationDirectory ?? "")`")
        }

        lines.append("")
        lines.append("## Conflicts")
        lines.append("")

        let conflicts = files.filter { $0.decision == .conflict }
        if conflicts.isEmpty {
            lines.append("- none")
        } else {
            for file in conflicts {
                lines.append("- `\(file.sourcePath)` (\(file.error ?? "conflict"))")
            }
        }

        return lines.joined(separator: "\n")
    }
}

private struct ReportPayload: Encodable {
    let summary: ScanSummary
    let files: [JobFileRecord]
}
