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

        let payload = ImportReport(summary: summary, files: files)
        let data = try encoder.encode(payload)
        try data.write(to: jsonURL, options: .atomic)
        try markdown(summary: summary, files: files).write(to: markdownURL, atomically: true, encoding: .utf8)

        return ReportPaths(jsonURL: jsonURL, markdownURL: markdownURL)
    }

    private func markdown(summary: ScanSummary, files: [JobFileRecord]) -> String {
        let receiptTotals = ImportReceiptTotals(files: files)
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
            "- copied: `\(receiptTotals.copiedFiles)`",
            "- skipped: `\(receiptTotals.skippedFiles)`",
            "- failed: `\(receiptTotals.failedFiles)`",
            "",
            "## New Files",
            ""
        ]

        for unit in reportUnits(files: files) where unit.contains(where: { $0.decision == .new }) {
            if unit.count == 1, let file = unit.first {
                lines.append("- `\(file.sourcePath)` -> `\(file.finalDestinationPath ?? file.plannedDestinationPath ?? file.destinationDirectory ?? "")` (\(file.copyStatus.databaseValue))")
            } else {
                lines.append("- Insta360 recording (\(unit.count) companion files)")
                for file in unit {
                    lines.append("  - `\(file.filename)` -> `\(file.finalDestinationPath ?? file.plannedDestinationPath ?? file.destinationDirectory ?? "")` (\(file.copyStatus.databaseValue))")
                }
            }
        }

        lines.append("")
        lines.append("## Copied Files")
        lines.append("")

        let copiedUnits = reportUnits(files: files).filter {
            $0.contains(where: { $0.copyStatus == .copied })
        }
        if copiedUnits.isEmpty {
            lines.append("- none")
        } else {
            for unit in copiedUnits {
                let copiedMembers = unit.filter { $0.copyStatus == .copied }
                if unit.count == 1, let file = copiedMembers.first {
                    lines.append("- `\(file.filename)` -> `\(file.finalDestinationPath ?? file.plannedDestinationPath ?? "")` (Copied, \(Self.bytes(file.size)))")
                } else {
                    let copiedBytes = copiedMembers.reduce(Int64(0)) { $0 + $1.size }
                    lines.append("- Insta360 recording (Copied, \(Self.bytes(copiedBytes)))")
                    for file in copiedMembers {
                        lines.append("  - `\(file.filename)` -> `\(file.finalDestinationPath ?? file.plannedDestinationPath ?? "")`")
                    }
                }
            }
        }

        lines.append("")
        lines.append("## Conflicts")
        lines.append("")

        let conflictUnits = reportUnits(files: files).filter {
            $0.contains(where: { $0.decision == .conflict })
        }
        if conflictUnits.isEmpty {
            lines.append("- none")
        } else {
            for unit in conflictUnits {
                if unit.count == 1, let file = unit.first {
                    lines.append("- `\(file.sourcePath)` (\(file.error ?? "conflict"))")
                } else {
                    lines.append("- Insta360 recording (Conflict)")
                    for file in unit {
                        let detail = file.error
                            ?? (file.decision == .conflict ? "conflict" : file.copyStatus.databaseValue)
                        lines.append("  - `\(file.filename)` (\(detail))")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func reportUnits(files: [JobFileRecord]) -> [[JobFileRecord]] {
        RecordingPresentation.units(files: files).map(\.files)
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
