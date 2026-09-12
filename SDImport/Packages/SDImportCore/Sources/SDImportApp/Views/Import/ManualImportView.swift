import SDImportCore
import SwiftUI

struct ManualImportView: View {
    @EnvironmentObject private var model: AppModel
    @AccessibilityFocusState private var phaseHeadingIsFocused: Bool

    var body: some View {
        Group {
            switch model.importUIPhase {
            case .source:
                sourcePage
            case .scanning:
                scanningPage
            case .review:
                ImportPreviewView()
            case .preparing:
                preparingPage
            case .copying:
                copyingPage
            case .completed:
                completionPage
            case .failed, .cancelled:
                recoveryPage
            }
        }
        .navigationTitle(L10n.tr("Import"))
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
        .onChange(of: model.importUIPhase) {
            phaseHeadingIsFocused = true
        }
    }

    private var sourcePage: some View {
        AppPage(status: visibleStatus) {
            VStack(alignment: .leading, spacing: 18) {
                phaseHeading(L10n.tr("Choose a source"), detail: L10n.tr("Select a card or folder, then scan it before anything is copied."))
                sourceSection
            }
        }
    }

    private var scanningPage: some View {
        AppPage {
            VStack(alignment: .leading, spacing: 18) {
                phaseHeading(L10n.tr("Scanning source"), detail: L10n.tr("Reading media and checking previous imports."))
                ImportSourceSummaryView(allowsChange: false)
                AppSection(L10n.tr("Scanning"), systemImage: "magnifyingglass") {
                    ProgressView()
                        .controlSize(.small)
                    Button(role: .cancel) {
                        model.cancelImport()
                    } label: {
                        Label(L10n.tr("Cancel Scan"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("import.cancel.scan")
                }
            }
        }
    }

    private var preparingPage: some View {
        AppPage {
            VStack(alignment: .leading, spacing: 18) {
                phaseHeading(L10n.tr("Preparing import"), detail: model.statusMessage)
                AppSection(L10n.tr("Preparing"), systemImage: "gearshape.2") {
                    ProgressView()
                        .controlSize(.small)
                    Button(role: .cancel) {
                        model.cancelImport()
                    } label: {
                        Label(L10n.tr("Cancel"), systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("import.cancel.preparation")
                }
            }
        }
    }

    @ViewBuilder
    private var copyingPage: some View {
        if let progress = model.importProgress {
            AppPage {
                VStack(alignment: .leading, spacing: 18) {
                    phaseHeading(L10n.tr("Copying files"), detail: L10n.tr("Keep the source connected until copying finishes."))
                    ImportProgressPanel(progress: progress) {
                        model.cancelImport()
                    }
                }
            }
        } else {
            preparingPage
        }
    }

    @ViewBuilder
    private var completionPage: some View {
        if let result = model.currentResult {
            AppPage {
                VStack(alignment: .leading, spacing: 18) {
                    phaseHeading(
                        result.failedFiles == 0 ? L10n.tr("Import complete") : L10n.tr("Completed with errors"),
                        detail: result.failedFiles == 0
                            ? L10n.tr("Your copied files are ready.")
                            : L10n.tr("Review the failed files before removing the source.")
                    )
                    ImportResultView(result: result)
                }
            }
        } else {
            recoveryPage
        }
    }

    private var recoveryPage: some View {
        AppPage {
            VStack(alignment: .leading, spacing: 18) {
                phaseHeading(
                    model.importUIPhase == .cancelled ? L10n.tr("Operation cancelled") : L10n.tr("Import needs attention"),
                    detail: model.importFailure?.message ?? model.statusMessage
                )

                AppSection(
                    model.importUIPhase == .cancelled ? L10n.tr("Cancelled") : L10n.tr("Couldn’t Continue"),
                    systemImage: model.importUIPhase == .cancelled ? "xmark.circle" : "exclamationmark.triangle"
                ) {
                    Text(model.importFailure?.message ?? model.statusMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        if model.importUIPhase == .failed {
                            Button(L10n.tr("Retry")) {
                                model.retryFailedImportOperation()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button(recoveryButtonTitle) {
                            if model.currentResult != nil {
                                model.recoverImportReceipt()
                            } else {
                                model.recoverImportWorkspace()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func phaseHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .accessibilityFocused($phaseHeadingIsFocused)
                .accessibilityIdentifier("import.phase.\(model.importUIPhase.rawValue).heading")
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoveryButtonTitle: String {
        if model.currentResult != nil {
            return L10n.tr("Back to Receipt")
        }
        return model.currentSummary == nil ? L10n.tr("Back to Source") : L10n.tr("Back to Review")
    }

    private var visibleStatus: String? {
        guard model.statusMessage != L10n.tr("Ready"), !model.statusMessage.isEmpty else {
            return nil
        }
        return model.statusMessage
    }

    private var sourceSection: some View {
        AppSection(L10n.tr("Source"), systemImage: "externaldrive") {
            SourceField()

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
        .disabled(model.isWorking || model.isEjectingSource)
    }

    private var sourceActions: some View {
        Group {
            Button {
                model.scan()
            } label: {
                Label(scanButtonTitle, systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canScan)
            .accessibilityIdentifier("import.scan")

            if model.shouldOfferSelectedSourceEjection {
                Button {
                    model.ejectSelectedSource()
                } label: {
                    Label(model.selectedSourceEjectionButtonTitle, systemImage: "eject.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canEjectSelectedSource)
                .accessibilityHint(L10n.tr("Safely unmounts all storage volumes on the selected source device"))
            }

        }
    }

    private var scanButtonTitle: String {
        model.currentSummary == nil ? L10n.tr("Scan Card") : L10n.tr("Scan Again")
    }
}

struct ImportSourceSummaryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isConfirmingSourceChange = false

    var allowsChange = true
    var allowsRescan = false
    var compact = false

    var body: some View {
        Group {
            if compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(.secondary)
                        sourceIdentity
                        Spacer(minLength: 12)
                        actions
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            sourceIdentity
                        } icon: {
                            Image(systemName: "externaldrive")
                                .foregroundStyle(.secondary)
                        }
                        actions
                    }
                }
                .padding(12)
                .appCardSurface()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.tr("Source"))
            } else {
                AppSection(L10n.tr("Source"), systemImage: "externaldrive") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            sourceIdentity
                            Spacer(minLength: 12)
                            actions
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            sourceIdentity
                            actions
                        }
                    }
                }
            }
        }
        .alert(L10n.tr("Change source?"), isPresented: $isConfirmingSourceChange) {
            Button(L10n.tr("Change Source")) {
                model.sourcePathDidChange()
            }
            Button(L10n.tr("Keep Review"), role: .cancel) {}
        } message: {
            Text(L10n.tr("The current scan and review will be discarded. No copied files are deleted."))
        }
    }

    private var sourceIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sourceTitle)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(sourceDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.cardPath)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("Source, \(sourceTitle), \(sourceDetail)"))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if allowsRescan {
                Button {
                    model.scan()
                } label: {
                    Label(L10n.tr("Scan Again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canScan)
            }

            if model.shouldOfferSelectedSourceEjection {
                Button {
                    model.ejectSelectedSource()
                } label: {
                    Label(L10n.tr("Eject"), systemImage: "eject")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canEjectSelectedSource)
            }

            if allowsChange {
                Button(L10n.tr("Change…")) {
                    isConfirmingSourceChange = true
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking || model.isEjectingSource)
            }
        }
    }

    private var sourceTitle: String {
        model.selectedSourceVolume?.name
            ?? URL(fileURLWithPath: model.cardPath, isDirectory: true).lastPathComponent.nilIfBlank
            ?? L10n.tr("Source Folder")
    }

    private var sourceDetail: String {
        if let volume = model.selectedSourceVolume {
            return volume.detailText
        }
        if let summary = model.currentSummary {
            return L10n.tr("\(summary.scannedFiles) scanned files · \(model.cardPath)")
        }
        return model.cardPath
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}

enum ImportFormLayout {
    static let labelWidth: CGFloat = 92
    static let columnSpacing: CGFloat = 14
    static let minimumControlWidth: CGFloat = 180
    static let compactSegmentedControlWidth: CGFloat = 420
}

struct ImportDestinationFields: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: ImportFormLayout.columnSpacing,
            verticalSpacing: 12
        ) {
            GridRow {
                Text(L10n.tr("Shoot"))
                    .foregroundStyle(.secondary)
                    .frame(width: ImportFormLayout.labelWidth, alignment: .leading)
                ShootNameField(name: $model.location)
            }

            switch model.importMediaSelection {
            case .photosAndVideos:
                switch model.destinationLayout {
                case .singleLibrary:
                    GridRow {
                        Text(L10n.tr("Library"))
                            .foregroundStyle(.secondary)
                            .frame(width: ImportFormLayout.labelWidth, alignment: .leading)
                        FolderField(
                            title: L10n.tr("Library"),
                            path: $model.photosPath,
                            validation: model.photosValidation,
                            recentChoices: model.recentPhotosPathSuggestions,
                            selectRecentPath: model.selectPhotosPath,
                            action: model.choosePhotosFolder
                        )
                    }
                case .separateMediaFolders:
                    GridRow {
                        Text(L10n.tr("Photos"))
                            .foregroundStyle(.secondary)
                            .frame(width: ImportFormLayout.labelWidth, alignment: .leading)
                        FolderField(
                            title: L10n.tr("Photos"),
                            path: $model.photosPath,
                            validation: model.photosValidation,
                            recentChoices: model.recentPhotosPathSuggestions,
                            selectRecentPath: model.selectPhotosPath,
                            action: model.choosePhotosFolder
                        )
                    }

                    GridRow {
                        Text(L10n.tr("Videos"))
                            .foregroundStyle(.secondary)
                            .frame(width: ImportFormLayout.labelWidth, alignment: .leading)
                        FolderField(
                            title: L10n.tr("Videos"),
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
                    Text(L10n.tr("Photos"))
                        .foregroundStyle(.secondary)
                        .frame(width: ImportFormLayout.labelWidth, alignment: .leading)
                    FolderField(
                        title: L10n.tr("Photos"),
                        path: $model.photosPath,
                        validation: model.photosValidation,
                        recentChoices: model.recentPhotosPathSuggestions,
                        selectRecentPath: model.selectPhotosPath,
                        action: model.choosePhotosFolder
                    )
                }
            case .videosOnly:
                GridRow {
                    Text(L10n.tr("Videos"))
                        .foregroundStyle(.secondary)
                        .frame(width: ImportFormLayout.labelWidth, alignment: .leading)
                    FolderField(
                        title: L10n.tr("Videos"),
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SourceField: View {
    @EnvironmentObject private var model: AppModel
    @State private var isManagingRecentSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    sourcePathField
                    sourceControls
                }

                VStack(alignment: .leading, spacing: 8) {
                    sourcePathField
                    sourceControls
                }
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

    private var sourcePathField: some View {
        TextField(L10n.tr("Card or source path"), text: $model.cardPath)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .frame(minWidth: 180, maxWidth: 420)
    }

    private var sourceControls: some View {
        HStack(spacing: 8) {
            sourceMenu

            Button {
                model.refreshAvailableSourceVolumes()
                model.validatePaths()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(L10n.tr("Refresh mounted cards"))
            .accessibilityLabel(L10n.tr("Refresh mounted cards"))

            Button {
                model.chooseCardFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help(L10n.tr("Choose source folder"))
            .accessibilityLabel(L10n.tr("Choose source folder"))
        }
    }

    private var sourceMenu: some View {
        Menu {
            if model.availableSourceVolumes.isEmpty && model.recentSourcePathSuggestions.isEmpty {
                Text(L10n.tr("No cards or recent sources"))
            }

            if !model.availableSourceVolumes.isEmpty {
                Section(L10n.tr("Mounted Cards")) {
                    ForEach(model.availableSourceDeviceGroups) { group in
                        ForEach(group.volumes) { volume in
                            Button {
                                model.selectSourceVolume(volume)
                            } label: {
                                Text(
                                    volume.menuTitle(
                                        deviceName: group.isMultiVolume ? group.displayName : nil
                                    )
                                )
                            }
                        }
                    }
                }
            }

            if !model.recentSourcePathSuggestions.isEmpty {
                Section(L10n.tr("Recent Sources")) {
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
                Label(L10n.tr("Manage Recent Sources..."), systemImage: "slider.horizontal.3")
            }
            .disabled(model.recentSourcePathSuggestions.isEmpty)

            if model.hasForgottenRecentPaths {
                Button {
                    model.restoreForgottenRecentPaths()
                } label: {
                    Label(L10n.tr("Show Forgotten Folders Again"), systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label(sourceMenuTitle, systemImage: "sdcard")
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
        }
        .help(L10n.tr("Select source"))
        .accessibilityLabel(L10n.tr("Select source"))
        .sheet(isPresented: $isManagingRecentSources) {
            RecentPathManagementSheet(
                title: L10n.tr("Recent Sources"),
                choices: model.recentSourcePathSuggestions,
                selectRecentPath: model.selectSourcePath,
                forgetRecentPath: model.forgetRecentPath
            )
        }
    }

    private var sourceMenuTitle: String {
        model.selectedSourceVolume?.name ?? L10n.tr("Sources")
    }
}

private extension MountedVolume {
    func menuTitle(deviceName: String?) -> String {
        let identity = if let deviceName {
            "\(name) · \(deviceName)"
        } else {
            name
        }

        if let capacityText {
            return "\(identity) · \(capacityText)"
        }
        return identity
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
            return L10n.tr("\(available) free, \(used) used of \(total)")
        }

        return L10n.tr("\(available) free")
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
                TextField(L10n.tr("\(title) folder path"), text: $path)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .frame(
                        minWidth: ImportFormLayout.minimumControlWidth,
                        maxWidth: .infinity
                    )

                Menu {
                    if recentChoices.isEmpty {
                        Text(L10n.tr("No recent folders"))
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
                        Label(L10n.tr("Manage Recent Folders..."), systemImage: "slider.horizontal.3")
                    }
                    .disabled(recentChoices.isEmpty)

                    if model.hasForgottenRecentPaths {
                        Button {
                            model.restoreForgottenRecentPaths()
                        } label: {
                            Label(L10n.tr("Show Forgotten Folders Again"), systemImage: "arrow.uturn.backward")
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help(L10n.tr("Choose recent \(title) folder"))
                .accessibilityLabel(L10n.tr("Choose recent \(title) folder"))
                .fixedSize()
                .sheet(isPresented: $isManagingRecentFolders) {
                    RecentPathManagementSheet(
                        title: L10n.tr("Recent \(title) Folders"),
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
                .help(L10n.tr("Choose \(title) folder"))
                .accessibilityLabel(L10n.tr("Choose \(title) folder"))
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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

                Button(L10n.tr("Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            if choices.isEmpty {
                ContentUnavailableView(L10n.tr("No Recent Folders"), systemImage: "clock.arrow.circlepath")
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
                Label(L10n.tr("Use"), systemImage: "checkmark")
            }
            .disabled(!suggestion.isAvailable)
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                forgetRecentPath()
            } label: {
                Label(L10n.tr("Forget"), systemImage: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 8)
    }

    private var detailText: String {
        let usage = suggestion.choice.useCount == 1 ? L10n.tr("used once") : L10n.tr("used \(suggestion.choice.useCount) times")
        return "\(suggestion.validation.message) · \(usage)"
    }
}

private struct ValidationStatusView: View {
    let result: PathValidationResult

    var body: some View {
        AppStatusLabel(
            title: result.message,
            systemImage: result.isUsable ? "checkmark.circle" : "exclamationmark.triangle",
            role: result.isUsable ? .neutral : .warning
        )
            .font(.callout)
            .lineLimit(1)
    }
}
