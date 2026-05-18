import SDImportCore
import SwiftUI

struct ImportReportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var filter: ReportFileFilter = .all
    @State private var isShowingMarkdown = false

    let presentation: ImportReportPresentation

    private var job: ImportJob {
        presentation.job
    }

    private var files: [JobFileRecord] {
        presentation.files
    }

    private var filteredFiles: [JobFileRecord] {
        displayedFiles.filter(filter.includes)
    }

    private var displayedFiles: [JobFileRecord] {
        guard filter == .all else {
            return files
        }

        return files.enumerated()
            .sorted { lhs, rhs in
                let lhsPriority = fileSortPriority(lhs.element)
                let rhsPriority = fileSortPriority(rhs.element)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private var summary: ReportSummary {
        return ReportSummary(job: job, files: files)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summaryGrid
                pathDetails
                fileSection

                if isShowingMarkdown, let markdownText = presentation.markdownText {
                    markdownPreview(markdownText)
                }

                if let loadError = presentation.loadError {
                    loadWarning(loadError)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close report")
            .padding(18)
        }
        .frame(minWidth: 560, idealWidth: 860, minHeight: 480, idealHeight: 680)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Import Report")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(HistoryJobPresentation.title(for: job))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(job.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    reportActions
                }
                VStack(alignment: .trailing, spacing: 8) {
                    reportActions
                }
            }
            .padding(.trailing, 34)
        }
    }

    private var reportActions: some View {
        Group {
            Button {
                model.copySummary(for: job)
            } label: {
                Label("Copy Summary", systemImage: "doc.on.doc")
            }

            Menu {
                Button {
                    model.openReportFile(for: job)
                } label: {
                    Label("Open Markdown", systemImage: "doc.text")
                }

                Button {
                    model.revealReport(for: job)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            } label: {
                Label("Original Report", systemImage: "doc.text")
            }
            .disabled(!model.reportFileExists(for: job))
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], alignment: .leading, spacing: 10) {
            MetricView(title: "Scanned", value: summary.scannedFiles)
            MetricView(title: "New", value: summary.newFiles)
            MetricView(title: "Known", value: summary.knownFiles)
            MetricView(title: "Conflicts", value: summary.conflictFiles)
            MetricView(title: "Copied", value: summary.copiedFiles)
            MetricView(title: "Failed", value: summary.failedFiles)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var pathDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            reportPathRow(title: "Source", path: summary.mountPath)
            reportPathRow(title: "Photos", path: job.photosRoot)
            reportPathRow(title: "Videos", path: job.videosRoot)
        }
        .font(.caption)
    }

    private func reportPathRow(title: String, path: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fileSectionHeader

            if filteredFiles.isEmpty {
                ContentUnavailableView("No Files", systemImage: "doc")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredFiles) { file in
                            ReportFileRow(file: file)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 180, maxHeight: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                }
            }
        }
    }

    private var fileSectionHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                fileHeading
                Spacer()
                fileControls
            }

            VStack(alignment: .leading, spacing: 8) {
                fileHeading
                fileControls
            }
        }
    }

    private var fileHeading: some View {
        HStack(spacing: 8) {
            Text("Files")
                .font(.headline)
            Text(fileCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileControls: some View {
        HStack(spacing: 8) {
            if presentation.markdownText != nil {
                Toggle(isOn: $isShowingMarkdown) {
                    Label("Markdown", systemImage: "doc.richtext")
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }

            Picker("File Filter", selection: $filter) {
                ForEach(ReportFileFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 300, idealWidth: 410, maxWidth: 410)
        }
    }

    private var fileCountText: String {
        if filteredFiles.count == files.count {
            return files.count == 1 ? "1 file" : "\(files.count) files"
        }
        return "\(filteredFiles.count) of \(files.count)"
    }

    private func fileSortPriority(_ file: JobFileRecord) -> Int {
        if file.copyStatus == .failed {
            return 0
        }
        if file.decision == .conflict {
            return 1
        }
        if file.copyStatus == .copied {
            return 2
        }
        return 3
    }

    private func markdownPreview(_ markdownText: String) -> some View {
        ScrollView {
            Text(markdownAttributedString(markdownText))
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private func markdownAttributedString(_ markdownText: String) -> AttributedString {
        (try? AttributedString(markdown: markdownText)) ?? AttributedString(markdownText)
    }

    private func loadWarning(_ message: String) -> some View {
        DisclosureGroup {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Report opened with warnings", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct ReportSummary {
    let mountPath: String
    let scannedFiles: Int
    let newFiles: Int
    let knownFiles: Int
    let conflictFiles: Int
    let copiedFiles: Int
    let failedFiles: Int

    init(job: ImportJob, files: [JobFileRecord]) {
        self.mountPath = job.mountPath
        self.scannedFiles = job.scannedFiles
        self.newFiles = job.newFiles
        self.knownFiles = job.knownFiles
        self.conflictFiles = job.conflictFiles
        self.copiedFiles = job.importedFiles > 0 ? job.importedFiles : files.filter { $0.copyStatus == .copied }.count
        self.failedFiles = job.failedFiles > 0 ? job.failedFiles : files.filter { $0.copyStatus == .failed }.count
    }
}

private enum ReportFileFilter: String, CaseIterable, Identifiable {
    case all
    case copied
    case skipped
    case failed
    case conflicts

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
        case .conflicts:
            return "Conflicts"
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
        case .conflicts:
            return file.decision == .conflict
        }
    }
}

private struct ReportFileRow: View {
    @EnvironmentObject private var model: AppModel

    let file: JobFileRecord

    private var destinationPath: String? {
        file.finalDestinationPath ?? file.plannedDestinationPath ?? file.destinationDirectory
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
