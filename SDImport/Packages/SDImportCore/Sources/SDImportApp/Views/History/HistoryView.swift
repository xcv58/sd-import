import SDImportCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: HistoryFilter = .all

    private var filteredJobs: [ImportJob] {
        model.jobs.filter(filter.includes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Filter", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                if filteredJobs.isEmpty {
                    ContentUnavailableView("No Import History", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Jobs")
                            .font(.headline)
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(filteredJobs) { job in
                                HistoryRow(job: job, isSelected: model.selectedJobID == job.id)
                                    .onTapGesture {
                                        model.loadJobDetail(jobID: job.id)
                                    }
                            }
                        }
                    }

                    Divider()

                    HistoryDetailView(job: model.selectedJob(), files: model.selectedJobFiles)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("History")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.refreshHistory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    model.retrySelectedJob()
                } label: {
                    Label("Retry", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.selectedJobID == nil)
            }
        }
        .onAppear {
            model.refreshHistory()
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
            return job.failedFiles == 0 && (job.status == .imported || job.status == .scanned)
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
                Text(job.volumeName ?? job.id)
                    .lineLimit(1)
                Text("\(job.status.databaseValue) · \(job.newFiles) new · \(job.failedFiles) failed")
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
