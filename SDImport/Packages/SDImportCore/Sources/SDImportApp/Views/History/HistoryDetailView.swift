import SDImportCore
import SwiftUI

struct HistoryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingForgetConfirmation = false
    @State private var fileFilter: HistoryFileFilter = .all

    let job: ImportJob?
    let files: [JobFileRecord]

    private var filteredFiles: [JobFileRecord] {
        files.filter(fileFilter.includes)
    }

    var body: some View {
        if let job {
            VStack(alignment: .leading, spacing: 16) {
                header(job)
                metrics(job)
                actions(job)
                fileList
            }
        } else {
            ContentUnavailableView("No Job Selected", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private func header(_ job: ImportJob) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(HistoryJobPresentation.title(for: job))
                .font(.title2)
                .fontWeight(.semibold)
            Text(HistoryJobPresentation.subtitle(for: job))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(job.id)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(job.mountPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private func metrics(_ job: ImportJob) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], alignment: .leading, spacing: 10) {
            MetricView(title: "Scanned", value: job.scannedFiles)
            MetricView(title: "New", value: job.newFiles)
            MetricView(title: "Known", value: job.knownFiles)
            MetricView(title: "Conflicts", value: job.conflictFiles)
            MetricView(title: "Imported", value: job.importedFiles)
            MetricView(title: "Failed", value: job.failedFiles)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func actions(_ job: ImportJob) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                actionButtons(job)
            }

            VStack(alignment: .leading, spacing: 8) {
                actionButtons(job)
            }
        }
    }

    private func actionButtons(_ job: ImportJob) -> some View {
        Group {
            Button {
                model.retrySelectedJob()
            } label: {
                Label("Retry", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.isWorking || !job.canRetryImport)
            Button {
                model.copySummary(for: job)
            } label: {
                Label("Copy Summary", systemImage: "doc.on.doc")
            }
            Button {
                model.exportSummary(for: job)
            } label: {
                Label("Export Summary", systemImage: "square.and.arrow.up")
            }
            Button {
                model.revealReport(for: job)
            } label: {
                Label("Reveal Report", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(job.summaryMarkdownPath == nil && job.summaryJSONPath == nil)

            Button(role: .destructive) {
                isShowingForgetConfirmation = true
            } label: {
                Label("Forget Files", systemImage: "trash")
            }
            .disabled(model.isWorking || (job.importedFiles == 0 && files.allSatisfy { $0.copyStatus != .copied }))
            .alert("Forget imported files?", isPresented: $isShowingForgetConfirmation) {
                Button("Forget Files", role: .destructive) {
                    model.forgetImportedFiles(for: job)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("SD Import will keep the copied files and job history. Files first imported by this job can be imported again for another destination.")
            }
        }
    }

    private var fileList: some View {
        let files = filteredFiles
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files")
                    .font(.headline)
                Spacer()
                Picker("File Filter", selection: $fileFilter) {
                    ForEach(HistoryFileFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(files) { file in
                    HistoryFileRow(file: file)
                    Divider()
                }
            }
        }
    }
}

private enum HistoryFileFilter: String, CaseIterable, Identifiable {
    case all
    case copied
    case skipped
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .copied:
            return "Copied"
        case .skipped:
            return "Skipped"
        case .failed:
            return "Failed"
        }
    }

    func includes(_ file: JobFileRecord) -> Bool {
        switch self {
        case .all:
            return true
        case .copied:
            return file.copyStatus == .copied
        case .skipped:
            return file.copyStatus == .skipped
        case .failed:
            return file.copyStatus == .failed
        }
    }
}

private struct HistoryFileRow: View {
    @EnvironmentObject private var model: AppModel

    let file: JobFileRecord

    private var destinationPath: String? {
        file.finalDestinationPath ?? file.plannedDestinationPath
    }

    private var revealPath: String? {
        file.copyStatus == .copied ? file.finalDestinationPath : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusImage)
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(file.filename)
                        .lineLimit(1)

                    Text(statusTitle)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                if let destinationPath {
                    Text(destinationPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Text(Self.bytes(file.size))
                    if let completedAt = file.completedAt {
                        Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text(file.relativePath ?? file.sourcePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                if let error = file.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Button {
                if let revealPath {
                    model.reveal(path: revealPath)
                }
            } label: {
                Label("Reveal", systemImage: "arrow.up.right.square")
            }
            .disabled(revealPath == nil)
            .accessibilityLabel("Reveal \(file.filename)")
        }
        .padding(.vertical, 6)
    }

    private var statusImage: String {
        switch file.copyStatus {
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
        switch file.copyStatus {
        case .pending, .skipped:
            return .secondary
        case .copied:
            return .green
        case .failed:
            return .orange
        }
    }

    private var statusTitle: String {
        switch file.copyStatus {
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
