import SDImportCore
import SwiftUI

struct ManualImportView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                pathSection
                actionSection

                if let progress = model.importProgress {
                    ImportProgressPanel(progress: progress)
                }

                if let summary = model.currentSummary {
                    ScanSummaryView(summary: summary)
                    ImportPreviewView()
                }

                if let result = model.currentResult {
                    ImportResultView(result: result)
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Import")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.scan()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .disabled(!model.canScan)

                Button {
                    model.importCurrentJob()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.canImportPlannedFiles)
            }
        }
        .onAppear {
            model.refreshAvailableSourceVolumes()
            model.validatePaths()
        }
        .onChange(of: model.cardPath) {
            model.sourcePathDidChange()
        }
        .onChange(of: model.photosPath) {
            model.validatePaths()
        }
        .onChange(of: model.videosPath) {
            model.validatePaths()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual Import")
                .font(.title)
                .fontWeight(.semibold)
            Text(model.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private var pathSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Card or source")
                    .foregroundStyle(.secondary)
                SourceField()
            }

            switch model.organizationPreset {
            case .classicDatedFolders:
                GridRow {
                    Text("Photos")
                        .foregroundStyle(.secondary)
                    FolderField(
                        path: $model.photosPath,
                        validation: model.photosValidation,
                        action: model.choosePhotosFolder
                    )
                }
                GridRow {
                    Text("Videos")
                        .foregroundStyle(.secondary)
                    FolderField(
                        path: $model.videosPath,
                        validation: model.videosValidation,
                        action: model.chooseVideosFolder
                    )
                }
            case .shootSessionsByDate:
                GridRow {
                    Text("Library")
                        .foregroundStyle(.secondary)
                    FolderField(
                        path: $model.photosPath,
                        validation: model.photosValidation,
                        action: model.choosePhotosFolder
                    )
                }
            case .footageBackup:
                GridRow {
                    Text("Footage")
                        .foregroundStyle(.secondary)
                    FolderField(
                        path: $model.videosPath,
                        validation: model.videosValidation,
                        action: model.chooseVideosFolder
                    )
                }
            }

            GridRow {
                Text("Location")
                    .foregroundStyle(.secondary)
                TextField("Location", text: $model.location)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons
            }

            VStack(alignment: .leading, spacing: 10) {
                actionButtons
            }
        }
    }

    private var actionButtons: some View {
        Group {
            Button {
                model.scan()
            } label: {
                Label("Scan Card", systemImage: "magnifyingglass")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canScan)

            Button {
                model.importCurrentJob()
            } label: {
                Label("Import Planned Files", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.canImportPlannedFiles)

            if model.isWorking, model.importProgress != nil {
                Button {
                    model.cancelImport()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }

            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct SourceField: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Card or source path", text: $model.cardPath)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .frame(minWidth: 180, maxWidth: 420)

                Menu {
                    if model.availableSourceVolumes.isEmpty {
                        Text("No cards detected")
                    } else {
                        ForEach(model.availableSourceVolumes) { volume in
                            Button {
                                model.selectSourceVolume(volume)
                            } label: {
                                Text(volume.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "sdcard")
                }
                .help("Select mounted card")

                Button {
                    model.refreshAvailableSourceVolumes()
                    model.validatePaths()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh mounted cards")

                Button {
                    model.chooseCardFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose source folder")
            }

            ValidationStatusView(result: model.sourceValidation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FolderField: View {
    @Binding var path: String
    let validation: PathValidationResult
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Folder path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .frame(minWidth: 180, maxWidth: 420)
                Button {
                    action()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose folder")
            }

            ValidationStatusView(result: validation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ValidationStatusView: View {
    let result: PathValidationResult

    var body: some View {
        Label(result.message, systemImage: result.isUsable ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(result.isUsable ? Color.secondary : Color.orange)
            .lineLimit(1)
    }
}
