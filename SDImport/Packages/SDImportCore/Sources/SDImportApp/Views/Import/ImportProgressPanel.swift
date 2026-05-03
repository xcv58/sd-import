import SDImportCore
import SwiftUI

struct ImportProgressPanel: View {
    let progress: ImportProgress

    private var fractionComplete: Double {
        min(1, max(0, progress.percent / 100))
    }

    private var percentText: String {
        "\(Int(progress.percent.rounded()))%"
    }

    var body: some View {
        AppSection("Copy Monitor", systemImage: "speedometer") {
            HStack(alignment: .firstTextBaseline) {
                Text(percentText)
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                Text(fileCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: fractionComplete)
                .progressViewStyle(.linear)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                ProgressMetric(title: "Data", value: copiedText)
                ProgressMetric(title: "Speed", value: speedText)
                ProgressMetric(title: "Remaining", value: remainingText)
                ProgressMetric(title: "Files", value: fileCountText)
                ProgressMetric(title: "Copied", value: "\(progress.importedFiles)")
                ProgressMetric(title: "Skipped", value: "\(progress.skippedFiles)")
                ProgressMetric(title: "Failed", value: "\(progress.failedFiles)")
            }

            if let currentFilename = progress.currentFilename, !currentFilename.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(currentFilename, systemImage: "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let destinationPath = progress.currentDestinationPath {
                        Label(destinationPath, systemImage: "folder")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if !progress.recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Files")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(progress.recentFiles) { event in
                        ProgressFileEventRow(event: event)
                    }
                }
            }
        }
    }

    private var copiedText: String {
        "\(Self.bytes(progress.copiedBytes)) of \(Self.bytes(progress.totalBytes))"
    }

    private var speedText: String {
        guard progress.throughputBytesPerSecond > 1 else {
            return "Estimating"
        }
        return "\(Self.bytes(Int64(progress.throughputBytesPerSecond)))/s"
    }

    private var remainingText: String {
        if progress.status == "completed" || progress.status == "completed_with_errors" || fractionComplete >= 1 {
            return "Complete"
        }
        guard let etaSeconds = progress.etaSeconds else {
            return "Estimating"
        }
        return Self.duration(etaSeconds)
    }

    private var fileCountText: String {
        "\(progress.doneFiles) of \(progress.totalFiles)"
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func duration(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded(.up)))
        if rounded < 1 {
            return "<1s"
        }
        if rounded < 60 {
            return "\(rounded)s"
        }

        let minutes = rounded / 60
        let remainderSeconds = rounded % 60
        if minutes < 60 {
            return "\(minutes)m \(remainderSeconds)s"
        }

        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        return "\(hours)h \(remainderMinutes)m"
    }
}

private struct ProgressMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProgressFileEventRow: View {
    let event: ImportProgressFileEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusImage)
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(statusText)
                    Text(Self.bytes(event.size))
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
    }

    private var statusImage: String {
        switch event.status {
        case .pending:
            return "clock"
        case .copied:
            return "checkmark.seal"
        case .skipped:
            return "forward"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch event.status {
        case .pending, .skipped:
            return .secondary
        case .copied:
            return .green
        case .failed:
            return .orange
        }
    }

    private var statusText: String {
        switch event.status {
        case .pending:
            return "Pending"
        case .copied:
            return "Copied"
        case .skipped:
            return "Skipped"
        case .failed:
            return "Failed"
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
