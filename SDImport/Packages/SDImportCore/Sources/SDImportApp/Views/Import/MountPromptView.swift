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

            HStack {
                Spacer()
                Button("Skip") {
                    skipAction()
                }
                Button("Continue") {
                    continueAction()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
