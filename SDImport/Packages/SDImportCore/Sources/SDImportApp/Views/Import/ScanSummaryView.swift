import SDImportCore
import SwiftUI

struct ScanSummaryView: View {
    let summary: ScanSummary

    var body: some View {
        AppSection(L10n.tr("Scan Summary"), systemImage: "checklist") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                MetricView(title: L10n.tr("Scanned"), value: summary.scannedFiles)
                MetricView(title: L10n.tr("New"), value: summary.newFiles)
                MetricView(title: L10n.tr("Known"), value: summary.knownFiles)
                if let portableKnownFiles = summary.portableKnownFiles, portableKnownFiles > 0 {
                    MetricView(title: L10n.tr("Other Mac"), value: portableKnownFiles)
                }
                MetricView(title: L10n.tr("Conflicts"), value: summary.conflictFiles)
                MetricView(title: L10n.tr("Unsupported"), value: summary.unsupportedFiles)
            }

            Text(summary.jobID)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let warning = summary.portableReceiptWarning {
                AppStatusLabel(
                    title: warning,
                    systemImage: "exclamationmark.triangle",
                    role: .warning
                )
                    .font(.callout)
            } else if let portableKnownFiles = summary.portableKnownFiles, portableKnownFiles > 0 {
                AppStatusLabel(
                    title: portableKnownFiles == 1
                        ? L10n.tr("1 file was previously imported on another Mac")
                        : L10n.tr("\(portableKnownFiles) files were previously imported on another Mac"),
                    systemImage: "externaldrive.badge.checkmark",
                    role: .neutral
                )
                    .font(.callout)
            }
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
