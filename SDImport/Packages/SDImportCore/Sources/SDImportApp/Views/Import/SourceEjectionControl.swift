import SwiftUI

struct SourceEjectionControl: View {
    let sourceName: String
    let isEjected: Bool
    let isEjecting: Bool
    let canEject: Bool
    let eject: () -> Void

    var body: some View {
        if isEjected {
            Label("\(sourceName) Ejected — Safe to Remove", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("\(sourceName) ejected. Safe to remove.")
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
                isEjecting ? "Ejecting \(sourceName)…" : "Eject “\(sourceName)”",
                systemImage: "eject.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canEject)
        .accessibilityHint("Safely unmounts the source card")
    }

    private var guidance: some View {
        Text("Safely unmount the card before removing it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
