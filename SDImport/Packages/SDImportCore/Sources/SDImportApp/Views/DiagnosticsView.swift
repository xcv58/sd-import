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

                AppSection(
                    "Diagnostics Export",
                    systemImage: "waveform.path.ecg",
                    subtitle: "Opt-in and redacted"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Exports app version, macOS version, settings, recent job counts, and selected-job file statuses. Media files, file names, and full paths are omitted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Button {
                                model.copyDiagnostics()
                            } label: {
                                Label("Copy Diagnostics", systemImage: "doc.on.doc")
                            }

                            Button {
                                model.exportDiagnostics()
                            } label: {
                                Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                AppSection(
                    "Crash Reports",
                    systemImage: "exclamationmark.triangle",
                    subtitle: "Manual and local"
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SD Import does not upload crash reports. If macOS saved a local report, reveal or export it here and review it before sharing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Button {
                                model.revealCrashReportsFolder()
                            } label: {
                                Label("Reveal Crash Reports", systemImage: "folder")
                            }

                            Button {
                                model.exportLatestCrashReport()
                            } label: {
                                Label("Export Latest Crash Report", systemImage: "square.and.arrow.up")
                            }
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
