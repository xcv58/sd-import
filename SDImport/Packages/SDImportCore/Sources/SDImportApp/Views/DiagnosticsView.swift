import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingPruneConfirmation = false

    var body: some View {
        AppPage(
            title: "Diagnostics",
            status: model.setupError ?? model.statusMessage,
            statusRole: model.setupError == nil ? .neutral : .error
        ) {
            VStack(alignment: .leading, spacing: 18) {
                AppSection("Folders", systemImage: "folder") {
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
                }

                AppSection("Maintenance", systemImage: "wrench.and.screwdriver") {
                    HStack {
                        Button {
                            model.pruneHistory(dryRun: true)
                        } label: {
                            Label("Dry Run Prune", systemImage: "doc.text.magnifyingglass")
                        }

                        Button(role: .destructive) {
                            isShowingPruneConfirmation = true
                        } label: {
                            Label("Prune History", systemImage: "trash")
                        }
                        .alert("Prune old history?", isPresented: $isShowingPruneConfirmation) {
                            Button("Prune History", role: .destructive) {
                                model.pruneHistory(dryRun: false)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This deletes old SD Import job records using the current retention setting. Copied media files are not deleted.")
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
