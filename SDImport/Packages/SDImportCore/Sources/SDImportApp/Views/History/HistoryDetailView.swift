import SDImportCore
import SwiftUI

struct HistoryDetailView: View {
    @EnvironmentObject private var model: AppModel
    let job: ImportJob?
    let files: [JobFileRecord]

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
            Text(job.volumeName ?? "Import Job")
                .font(.title2)
                .fontWeight(.semibold)
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
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files")
                .font(.headline)
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.filename)
                        .lineLimit(1)
                    Text("\(file.decision.databaseValue) · \(file.copyStatus.databaseValue) · \(file.relativePath ?? file.sourcePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let error = file.error, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 5)
                Divider()
            }
        }
    }
}
