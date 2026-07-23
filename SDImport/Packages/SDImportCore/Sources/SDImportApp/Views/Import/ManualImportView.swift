import SDImportCore
import SwiftUI

struct ManualImportView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        AppPage {
            VStack(alignment: .leading, spacing: 18) {
                sourceSection

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

    private var sourceSection: some View {
        AppSection("Source", systemImage: "externaldrive") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Source")
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    SourceField()
                }
            }
            .gridColumnAlignment(.leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    sourceActions
                }

                VStack(alignment: .leading, spacing: 10) {
                    sourceActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceActions: some View {
        Group {
            Button {
                model.scan()
            } label: {
                Label(scanButtonTitle, systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canScan)

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

    private var scanButtonTitle: String {
        model.currentSummary == nil ? "Scan Card" : "Scan Again"
    }
}

struct ImportDestinationFields: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Text("Shoot")
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                ShootNameField(name: $model.location, width: 260)
            }

            switch model.importMediaSelection {
            case .photosAndVideos:
                switch model.destinationLayout {
                case .singleLibrary:
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
                case .separateMediaFolders:
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
                case .footageBackup:
                    EmptyView()
                }
            case .photosOnly:
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
            case .videosOnly:
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
        }
        .gridColumnAlignment(.leading)
    }
}

private struct SourceField: View {
    @EnvironmentObject private var model: AppModel
    @State private var isManagingRecentSources = false

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

                    Divider()

                    Button {
                        isManagingRecentSources = true
                    } label: {
                        Label("Manage Recent Sources...", systemImage: "slider.horizontal.3")
                    }
                    .disabled(model.recentSourcePathSuggestions.isEmpty)

                    if model.hasForgottenRecentPaths {
                        Button {
                            model.restoreForgottenRecentPaths()
                        } label: {
                            Label("Show Forgotten Folders Again", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Label(sourceMenuTitle, systemImage: "sdcard")
                }
                .fixedSize(horizontal: true, vertical: false)
                .help("Select source")
                .accessibilityLabel("Select source")
                .sheet(isPresented: $isManagingRecentSources) {
                    RecentPathManagementSheet(
                        title: "Recent Sources",
                        choices: model.recentSourcePathSuggestions,
                        selectRecentPath: model.selectSourcePath,
                        forgetRecentPath: model.forgetRecentPath
                    )
                }

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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ValidationStatusView(result: model.sourceValidation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceMenuTitle: String {
        model.selectedSourceVolume?.name ?? "Sources"
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
    @EnvironmentObject private var model: AppModel
    @State private var isManagingRecentFolders = false

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

                    Divider()

                    Button {
                        isManagingRecentFolders = true
                    } label: {
                        Label("Manage Recent Folders...", systemImage: "slider.horizontal.3")
                    }
                    .disabled(recentChoices.isEmpty)

                    if model.hasForgottenRecentPaths {
                        Button {
                            model.restoreForgottenRecentPaths()
                        } label: {
                            Label("Show Forgotten Folders Again", systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Choose recent \(title.lowercased()) folder")
                .accessibilityLabel("Choose recent \(title.lowercased()) folder")
                .sheet(isPresented: $isManagingRecentFolders) {
                    RecentPathManagementSheet(
                        title: "Recent \(title) Folders",
                        choices: recentChoices,
                        selectRecentPath: selectRecentPath,
                        forgetRecentPath: model.forgetRecentPath
                    )
                }

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

private struct RecentPathManagementSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let choices: [RecentPathSuggestion]
    let selectRecentPath: (String) -> Void
    let forgetRecentPath: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            if choices.isEmpty {
                ContentUnavailableView("No Recent Folders", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(choices) { suggestion in
                            RecentPathManagementRow(
                                suggestion: suggestion,
                                selectRecentPath: {
                                    selectRecentPath(suggestion.path)
                                    dismiss()
                                },
                                forgetRecentPath: {
                                    forgetRecentPath(suggestion.path)
                                }
                            )

                            if suggestion.id != choices.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 180, idealHeight: 260, maxHeight: 320)
                .appCardSurface()
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 260)
    }
}

private struct RecentPathManagementRow: View {
    let suggestion: RecentPathSuggestion
    let selectRecentPath: () -> Void
    let forgetRecentPath: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.isAvailable ? "folder" : "exclamationmark.triangle")
                .foregroundStyle(suggestion.isAvailable ? Color.secondary : Color.orange)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.displayName)
                    .lineLimit(1)

                Text(suggestion.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Button {
                selectRecentPath()
            } label: {
                Label("Use", systemImage: "checkmark")
            }
            .disabled(!suggestion.isAvailable)
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                forgetRecentPath()
            } label: {
                Label("Forget", systemImage: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
    }

    private var detailText: String {
        let usage = suggestion.choice.useCount == 1 ? "used once" : "used \(suggestion.choice.useCount) times"
        return "\(suggestion.validation.message) · \(usage)"
    }
}

private struct ValidationStatusView: View {
    let result: PathValidationResult

    var body: some View {
        Label(result.message, systemImage: result.isUsable ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(result.isUsable ? Color.secondary : Color.orange)
            .lineLimit(1)
    }
}
