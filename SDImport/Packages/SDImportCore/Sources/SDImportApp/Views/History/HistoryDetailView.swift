import SDImportCore
import SwiftUI

struct HistoryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingForgetConfirmation = false
    @State private var fileFilter: HistoryFileFilter = .all
    @State private var filePage = 0

    let job: ImportJob?
    let files: [JobFileRecord]

    private static let fileBatchSize = 100

    private var filteredFiles: [JobFileRecord] {
        files.filter(fileFilter.includes)
    }

    var body: some View {
        if let job {
            detail(job)
                .onChange(of: job.id) {
                    filePage = 0
                }
        } else {
            ContentUnavailableView(L10n.tr("No Job Selected"), systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private func detail(_ job: ImportJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(job)
            metrics(job)
            Divider()
            fileSection
        }
        .padding(.trailing, 8)
        .alert(L10n.tr("Forget imported files?"), isPresented: $isShowingForgetConfirmation) {
            Button(L10n.tr("Forget Files"), role: .destructive) {
                model.forgetImportedFiles(for: job)
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("\(AppDistribution.current.displayName) will keep the copied files and job history. Files first imported by this job can be imported again for another destination."))
        }
    }

    private func header(_ job: ImportJob) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(job.mountPath)
            }

            Spacer(minLength: 8)
            actions(job)
        }
    }

    private func actions(_ job: ImportJob) -> some View {
        HStack(spacing: 8) {
            Button {
                model.retrySelectedJob()
            } label: {
                Label(L10n.tr("Retry"), systemImage: "arrow.counterclockwise")
            }
            .disabled(model.isWorking || !job.canRetryImport)

            Menu {
                summaryActions(job)

                Divider()

                Button(role: .destructive) {
                    isShowingForgetConfirmation = true
                } label: {
                    Label(L10n.tr("Forget Files…"), systemImage: "trash")
                }
                .disabled(model.isWorking || (job.importedFiles == 0 && files.allSatisfy { $0.copyStatus != .copied }))
            } label: {
                Label(L10n.tr("More"), systemImage: "ellipsis.circle")
            }
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func summaryActions(_ job: ImportJob) -> some View {
        Group {
            Button {
                model.copySummary(for: job)
            } label: {
                Label(L10n.tr("Copy Summary"), systemImage: "doc.on.doc")
            }
            Button {
                model.exportSummary(for: job)
            } label: {
                Label(L10n.tr("Export Summary"), systemImage: "square.and.arrow.up")
            }
            Button {
                model.viewReport(for: job)
            } label: {
                Label(L10n.tr("View Report"), systemImage: "doc.text.magnifyingglass")
            }
            .disabled(job.summaryMarkdownPath == nil && job.summaryJSONPath == nil)
        }
    }

    private func metrics(_ job: ImportJob) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], alignment: .leading, spacing: 10) {
            MetricView(title: L10n.tr("Scanned"), value: job.scannedFiles)
            MetricView(title: L10n.tr("New"), value: job.newFiles)
            MetricView(title: L10n.tr("Known"), value: job.knownFiles)
            MetricView(title: L10n.tr("Conflicts"), value: job.conflictFiles)
            MetricView(title: L10n.tr("Imported"), value: job.importedFiles)
            MetricView(title: L10n.tr("Failed"), value: job.failedFiles)
        }
        .padding(12)
        .appCardSurface()
    }

    private var fileSection: some View {
        let files = filteredFiles
        let lastPage = max(0, (files.count - 1) / Self.fileBatchSize)
        let displayedPage = min(filePage, lastPage)
        let pageStart = displayedPage * Self.fileBatchSize
        let visibleFiles = Array(files.dropFirst(pageStart).prefix(Self.fileBatchSize))
        let totalCount = self.files.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                fileHeading(
                    filteredCount: files.count,
                    visibleCount: visibleFiles.count,
                    firstVisibleIndex: files.isEmpty ? 0 : pageStart + 1,
                    totalCount: totalCount
                )
                Spacer()
                fileFilterControl
            }

            if files.isEmpty {
                ContentUnavailableView(L10n.tr("No Files"), systemImage: "doc")
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                List {
                    ForEach(visibleFiles) { file in
                        HistoryFileRow(file: file) { path in
                            model.reveal(path: path)
                        }
                            .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                            .listRowSeparator(.visible)
                    }

                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 1)
                .frame(minHeight: 180, maxHeight: .infinity)

                if files.count > Self.fileBatchSize {
                    HStack(spacing: 10) {
                        Button(L10n.tr("Previous")) {
                            filePage = max(0, displayedPage - 1)
                        }
                        .disabled(displayedPage == 0)

                        Text(L10n.tr("Page \(displayedPage + 1) of \(lastPage + 1)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(L10n.tr("Next")) {
                            filePage = min(lastPage, displayedPage + 1)
                        }
                        .disabled(displayedPage == lastPage)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func fileHeading(
        filteredCount: Int,
        visibleCount: Int,
        firstVisibleIndex: Int,
        totalCount: Int
    ) -> some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Files"))
                .font(.headline)
                .foregroundStyle(.primary)
            Text(
                fileCountText(
                    filteredCount: filteredCount,
                    visibleCount: visibleCount,
                    firstVisibleIndex: firstVisibleIndex,
                    totalCount: totalCount
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileFilterControl: some View {
        Picker(L10n.tr("File Filter"), selection: fileFilterBinding) {
            ForEach(HistoryFileFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 120)
        .accessibilityLabel(L10n.tr("File filter"))
    }

    private func fileCountText(
        filteredCount: Int,
        visibleCount: Int,
        firstVisibleIndex: Int,
        totalCount: Int
    ) -> String {
        if filteredCount > Self.fileBatchSize {
            let lastVisibleIndex = firstVisibleIndex + visibleCount - 1
            return filteredCount == totalCount
                ? L10n.tr("Showing \(firstVisibleIndex)–\(lastVisibleIndex) of \(filteredCount)")
                : L10n.tr("Showing \(firstVisibleIndex)–\(lastVisibleIndex) of \(filteredCount) matching files")
        }
        if filteredCount == totalCount {
            return totalCount == 1 ? L10n.tr("1 file") : L10n.tr("\(totalCount) files")
        }
        return L10n.tr("\(filteredCount) of \(totalCount)")
    }

    private var fileFilterBinding: Binding<HistoryFileFilter> {
        Binding {
            fileFilter
        } set: { filter in
            filePage = 0
            fileFilter = filter
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
            return L10n.tr("All")
        case .copied:
            return L10n.tr("Copied")
        case .skipped:
            return L10n.tr("Skipped")
        case .failed:
            return L10n.tr("Failed")
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
    let file: JobFileRecord
    let revealAction: (String) -> Void

    private var destinationPath: String? {
        file.finalDestinationPath ?? file.plannedDestinationPath
    }

    private var revealPath: String? {
        file.copyStatus == .copied ? file.finalDestinationPath : nil
    }

    private var detailPath: String {
        destinationPath ?? file.relativePath ?? file.sourcePath
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusImage)
                .foregroundStyle(statusColor)
                .frame(width: 18)
                .accessibilityHidden(true)

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

                HStack(spacing: 8) {
                    Text(detailPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)
                    Text(Self.bytes(file.size))
                    if let completedAt = file.completedAt {
                        Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(file.relativePath ?? file.sourcePath)

                if let error = file.error, !error.isEmpty {
                    Text(L10n.storedMessage(error))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)

            Spacer(minLength: 0)

            if let revealPath {
                Button {
                    revealAction(revealPath)
                } label: {
                    Label(L10n.tr("Reveal"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.tr("Reveal \(file.filename)"))
            }
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
            return .red
        }
    }

    private var statusTitle: String {
        switch file.copyStatus {
        case .pending:
            return L10n.tr("Pending")
        case .copied:
            return L10n.tr("Copied")
        case .skipped:
            return file.knownSource?.skippedStatusTitle ?? L10n.tr("Skipped")
        case .failed:
            return L10n.tr("Failed")
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var accessibilityLabel: String {
        var parts = [
            file.filename,
            statusTitle,
            Self.bytes(file.size),
            detailPath
        ]
        if let completedAt = file.completedAt {
            parts.append(completedAt.formatted(date: .abbreviated, time: .shortened))
        }
        if let error = file.error, !error.isEmpty {
            parts.append(L10n.storedMessage(error))
        }
        return parts.joined(separator: ", ")
    }
}
