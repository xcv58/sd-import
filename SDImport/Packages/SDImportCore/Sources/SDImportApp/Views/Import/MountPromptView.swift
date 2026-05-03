import SDImportCore
import SwiftUI

struct MountPromptView: View {
    let volume: MountedVolume
    let continueAction: () -> Void
    let skipAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.name)
                        .font(.headline)
                    Text(volume.mountURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text("SD Import found supported media on this volume. Scan it now to preview what will be copied.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Skip") {
                    skipAction()
                }
                Button("Scan This Card") {
                    continueAction()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
