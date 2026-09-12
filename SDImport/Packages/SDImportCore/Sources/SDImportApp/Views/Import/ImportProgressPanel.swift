import SDImportCore
import SwiftUI

struct ImportProgressPanel: View {
    let progress: ImportProgress
    let cancelAction: () -> Void

    private var fractionComplete: Double {
        min(1, max(0, progress.percent / 100))
    }

    private var percentText: String {
        "\(Int(progress.percent.rounded()))%"
    }

    var body: some View {
        AppSection(L10n.tr("Copy Monitor"), systemImage: "speedometer") {
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

            HStack {
                Spacer()
                Button(role: .cancel) {
                    cancelAction()
                } label: {
                    Label(L10n.tr("Cancel Copy"), systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("import.cancel.copy")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                ProgressMetric(title: L10n.tr("Data"), value: copiedText)
                ProgressMetric(title: L10n.tr("Speed"), value: speedText)
                ProgressMetric(title: L10n.tr("Remaining"), value: remainingText)
                ProgressMetric(title: L10n.tr("Files"), value: fileCountText)
                ProgressMetric(title: L10n.tr("Copied"), value: "\(progress.importedFiles)")
                ProgressMetric(title: L10n.tr("Skipped"), value: "\(progress.skippedFiles)")
                ProgressMetric(title: L10n.tr("Failed"), value: "\(progress.failedFiles)")
            }

            if let destinationSummary {
                ProgressDestinationSummary(summary: destinationSummary)
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
                    Text(L10n.tr("Recent Files"))
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
        L10n.tr("\(Self.bytes(progress.copiedBytes)) of \(Self.bytes(progress.totalBytes))")
    }

    private var speedText: String {
        guard progress.throughputBytesPerSecond > 1 else {
            return L10n.tr("Estimating")
        }
        return "\(Self.bytes(Int64(progress.throughputBytesPerSecond)))/s"
    }

    private var remainingText: String {
        if progress.status == "completed" || progress.status == "completed_with_errors" || fractionComplete >= 1 {
            return L10n.tr("Complete")
        }
        guard let etaSeconds = progress.etaSeconds else {
            return L10n.tr("Estimating")
        }
        return Self.duration(etaSeconds)
    }

    private var fileCountText: String {
        L10n.tr("\(progress.doneFiles) of \(progress.totalFiles)")
    }

    private var destinationSummary: ProgressDestinationSummaryModel? {
        let directories = progress.destinationDirectories
        if let firstDirectory = directories.first {
            return ProgressDestinationSummaryModel(
                count: directories.count,
                primaryPath: firstDirectory,
                allPaths: directories
            )
        }

        let paths = ([progress.currentDestinationPath] + progress.recentFiles.map(\.destinationPath)).compactMap { $0 }
        let directoriesFromEvents = Array(Set(paths.map {
            URL(fileURLWithPath: $0, isDirectory: false).deletingLastPathComponent().path
        }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let firstDirectory = directoriesFromEvents.first else {
            return nil
        }
        return ProgressDestinationSummaryModel(
            count: directoriesFromEvents.count,
            primaryPath: firstDirectory,
            allPaths: directoriesFromEvents
        )
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return L10n.tr("Estimating") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(1, seconds.rounded(.up))) ?? L10n.tr("Estimating")
    }
}

private struct ProgressDestinationSummaryModel {
    let count: Int
    let primaryPath: String
    let allPaths: [String]

    var title: String {
        count == 1 ? L10n.tr("Destination") : L10n.tr("\(count) destination folders")
    }

    var detail: String {
        count <= 1 ? primaryPath : L10n.tr("\(primaryPath) (+\(count - 1) more)")
    }

    var helpText: String {
        allPaths.joined(separator: "\n")
    }
}

private struct ProgressDestinationSummary: View {
    let summary: ProgressDestinationSummaryModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(summary.title, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)

            Text(summary.detail)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(summary.helpText)

            Spacer(minLength: 0)
        }
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
                        Text(L10n.storedMessage(detail))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

                if let destinationPath = event.destinationPath, !destinationPath.isEmpty {
                    Label(destinationPath, systemImage: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(destinationPath)
                }
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
            return .red
        }
    }

    private var statusText: String {
        switch event.status {
        case .pending:
            return L10n.tr("Pending")
        case .copied:
            return L10n.tr("Copied")
        case .skipped:
            return L10n.tr("Skipped")
        case .failed:
            return L10n.tr("Failed")
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
