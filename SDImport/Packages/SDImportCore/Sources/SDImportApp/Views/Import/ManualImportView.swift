import SDImportCore
import SwiftUI

struct ManualImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @AccessibilityFocusState private var phaseHeadingIsFocused: Bool

    var body: some View {
        Group {
            switch model.importUIPhase {
            case .source:
                sourcePage
            case .scanning:
                scanningPage
            case .review:
                if let session = model.scanBothSession {
                    scanBothReviewPage(session)
                } else {
                    ImportPreviewView()
                }
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
        .onChange(of: model.photosPath) {
            model.destinationPathDidChange(clearFeedback: !model.isReviewingScanBothVolume)
        }
        .onChange(of: model.videosPath) {
            model.destinationPathDidChange(clearFeedback: !model.isReviewingScanBothVolume)
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
                if let session = model.scanBothSession {
                    AppSection(session.deviceName, systemImage: "externaldrive") {
                        ForEach(session.entries) { entry in
                            HStack {
                                Text(entry.volume.name).fontWeight(.medium)
                                Spacer()
                                scanBothStatus(entry.state)
                            }
                        }
                    }
                } else {
                    ImportSourceSummaryView(allowsChange: false)
                }
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

    private func scanBothReviewPage(_ session: ScanBothSession) -> some View {
        ImportPreviewView(scanBothStatus: model.ejectedSourceJobID == nil ? nil : visibleStatus) {
            VStack(alignment: .leading, spacing: 14) {
                phaseHeading(L10n.tr("Review import"), detail: session.deviceName)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(session.entries) { entry in
                            scanBothVolumeCard(entry, in: session)
                                .frame(minWidth: 250, idealWidth: 250, maxWidth: .infinity)
                        }
                    }
                    VStack(spacing: 12) {
                        ForEach(session.entries) { entry in
                            scanBothVolumeCard(entry, in: session)
                        }
                    }
                }
                if session.reviewingEntry == nil, AppDistribution.current.supportsSourceEjection {
                    SourceEjectionControl(
                        sourceName: session.deviceName,
                        volumeCount: session.entries.count,
                        isEjected: model.ejectedSourceJobID != nil,
                        isEjecting: model.isEjectingSource,
                        canEject: model.canEjectScanBoth
                    ) {
                        model.ejectScanBoth()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            scanBothReviewFooter(session)
        }
    }

    private func scanBothVolumeCard(_ entry: ScanBothSession.Entry, in session: ScanBothSession) -> some View {
        let isEditing = session.reviewingEntry?.id == entry.id
        return AppSection(entry.volume.name, systemImage: "externaldrive") {
            VStack(alignment: .leading, spacing: 6) {
                scanBothStatus(entry.state)
                if let summary = entry.summary {
                    let scannedPath = URL(fileURLWithPath: summary.mountPath, isDirectory: true).standardizedFileURL.path
                    if scannedPath != entry.volume.mountPath {
                        scanBothPath(scannedPath)
                    }
                    ScanPortableReceiptWarning(summary: summary)
                    if entry.awaitsImport {
                        scanBothPlanSummary(entry, summary: summary, isEditing: isEditing)
                    }
                }
                if model.ejectedSourceJobID == nil, session.removedMountPaths.contains(entry.volume.mountPath) {
                    AppStatusLabel(
                        title: L10n.tr("Card is not mounted"), systemImage: "exclamationmark.triangle", role: .warning
                    )
                }
                if let result = entry.result {
                    scanBothCopySummary(result, interruption: entry.copyInterruption)
                }
            }
            .font(.callout)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { scanBothReviewActions(entry, isEditing: isEditing) }
                VStack(alignment: .leading, spacing: 6) { scanBothReviewActions(entry, isEditing: isEditing) }
            }
        }
        .overlay {
            if isEditing {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func scanBothPlanSummary(_ entry: ScanBothSession.Entry, summary: ScanSummary, isEditing: Bool) -> some View {
        if let readyCount = isEditing ? model.previewTotals.copyFiles : entry.confirmation?.copyFileCount {
            LabeledContent(L10n.tr("Copy"), value: L10n.tr("\(readyCount) files"))
        } else {
            LabeledContent(L10n.tr("New"), value: L10n.tr("\(summary.newFiles) files"))
        }

        let draft = isEditing ? model.currentImportDraft : entry.draft?.settings
        let defaults = model.importDefaults
        let photosPath = draft?.photosPath ?? defaults.photosPath
        let videosPath = draft?.videosPath ?? defaults.videosPath
        switch draft?.mediaSelection ?? defaults.mediaSelection {
        case .photosOnly:
            scanBothDestination(L10n.tr("Destination"), path: photosPath)
        case .videosOnly:
            scanBothDestination(L10n.tr("Destination"), path: videosPath)
        case .photosAndVideos:
            if (draft?.destinationLayout ?? defaults.destinationLayout) == .separateMediaFolders, photosPath != videosPath {
                scanBothDestination(L10n.tr("Photos"), path: photosPath)
                scanBothDestination(L10n.tr("Videos"), path: videosPath)
            } else {
                scanBothDestination(L10n.tr("Library"), path: photosPath)
            }
        }

        let needsAttention = isEditing
            ? model.previewAttentionCount > 0 || model.previewDestinationIssueCount > 0
            : summary.conflictFiles > 0 && entry.confirmation == nil
        if needsAttention {
            AppStatusLabel(title: L10n.tr("Needs attention"), systemImage: "exclamationmark.triangle", role: .warning)
        }
    }

    private func scanBothDestination(_ title: String, path: String) -> some View {
        LabeledContent {
            scanBothPath(path)
        } label: {
            Text(title)
        }
    }

    private func scanBothPath(_ path: String) -> some View {
        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }

    private func scanBothReviewFooter(_ session: ScanBothSession) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                scanBothFooterContext(session)
                Spacer(minLength: 0)
                scanBothFooterActions(session)
            }
            VStack(alignment: .leading, spacing: 8) {
                scanBothFooterContext(session)
                scanBothFooterActions(session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(AppSurfacePalette.contentBackground)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func scanBothFooterContext(_ session: ScanBothSession) -> some View {
        if let entry = session.reviewingEntry {
            Label(entry.volume.name, systemImage: "externaldrive")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        } else {
            Button(L10n.tr("Change Source")) {
                model.changeScanBothSource()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func scanBothFooterActions(_ session: ScanBothSession) -> some View {
        if session.reviewingEntry != nil {
            ImportReviewUpdateControls()
            Button(L10n.tr("Close")) {
                model.returnToScanBothResults()
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
            ImportReviewPrimaryAction()
        } else if session.hasPendingResults {
            Button {
                model.startScanBothImports()
            } label: {
                Label(L10n.tr("Start Imports"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canStartScanBothImports)
            .accessibilityIdentifier("import.scan-both.start")
        }
    }

    @ViewBuilder
    private func scanBothReviewActions(_ entry: ScanBothSession.Entry, isEditing: Bool) -> some View {
        switch entry.disposition {
        case .pending:
            if entry.confirmation != nil, !isEditing {
                Label(L10n.tr("Ready"), systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
            }
            if entry.canSkip {
                Button(L10n.tr("Skip")) {
                    model.skipScanBothImport(entry.id)
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking || model.isEjectingSource)
            }
            if let summary = entry.summary {
                if model.needsRescan(summary.jobID) {
                    Button(L10n.tr("Rescan Source")) {
                        model.rescanSource(startingAt: summary.mountPath, recoveringJobID: summary.jobID)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking || model.isEjectingSource)
                } else if !isEditing {
                    Button(entry.confirmation == nil ? L10n.tr("Review import") : L10n.tr("Edit Plan")) {
                        model.reviewScanBothVolume(entry.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking || model.isEjectingSource)
                    .accessibilityLabel(L10n.tr("Review \(entry.volume.name)"))
                    .accessibilityIdentifier("import.scan-both.review.\(entry.volume.mountPath)")
                }
            }
        case .imported:
            Text(L10n.tr("Imported")).foregroundStyle(.secondary)
        case .skipped:
            Text(L10n.tr("Skipped")).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func scanBothCopySummary(_ result: ImportResult, interruption: String?) -> some View {
        LabeledContent(L10n.tr("Copied"), value: L10n.tr("\(result.importedFiles) files"))
        if result.failedFiles > 0 {
            LabeledContent(L10n.tr("Failed"), value: L10n.tr("\(result.failedFiles) files"))
        }
        if let interruption {
            AppStatusLabel(title: interruption, systemImage: "exclamationmark.triangle", role: .warning)
        }
        if let warning = result.portableReceiptWarning {
            AppStatusLabel(
                title: L10n.portableReceiptWarning(warning, sizeWarning: result.portableReceiptSizeWarning),
                systemImage: "exclamationmark.triangle",
                role: .warning
            )
        }
    }

    @ViewBuilder
    private func scanBothStatus(_ state: ScanBothSession.Entry.State) -> some View {
        switch state {
        case .waiting:
            Text(L10n.tr("Waiting to scan"))
                .foregroundStyle(.secondary)
        case .scanning:
            Text(L10n.tr("Scanning"))
        case .complete(let summary, _, _):
            Text(L10n.tr("\(summary.scannedFiles) files scanned"))
                .foregroundStyle(.secondary)
        case .skipped(let issue):
            AppStatusLabel(title: issue.message, systemImage: "exclamationmark.triangle", role: .warning)
        }
    }

    private var preparingPage: some View {
        AppPage(status: model.importDisconnectionMessage, statusRole: .error) {
            VStack(alignment: .leading, spacing: 18) {
                phaseHeading(L10n.tr("Preparing import"), detail: model.statusMessage)
                AppSection(model.activeScanBothImportVolumeName ?? L10n.tr("Preparing"), systemImage: "gearshape.2") {
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
            AppPage(status: model.importDisconnectionMessage, statusRole: .error) {
                VStack(alignment: .leading, spacing: 18) {
                    phaseHeading(
                        L10n.tr("Copying files"),
                        detail: model.activeScanBothImportVolumeName
                            ?? L10n.tr("Keep the source connected until copying finishes.")
                    )
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
        if let receipt = model.currentImportReceipt {
            let result = receipt.result
            AppPage(status: model.folderAccessFeedback?.text, statusRole: .error) {
                VStack(alignment: .leading, spacing: 18) {
                    phaseHeading(
                        result.failedFiles == 0 ? L10n.tr("Import complete") : L10n.tr("Completed with errors"),
                        detail: result.failedFiles == 0
                            ? L10n.tr("Your copied files are ready.")
                            : L10n.tr("Review the failed files before removing the source.")
                    )
                    if let session = model.scanBothSession, session.entry(for: result.jobID) != nil {
                        ForEach(session.entries) { entry in
                            if let earlierResult = entry.result, earlierResult.jobID != result.jobID {
                                AppSection(entry.volume.name, systemImage: "externaldrive") {
                                    scanBothCopySummary(earlierResult, interruption: entry.copyInterruption)
                                }
                            }
                        }
                        if let name = session.entry(for: result.jobID)?.volume.name {
                            Text(name).font(.headline)
                        }
                    }
                    ImportResultView(receipt: receipt)
                    scanBothBackButton
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
                    Text(model.folderAccessFeedback?.text ?? model.importFailure?.message ?? model.statusMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        if let summary = model.currentSummary, model.needsRescan(summary.jobID) {
                            Button(L10n.tr("Rescan Source")) {
                                model.rescanSource(startingAt: summary.mountPath, recoveringJobID: summary.jobID)
                            }
                            .buttonStyle(.borderedProminent)
                        } else if model.importUIPhase == .failed {
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

                        scanBothBackButton
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var scanBothBackButton: some View {
        if model.isReviewingScanBothVolume {
            Button(L10n.tr("Back to Scan Results")) {
                model.returnToScanBothResults()
            }
            .buttonStyle(.bordered)
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
        if model.isShowingScanBothResults {
            return L10n.tr("Back to Scan Results")
        }
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
                Label(scanButtonTitle, systemImage: model.sourceNeedsAccess ? "lock.open" : "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canStartScan)
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
        if model.sourceNeedsAccess {
            return L10n.tr("Allow Access & Scan")
        }
        return model.currentSummary == nil ? L10n.tr("Scan Card") : L10n.tr("Scan Again")
    }
}

struct ImportSourceSummaryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
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
                .help(model.importSourcePath)
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
                    if model.sourceNeedsAccess {
                        Label(L10n.tr("Allow Access & Scan"), systemImage: "lock.open")
                    } else {
                        Label(L10n.tr("Scan Again"), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!model.canStartScan)
            }

            if !model.isReviewingScanBothVolume,
               model.shouldOfferSelectedSourceEjection {
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
        (model.isReviewingScanBothVolume
            ? model.currentSummary?.volumeName : model.selectedSourceVolume?.name)
            ?? URL(fileURLWithPath: model.importSourcePath, isDirectory: true).lastPathComponent.nilIfBlank
            ?? L10n.tr("Source Folder")
    }

    private var sourceDetail: String {
        if !model.isReviewingScanBothVolume,
           let volume = model.selectedSourceVolume {
            return volume.detailText
        }
        if let summary = model.currentSummary {
            return L10n.tr("\(summary.scannedFiles) scanned files · \(model.importSourcePath)")
        }
        return model.importSourcePath
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
    @Environment(\.locale) private var locale
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
    @Environment(\.locale) private var locale
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

            if model.sourceNeedsAccess {
                AppStatusLabel(
                    title: L10n.tr("macOS needs your permission to read this source."),
                    systemImage: "lock",
                    role: .warning
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ValidationStatusView(result: model.sourceValidation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcePathField: some View {
        TextField(L10n.tr("Card or source path"), text: Binding(
            get: { model.cardPath },
            set: {
                model.cardPath = $0
                model.sourcePathDidChange()
            }
        ))
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
                        .disabled(!suggestion.canSelect)
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

        let available = L10n.fileSize(availableCapacityBytes)
        if let usedCapacityBytes, let totalCapacityBytes {
            let used = L10n.fileSize(usedCapacityBytes)
            let total = L10n.fileSize(totalCapacityBytes)
            return L10n.tr("\(available) free, \(used) used of \(total)")
        }

        return L10n.tr("\(available) free")
    }
}

private struct FolderField: View {
    @Environment(\.locale) private var locale
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
                            .disabled(!suggestion.canSelect)
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
                    if model.destinationNeedsAccess(validation) {
                        Label(L10n.tr("Allow Access"), systemImage: "lock.open")
                    } else {
                        Image(systemName: "folder")
                    }
                }
                .help(L10n.tr("Choose \(title) folder"))
                .accessibilityLabel(model.destinationNeedsAccess(validation)
                    ? L10n.tr("Allow Access to \(title)") : L10n.tr("Choose \(title) folder"))
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.destinationNeedsAccess(validation) {
                AppStatusLabel(title: L10n.tr("Permission needed"), systemImage: "lock", role: .warning)
                    .font(.callout)
            } else {
                ValidationStatusView(result: validation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecentPathManagementSheet: View {
    @Environment(\.locale) private var locale
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
    @Environment(\.locale) private var locale
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
            .disabled(!suggestion.canSelect)
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
    @Environment(\.locale) private var locale
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
