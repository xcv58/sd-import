import SDImportCore
import SwiftUI

struct ImportPlanCopyPills: View {
    let totals: ImportPreviewTotals

    var body: some View {
        InfoPill(
            title: totals.copyFiles == 1 ? L10n.tr("1 file ready") : L10n.tr("\(totals.copyFiles) files ready"),
            systemImage: "arrow.down.circle",
            role: .success
        )
        InfoPill(title: L10n.fileSize(totals.copyBytes), systemImage: "externaldrive")
    }
}

struct ImportPlanOptionRow<Content: View>: View {
    let title: String
    let maximumControlWidth: CGFloat?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        maximumControlWidth: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.maximumControlWidth = maximumControlWidth
        self.content = content
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ImportFormLayout.columnSpacing) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: ImportFormLayout.labelWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                control
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                control
            }
        }
    }

    private var control: some View {
        content()
            .frame(
                minWidth: ImportFormLayout.minimumControlWidth,
                idealWidth: maximumControlWidth,
                maxWidth: maximumControlWidth ?? .infinity
            )
    }
}
