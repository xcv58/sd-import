import SDImportCore
import SwiftUI

struct ImportProgressPanel: View {
    let progress: ImportProgress

    private var fractionComplete: Double {
        min(1, max(0, progress.percent / 100))
    }

    private var percentText: String {
        "\(Int(progress.percent.rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Import Progress")
                    .font(.headline)
                Spacer()
                Text(percentText)
                    .font(.headline)
                    .monospacedDigit()
            }

            ProgressView(value: fractionComplete)
                .progressViewStyle(.linear)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                ProgressMetric(title: "Processed", value: copiedText)
                ProgressMetric(title: "Speed", value: speedText)
                ProgressMetric(title: "Remaining", value: remainingText)
                ProgressMetric(title: "Files", value: fileCountText)
            }

            if let currentFilename = progress.currentFilename, !currentFilename.isEmpty {
                Label(currentFilename, systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var copiedText: String {
        "\(Self.bytes(progress.processedBytes)) of \(Self.bytes(progress.totalBytes))"
    }

    private var speedText: String {
        guard progress.throughputBytesPerSecond > 1 else {
            return "Estimating"
        }
        return "\(Self.bytes(Int64(progress.throughputBytesPerSecond)))/s"
    }

    private var remainingText: String {
        if progress.status == "completed" || progress.status == "completed_with_errors" || fractionComplete >= 1 {
            return "Complete"
        }
        guard let etaSeconds = progress.etaSeconds else {
            return "Estimating"
        }
        return Self.duration(etaSeconds)
    }

    private var fileCountText: String {
        "\(progress.doneFiles) of \(progress.totalFiles)"
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func duration(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded(.up)))
        if rounded < 1 {
            return "<1s"
        }
        if rounded < 60 {
            return "\(rounded)s"
        }

        let minutes = rounded / 60
        let remainderSeconds = rounded % 60
        if minutes < 60 {
            return "\(minutes)m \(remainderSeconds)s"
        }

        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        return "\(hours)h \(remainderMinutes)m"
    }
}

private struct ProgressMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
