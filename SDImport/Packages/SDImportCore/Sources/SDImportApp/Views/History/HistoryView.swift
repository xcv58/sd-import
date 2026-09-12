import SDImportCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: HistoryFilter = .all

    private var filteredJobs: [ImportJob] {
        model.jobs.filter(\.isImportHistoryEntry).filter(filter.includes)
    }

    var body: some View {
        AppPage(scrolls: false, maxContentWidth: .infinity) {
            historyLayout
        }
        .navigationTitle(L10n.tr("History"))
        .onAppear {
            let importJobs = model.jobs.filter(\.isImportHistoryEntry)
            let selectedJobIsVisible = model.selectedJobID.map { selectedJobID in
                importJobs.contains { $0.id == selectedJobID }
            } ?? false
            if importJobs.isEmpty || !selectedJobIsVisible {
                model.refreshHistory()
            }
        }
    }

    private var historyLayout: some View {
        HSplitView {
            recentJobsSection
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

            detailSection
                .frame(minWidth: 360, maxWidth: .infinity)
        }
        .frame(minHeight: 320, maxHeight: .infinity)
    }

    private var recentJobsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(L10n.tr("Recent Imports"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)

                Spacer()

                Button {
                    model.refreshHistory()
                } label: {
                    Label(L10n.tr("Refresh"), systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(model.isHistoryLoading)
                .help(L10n.tr("Refresh history"))
                .accessibilityLabel(L10n.tr("Refresh history"))
            }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.tr("Filter"), selection: $filter) {
                    ForEach(HistoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if model.isHistoryLoading {
                    ProgressView(L10n.tr("Loading history..."))
                        .controlSize(.small)
                }

                if filteredJobs.isEmpty {
                    ContentUnavailableView(
                        model.isHistoryLoading ? L10n.tr("Loading History") : L10n.tr("No Import History"),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    List(selection: selectedJobBinding) {
                        ForEach(filteredJobs) { job in
                            HistoryRow(job: job)
                            .tag(job.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .accessibilityLabel("\(HistoryJobPresentation.title(for: job)), \(HistoryJobPresentation.subtitle(for: job))")
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 180, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(AppSurfacePalette.contentBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailSection: some View {
        Group {
            if model.isHistoryDetailLoading {
                ProgressView(L10n.tr("Loading job..."))
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HistoryDetailView(job: model.selectedJob(), files: model.selectedJobFiles)
            }
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedJobBinding: Binding<String?> {
        Binding {
            model.selectedJobID
        } set: { selectedJobID in
            guard let selectedJobID, selectedJobID != model.selectedJobID else {
                return
            }
            model.loadJobDetail(jobID: selectedJobID)
        }
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case success
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return L10n.tr("All")
        case .success:
            return L10n.tr("Success")
        case .failed:
            return L10n.tr("Failed")
        }
    }

    func includes(_ job: ImportJob) -> Bool {
        switch self {
        case .all:
            return true
        case .success:
            return job.failedFiles == 0 && job.status == .imported
        case .failed:
            return job.failedFiles > 0
                || job.status == .failed
                || job.status == .cancelled
                || job.status == .importedWithErrors
        }
    }
}

private struct HistoryRow: View {
    let job: ImportJob

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.failedFiles > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(job.failedFiles > 0 ? .red : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(HistoryJobPresentation.title(for: job))
                    .lineLimit(1)
                Text(HistoryJobPresentation.subtitle(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
