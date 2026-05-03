import SDImportCore
import SwiftUI

struct ImportResultView: View {
    @EnvironmentObject private var model: AppModel

    let result: ImportResult

    private var job: ImportJob? {
        model.selectedJob()
    }

    private var copiedFiles: [JobFileRecord] {
        model.selectedJobFiles.filter { $0.copyStatus == .copied }
    }

    private var copiedBytes: Int64 {
        copiedFiles.reduce(Int64(0)) { $0 + $1.size }
    }

    private var folderSummaries: [ReceiptFolderSummary] {
        let grouped = Dictionary(grouping: copiedFiles) { file in
            file.finalDestinationPath.map {
                URL(fileURLWithPath: $0, isDirectory: false).deletingLastPathComponent().path
            } ?? file.destinationDirectory ?? "Unknown"
        }

        return grouped
            .map { path, files in
                ReceiptFolderSummary(
                    path: path,
                    title: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent,
                    count: files.count
                )
            }
            .sorted { $0.path < $1.path }
    }

    private var primaryDestinationPath: String? {
        folderSummaries.first?.path
    }

    private var copyStatusTitle: String {
        if result.importedFiles == 0 {
            return "No Copies"
        }
        return result.failedFiles == 0 ? "Copied" : "Copied with Errors"
    }

    private var copyStatusColor: Color {
        result.importedFiles > 0 && result.failedFiles == 0 ? .green : .secondary
    }

    var body: some View {
        AppSection("Copy Receipt", systemImage: "checkmark.seal") {
            HStack(alignment: .firstTextBaseline) {
                Label(copyStatusTitle, systemImage: result.importedFiles == 0 ? "minus.circle" : "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(copyStatusColor)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                ReceiptMetric(title: "Copied", value: "\(result.importedFiles)")
                ReceiptMetric(title: "Size", value: Self.bytes(copiedBytes))
                ReceiptMetric(title: "Skipped", value: "\(result.skippedFiles)")
                ReceiptMetric(title: "Failed", value: "\(result.failedFiles)")
            }

            if !folderSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Destinations")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(folderSummaries.prefix(4)) { summary in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(summary.title)
                                .lineLimit(1)
                            Text("\(summary.count) files")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .help(summary.path)
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    receiptButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    receiptButtons
                }
            }
        }
    }

    private var receiptButtons: some View {
        Group {
            Button {
                if let primaryDestinationPath {
                    model.reveal(path: primaryDestinationPath)
                }
            } label: {
                Label("Reveal Destination", systemImage: "folder")
            }
            .disabled(primaryDestinationPath == nil)

            Button {
                if let job {
                    model.revealReport(for: job)
                }
            } label: {
                Label("Open Report", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(job?.summaryMarkdownPath == nil && job?.summaryJSONPath == nil)

            Button {
                model.selection = .history
            } label: {
                Label("View Imported Files", systemImage: "list.bullet.rectangle")
            }
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct ReceiptMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReceiptFolderSummary: Identifiable {
    let path: String
    let title: String
    let count: Int

    var id: String { path }
}
