import SDImportCore
import SwiftUI

struct SourceEjectionControl: View {
    let sourceName: String
    let volumeCount: Int
    let isEjected: Bool
    let isEjecting: Bool
    let canEject: Bool
    let eject: () -> Void

    var body: some View {
        if isEjected {
            AppStatusLabel(
                title: L10n.tr("\(sourceName) Ejected — Safe to Remove"),
                systemImage: "checkmark.circle.fill",
                role: .success
            )
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(L10n.tr("\(sourceName) ejected. Safe to remove."))
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ejectButton
                    guidance
                }

                VStack(alignment: .leading, spacing: 6) {
                    ejectButton
                    guidance
                }
            }
        }
    }

    private var ejectButton: some View {
        Button(action: eject) {
            Label(
                isEjecting ? L10n.tr("Ejecting \(sourceName)…") : ejectButtonTitle,
                systemImage: "eject.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canEject)
        .accessibilityHint(
            volumeCount > 1
                ? L10n.tr("Safely unmounts all source volumes")
                : L10n.tr("Safely unmounts the source volume")
        )
    }

    private var guidance: some View {
        Text(
            volumeCount > 1
                ? L10n.tr("Unmounts all \(volumeCount) storage volumes before disconnecting the device.")
                : L10n.tr("Eject the card before removing it.")
        )
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var ejectButtonTitle: String {
        if volumeCount > 1 {
            return L10n.tr("Eject \(sourceName) — \(volumeCount) Volumes")
        }
        return L10n.tr("Eject “\(sourceName)”")
    }
}
