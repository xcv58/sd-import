import SDImportCore
import SwiftUI

struct ScanSummaryView: View {
    let summary: ScanSummary

    var body: some View {
        AppSection("Scan Summary", systemImage: "checklist") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                MetricView(title: "Scanned", value: summary.scannedFiles)
                MetricView(title: "New", value: summary.newFiles)
                MetricView(title: "Known", value: summary.knownFiles)
                MetricView(title: "Conflicts", value: summary.conflictFiles)
                MetricView(title: "Unsupported", value: summary.unsupportedFiles)
            }

            Text(summary.jobID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct MetricView: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title2)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
