import SDImportCore
import SwiftUI

struct ManualImportView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppPage(title: "Import", status: model.statusMessage) {
            VStack(alignment: .leading, spacing: 18) {
                pathSection
                actionSection

                if let progress = model.importProgress {
                    ImportProgressPanel(progress: progress)
                }

                if let summary = model.currentSummary, model.importProgress == nil {
                    ScanSummaryView(summary: summary)
                    ImportPreviewView()
                }

                if let result = model.currentResult {
                    ImportResultView(result: result)
                }
            }
        }
        .navigationTitle("Import")
        .onAppear {
            model.refreshAvailableSourceVolumes()
            model.validatePaths()
        }
        .onChange(of: model.cardPath) {
            model.sourcePathDidChange()
        }
        .onChange(of: model.photosPath) {
            model.destinationPathDidChange()
        }
        .onChange(of: model.videosPath) {
            model.destinationPathDidChange()
        }
    }

    private var pathSection: some View {
        AppSection("Source and Destination", systemImage: "externaldrive") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Source")
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    SourceField()
                }

                switch model.organizationPreset {
                case .classicDatedFolders:
                    if model.importMediaSelection.includes(.photo) {
                        GridRow {
                            Text("Photos")
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .leading)
                            FolderField(
                                title: "Photos",
                                path: $model.photosPath,
                                validation: model.photosValidation,
                                recentChoices: model.recentPhotosPathSuggestions,
                                selectRecentPath: model.selectPhotosPath,
                                action: model.choosePhotosFolder
                            )
                        }
                    }
                    if model.importMediaSelection.includes(.video) {
                        GridRow {
                            Text("Videos")
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .leading)
                            FolderField(
                                title: "Videos",
                                path: $model.videosPath,
                                validation: model.videosValidation,
                                recentChoices: model.recentVideosPathSuggestions,
                                selectRecentPath: model.selectVideosPath,
                                action: model.chooseVideosFolder
                            )
                        }
                    }
                case .shootSessionsByDate:
                    GridRow {
                        Text("Library")
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        FolderField(
                            title: "Library",
                            path: $model.photosPath,
                            validation: model.photosValidation,
                            recentChoices: model.recentPhotosPathSuggestions,
                            selectRecentPath: model.selectPhotosPath,
                            action: model.choosePhotosFolder
                        )
                    }
                case .footageBackup:
                    GridRow {
                        Text("Footage")
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        FolderField(
                            title: "Footage",
                            path: $model.videosPath,
                            validation: model.videosValidation,
                            recentChoices: model.recentVideosPathSuggestions,
                            selectRecentPath: model.selectVideosPath,
                            action: model.chooseVideosFolder
                        )
                    }
                }

                GridRow {
                    Text("Shoot")
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    ShootNameField(name: $model.location, width: 260)
                }
            }
            .gridColumnAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionSection: some View {
        AppSection("Actions", systemImage: "bolt") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    actionButtons
                }

                VStack(alignment: .leading, spacing: 10) {
                    actionButtons
                }
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
            .buttonStyle(.bordered)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canScan)

            Button {
                model.importCurrentJob()
            } label: {
                Label(importButtonTitle, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canImportPlannedFiles)

            if model.isWorking {
                Button {
                    model.cancelImport()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var importButtonTitle: String {
        let total = model.previewTotals.copyFiles
        guard total > 0 else {
            return "Copy Files"
        }
        return total == 1 ? "Copy 1 File" : "Copy \(total) Files"
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
                    if model.availableSourceVolumes.isEmpty && model.recentSourcePathSuggestions.isEmpty {
                        Text("No cards or recent sources")
                    }

                    if !model.availableSourceVolumes.isEmpty {
                        Section("Mounted Cards") {
                            ForEach(model.availableSourceVolumes) { volume in
                                Button {
                                    model.selectSourceVolume(volume)
                                } label: {
                                    Text(volume.menuTitle)
                                }
                            }
                        }
                    }

                    if !model.recentSourcePathSuggestions.isEmpty {
                        Section("Recent Sources") {
                            ForEach(model.recentSourcePathSuggestions) { suggestion in
                                Button {
                                    model.selectSourcePath(suggestion.path)
                                } label: {
                                    Label(
                                        suggestion.menuTitle,
                                        systemImage: suggestion.isAvailable ? "externaldrive" : "exclamationmark.triangle"
                                    )
                                }
                                .disabled(!suggestion.isAvailable)
                                .help(suggestion.path)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "sdcard")
                }
                .help("Select source")
                .accessibilityLabel("Select source")

                Button {
                    model.refreshAvailableSourceVolumes()
                    model.validatePaths()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh mounted cards")
                .accessibilityLabel("Refresh mounted cards")

                Button {
                    model.chooseCardFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose source folder")
                .accessibilityLabel("Choose source folder")
            }

            if let selectedVolume = model.selectedSourceVolume {
                Label(selectedVolume.detailText, systemImage: "externaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ValidationStatusView(result: model.sourceValidation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension MountedVolume {
    var menuTitle: String {
        if let capacityText {
            return "\(name) · \(capacityText)"
        }
        return name
    }

    var detailText: String {
        if let capacityText {
            return "\(name): \(capacityText) · \(mountURL.path)"
        }
        return "\(name): \(mountURL.path)"
    }

    private var capacityText: String? {
        guard let availableCapacityBytes else {
            return nil
        }

        let available = ByteCountFormatter.string(fromByteCount: availableCapacityBytes, countStyle: .file)
        if let usedCapacityBytes, let totalCapacityBytes {
            let used = ByteCountFormatter.string(fromByteCount: usedCapacityBytes, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalCapacityBytes, countStyle: .file)
            return "\(available) free, \(used) used of \(total)"
        }

        return "\(available) free"
    }
}

private struct FolderField: View {
    let title: String
    @Binding var path: String
    let validation: PathValidationResult
    let recentChoices: [RecentPathSuggestion]
    let selectRecentPath: (String) -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("\(title) folder path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .frame(minWidth: 180, maxWidth: 420)

                Menu {
                    if recentChoices.isEmpty {
                        Text("No recent folders")
                    } else {
                        ForEach(recentChoices) { suggestion in
                            Button {
                                selectRecentPath(suggestion.path)
                            } label: {
                                Label(
                                    suggestion.menuTitle,
                                    systemImage: suggestion.isAvailable ? "folder" : "exclamationmark.triangle"
                                )
                            }
                            .disabled(!suggestion.isAvailable)
                            .help(suggestion.path)
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Choose recent \(title.lowercased()) folder")
                .accessibilityLabel("Choose recent \(title.lowercased()) folder")

                Button {
                    action()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose \(title.lowercased()) folder")
                .accessibilityLabel("Choose \(title.lowercased()) folder")
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
