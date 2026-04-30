import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Diagnostics")
                .font(.title)
                .fontWeight(.semibold)

            Text(model.setupError ?? model.statusMessage)
                .foregroundStyle(model.setupError == nil ? Color.secondary : Color.red)
                .textSelection(.enabled)

            HStack {
                Button {
                    model.revealPhotosFolder()
                } label: {
                    Label("Reveal Photos", systemImage: "photo")
                }
                Button {
                    model.revealVideosFolder()
                } label: {
                    Label("Reveal Videos", systemImage: "video")
                }
            }

            HStack {
                Button {
                    model.pruneHistory(dryRun: true)
                } label: {
                    Label("Dry Run Prune", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    model.pruneHistory(dryRun: false)
                } label: {
                    Label("Prune History", systemImage: "trash")
                }
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("Diagnostics")
    }
}
