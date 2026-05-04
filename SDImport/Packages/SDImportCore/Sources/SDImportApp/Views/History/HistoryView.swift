import SDImportCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: HistoryFilter = .all

    private var filteredJobs: [ImportJob] {
        model.jobs.filter(\.isImportHistoryEntry).filter(filter.includes)
    }

    var body: some View {
        AppPage(title: "History", status: model.statusMessage, scrolls: false, maxContentWidth: .infinity) {
            historyLayout
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.refreshHistory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isHistoryLoading)

                Button {
                    model.retrySelectedJob()
                } label: {
                    Label("Retry", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.isWorking || model.selectedJob()?.canRetryImport != true)
            }
        }
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
        GeometryReader { proxy in
            if proxy.size.width >= 760 {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        recentJobsSection
                    }
                    .frame(width: 360)

                    ScrollView {
                        detailSection
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailSection
                        recentJobsSection
                    }
                }
            }
        }
        .frame(minHeight: 320, maxHeight: .infinity)
    }

    private var recentJobsSection: some View {
        AppSection("Recent Imports", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Filter", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if model.isHistoryLoading {
                    ProgressView("Loading history...")
                        .controlSize(.small)
                }

                if filteredJobs.isEmpty {
                    ContentUnavailableView(
                        model.isHistoryLoading ? "Loading History" : "No Import History",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredJobs) { job in
                            Button {
                                model.loadJobDetail(jobID: job.id)
                            } label: {
                                HistoryRow(job: job, isSelected: model.selectedJobID == job.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(HistoryJobPresentation.title(for: job)), \(HistoryJobPresentation.subtitle(for: job))")
                            .accessibilityValue(model.selectedJobID == job.id ? "Selected" : "")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Job Details", systemImage: "doc.text.magnifyingglass")
                .font(.headline)

            if model.isHistoryDetailLoading {
                ProgressView("Loading job...")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                HistoryDetailView(job: model.selectedJob(), files: model.selectedJobFiles)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            return "All"
        case .success:
            return "Success"
        case .failed:
            return "Failed"
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
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.failedFiles > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(job.failedFiles > 0 ? .orange : .secondary)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
