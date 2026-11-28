import AppKit
import SDImportCommerce
import SDImportCore
import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var fileSelection = ImportFileBrowser.Selection()
    @State private var showsDateCustomization = false
    @StateObject private var quickLook = ImportQuickLookController()
    @AccessibilityFocusState private var reviewHeadingIsFocused: Bool

    private var selectedRow: ImportPreviewRow? {
        model.previewRows.first { $0.id == fileSelection.rowID }
    }

    private var isUpdatingReimportSelection: Bool {
        model.activeImportOperation == .reimportSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            ScrollViewReader { scroll in
                AppPage(status: model.folderAccessFeedback?.text, statusRole: .error, maxContentWidth: .infinity) {
                    previewContent.disabled(isUpdatingReimportSelection)
                }
                .onChange(of: fileSelection.filter) { _, filter in
                    guard filter != nil else { return }
                    // Filtering can replace a tall page with the empty state.
                    scroll.scrollTo(ImportFileBrowser.ScrollTarget.files, anchor: .top)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.previewTotals.copyFiles > 0 {
                ImportReviewFooter()
                    .environmentObject(model)
            }
        }
        .inspector(isPresented: inspectorBinding) {
            if let selectedRow {
                ImportFileInspector(
                    row: selectedRow,
                    quickLookAction: { quickLook.present(row: selectedRow, among: model.previewRows) },
                    setReimportSelection: updateReimportSelection
                )
                .frame(minWidth: 260, idealWidth: 300)
                .disabled(isUpdatingReimportSelection)
            }
        }
        .onChange(of: model.cardPath) {
            resetFileBrowser()
        }
        .onChange(of: model.previewRows.count) {
            fileSelection.page = 0
            if selectedRow == nil {
                fileSelection.rowID = nil
            }
        }
        .onDisappear { quickLook.dismiss() }
    }

    private var previewContent: some View {
        LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
            ImportSourceSummaryView(
                allowsChange: true,
                allowsRescan: model.currentSummary.map { !model.needsRescan($0.jobID) } == true,
                compact: true
            )
            if model.previewTotals.copyFiles == 0 {
                zeroCopyCard
            } else {
                importPlanCard
            }
            ImportFileBrowser(
                selection: $fileSelection, rows: model.previewRows, copyCount: model.previewTotals.copyFiles,
                reimportAction: { _ in updateReimportSelection },
                showQuickLook: { quickLook.present(row: $0, among: model.previewRows) }
            )
        }
    }

    private func resetFileBrowser() {
        quickLook.dismiss()
        fileSelection = .init()
    }

    private var reviewHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Review import"))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityFocused($reviewHeadingIsFocused)
                    .accessibilityIdentifier("import.phase.review.heading")
                    .onAppear { reviewHeadingIsFocused = true }
                Text(L10n.tr("Confirm what will be copied and where it will go."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            ImportReviewUpdateControls()

            if let summary = model.currentSummary, model.needsRescan(summary.jobID) {
                Button(L10n.tr("Rescan Source")) {
                    model.rescanSource(startingAt: summary.mountPath, recoveringJobID: summary.jobID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUpdatingReimportSelection)
            }

            ImportReviewPrimaryAction()
                .environmentObject(model)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(AppSurfacePalette.contentBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var importPlanCard: some View {
        AppSection(L10n.tr("Import Plan"), systemImage: "list.bullet.rectangle") {
            reviewSummary

            if let mediaContent = model.mediaContentProfile {
                Label(mediaContentSummary(mediaContent), systemImage: "externaldrive.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            importOptionControls

            if hasSupportedMedia {
                planSettingsFields
            }

            reimportControls
            destinationTree

            if let warning = selectedMediaAvailabilityMessage {
                AppStatusLabel(
                    title: warning,
                    systemImage: "info.circle",
                    role: .warning
                )
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var planSettingsFields: some View {
        Group {
            ImportDestinationFields()
            insta360RescanOptions
            defaultsAction
        }
        .disabled(model.isScanBothPlanLocked)
        sessionControls
    }

    @ViewBuilder
    private var insta360RescanOptions: some View {
        if model.canCompleteInsta360InOriginalFolders {
            Toggle(
                L10n.tr("Complete Insta360 recordings in their original folders"),
                isOn: $model.useOriginalInsta360Folders
            )
        }
        if model.hasInsta360RescanLensesToCopy, !model.hasIncompleteInsta360RescanRecording,
           !model.canCompleteInsta360InOriginalFolders || !model.useOriginalInsta360Folders {
            Text(L10n.tr("The plan includes both Insta360 lens files in the selected destination."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.hasIncompleteInsta360RescanRecording {
            AppStatusLabel(
                title: L10n.tr("The source is missing an Insta360 lens file. Scan the folder containing both files."),
                systemImage: "exclamationmark.triangle",
                role: .warning
            )
            .font(.caption)
        }
        if model.hasInsta360RescanConflict {
            AppStatusLabel(
                title: L10n.tr("An existing Insta360 lens file could not be verified. Choose a different folder for both files."),
                systemImage: "exclamationmark.triangle",
                role: .warning
            )
            .font(.caption)
        }
    }

    private var reviewSummary: some View {
        let summary = model.currentSummary
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summaryPills(summary: summary)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 7) {
                summaryPills(summary: summary)
            }
        }
    }

    @ViewBuilder
    private func summaryPills(summary: ScanSummary?) -> some View {
        ImportPlanCopyPills(totals: model.previewTotals)
        if let summary, summary.knownFiles > 0 {
            InfoPill(title: L10n.tr("\(summary.knownFiles) known"), systemImage: "checkmark.seal")
        }
        if model.previewAttentionCount > 0 {
            InfoPill(
                title: L10n.tr("\(model.previewAttentionCount) attention"),
                systemImage: "exclamationmark.triangle",
                role: .warning
            )
        }
        if model.previewDestinationIssueCount > 0 {
            InfoPill(
                title: model.previewDestinationIssueCount == 1
                    ? L10n.tr("1 destination issue")
                    : L10n.tr("\(model.previewDestinationIssueCount) destination issues"),
                systemImage: "externaldrive.badge.exclamationmark",
                role: .warning
            )
        }
    }

    private var importOptionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ImportPlanOptionRow(
                L10n.tr("Copy"),
                maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth
            ) {
                ImportReviewSegmentedControl(
                    title: L10n.tr("Copy"),
                    selection: mediaSelectionBinding,
                    options: ImportMediaSelection.allCases,
                    optionTitle: mediaSelectionTitle,
                    isOptionEnabled: isMediaSelectionAvailable
                )
            }

            if showsMixedDestinationLayout {
                ImportPlanOptionRow(
                    L10n.tr("Save to"),
                    maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth
                ) {
                    ImportReviewSegmentedControl(
                        title: L10n.tr("Save to"),
                        selection: destinationLayoutBinding,
                        options: [.singleLibrary, .separateMediaFolders],
                        optionTitle: { $0.displayTitle }
                    )
                }
            }

            ImportPlanOptionRow(
                L10n.tr("Organize"),
                maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth
            ) {
                ImportReviewSegmentedControl(
                    title: L10n.tr("Organize"),
                    selection: folderGroupingBinding,
                    options: ImportFolderGrouping.allCases,
                    optionTitle: { $0.displayTitle }
                )
            }
        }
        .disabled(model.isScanBothPlanLocked)
    }

    @ViewBuilder
    private var defaultsAction: some View {
        if !model.importDraftUsesDefaults {
            HStack(spacing: 8) {
                AppStatusLabel(
                    title: L10n.tr("These choices apply to this import only"),
                    systemImage: "info.circle",
                    role: .info
                )
                .font(.caption)

                Button(L10n.tr("Use as Defaults")) {
                    model.saveImportDraftAsDefaults()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var sessionControls: some View {
        let unsupportedCount = model.previewSessions.reduce(0) { $0 + $1.unsupportedCount }

        if model.importMediaSelection == .videosOnly, unsupportedCount > 0 {
            Toggle(
                L10n.tr("Include camera support files (\(unsupportedCount))"),
                isOn: allSessionsBinding(\.includeSidecars)
            )
            .help(L10n.tr("Includes metadata, proxy, audio, thumbnail, and other camera support files in footage backups."))
            .disabled(model.isScanBothPlanLocked)
        }

        if model.canCustomizeDates
            || (showsDateCustomization && model.folderGrouping == .byDay && !model.previewSessions.isEmpty) {
            DisclosureGroup(L10n.tr("Customize Dates"), isExpanded: $showsDateCustomization) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($model.previewSessions) { $session in
                        sessionEditor(session: $session)
                            .disabled(model.isScanBothPlanLocked)
                    }
                }
                .padding(.top, 8)
            }
            .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
        }
    }

    private func sessionEditor(session: Binding<ImportPreviewSession>) -> some View {
        let value = session.wrappedValue
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(value.date)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 96, alignment: .leading)
                TextField(L10n.tr("Folder label"), text: session.label)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                if value.photoCount > 0 {
                    mediaSessionControl(
                        title: L10n.tr("Photos \(value.photoCount)"),
                        isGloballyIncluded: model.importMediaSelection.includes(.photo),
                        isIncluded: session.includePhotos
                    )
                }
                if value.videoCount > 0 {
                    mediaSessionControl(
                        title: L10n.tr("Videos \(value.videoCount)"),
                        isGloballyIncluded: model.importMediaSelection.includes(.video),
                        isIncluded: session.includeVideos
                    )
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(value.date)
                    .font(.system(.callout, design: .monospaced))
                TextField(L10n.tr("Folder label"), text: session.label)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    if value.photoCount > 0 {
                        mediaSessionControl(
                            title: L10n.tr("Photos \(value.photoCount)"),
                            isGloballyIncluded: model.importMediaSelection.includes(.photo),
                            isIncluded: session.includePhotos
                        )
                    }
                    if value.videoCount > 0 {
                        mediaSessionControl(
                            title: L10n.tr("Videos \(value.videoCount)"),
                            isGloballyIncluded: model.importMediaSelection.includes(.video),
                            isIncluded: session.includeVideos
                        )
                    }
                }
            }
        }
        .padding(10)
        .appCardSurface(cornerRadius: 6)
    }

    @ViewBuilder
    private func mediaSessionControl(
        title: String,
        isGloballyIncluded: Bool,
        isIncluded: Binding<Bool>
    ) -> some View {
        if isGloballyIncluded {
            Toggle(title, isOn: isIncluded)
        } else {
            Text(L10n.tr("\(title) excluded"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.tr("\(title), excluded by Copy selection"))
        }
    }

    private var reimportControls: some View {
        ImportReimportControls(rows: model.previewRows, setReimportSelection: updateReimportSelection)
            .disabled(model.isScanBothPlanLocked)
    }

    private func updateReimportSelection(_ fileIDs: Set<Int64>, requested: Bool) {
        fileSelection.keepCurrentFilter(copyCount: model.previewTotals.copyFiles)
        model.setReimportSelection(fileIDs, requested: requested)
    }

    @ViewBuilder
    private var destinationTree: some View {
        if !model.previewDestinations.isEmpty || !model.previewSpaceRequirements.isEmpty {
            Divider()
            Text(L10n.tr("Destinations"))
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(model.previewDestinations) { destination in
                DestinationTreeRow(
                    destination: destination,
                    rootTitle: destinationRootTitle(for: destination)
                )
            }

            ForEach(model.previewSpaceRequirements) { requirement in
                AppStatusLabel(
                    title: spaceText(for: requirement),
                    systemImage: requirement.isSatisfied ? "checkmark.circle" : "exclamationmark.triangle",
                    role: requirement.isSatisfied ? .neutral : .warning
                )
                .font(.caption)
            }
        }
    }

    private var zeroCopyCard: some View {
        let conflict = model.hasInsta360RescanConflict
        return AppSection(
            conflict ? L10n.tr("Conflicts") : L10n.tr("Nothing New"),
            systemImage: conflict ? "exclamationmark.triangle" : "checkmark.seal"
        ) {
            if !conflict {
                Text(zeroCopyTitle)
                    .font(.headline)
                Text(zeroCopyDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hasSupportedMedia {
                Divider()
                importOptionControls
                planSettingsFields
            }

            reimportControls

            HStack(spacing: 8) {
                if canRecoverPhotos {
                    Button(L10n.tr("Import Photos")) {
                        fileSelection.selectFilter(.copy)
                        model.applyWorkflowProfile(.photoImport)
                    }
                    .buttonStyle(.bordered)
                }
                if canRecoverVideos {
                    Button(L10n.tr("Import Videos")) {
                        fileSelection.selectFilter(.copy)
                        model.applyWorkflowProfile(.footageBackup)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(model.isScanBothPlanLocked)
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding {
            selectedRow != nil
        } set: { isPresented in
            if !isPresented {
                fileSelection.rowID = nil
            }
        }
    }

    private var mediaSelectionBinding: Binding<ImportMediaSelection> {
        Binding {
            model.importMediaSelection
        } set: { selection in
            model.useImportMediaSelection(selection)
        }
    }

    private var destinationLayoutBinding: Binding<ImportDestinationLayout> {
        Binding {
            model.destinationLayout
        } set: { layout in
            model.useDestinationLayout(layout)
        }
    }

    private var folderGroupingBinding: Binding<ImportFolderGrouping> {
        Binding {
            model.folderGrouping
        } set: { grouping in
            model.useFolderGrouping(grouping)
        }
    }

    private func allSessionsBinding(
        _ keyPath: WritableKeyPath<ImportPreviewSession, Bool>
    ) -> Binding<Bool> {
        Binding {
            model.previewSessions.contains { $0[keyPath: keyPath] }
        } set: { isIncluded in
            model.setPreviewSessionInclusion(keyPath, to: isIncluded)
        }
    }

    private var hasSupportedMedia: Bool {
        model.mediaContentProfile?.supportedCount ?? 1 > 0
    }

    private var showsMixedDestinationLayout: Bool {
        !model.isReviewingScanBothVolume && model.importMediaSelection == .photosAndVideos
            && (model.mediaContentProfile?.photoCount ?? 1) > 0
            && (model.mediaContentProfile?.videoCount ?? 1) > 0
    }

    private var selectedMediaAvailabilityMessage: String? {
        guard !isMediaSelectionAvailable(model.importMediaSelection) else {
            return nil
        }
        switch model.importMediaSelection {
        case .photosAndVideos:
            return L10n.tr("This source does not contain both photos and videos.")
        case .photosOnly:
            return L10n.tr("No photos were found on this source.")
        case .videosOnly:
            return L10n.tr("No videos were found on this source.")
        }
    }

    private var canRecoverPhotos: Bool {
        guard let mediaContent = model.mediaContentProfile else {
            return false
        }
        return mediaContent.photoCount > 0 && model.importMediaSelection != .photosOnly
    }

    private var canRecoverVideos: Bool {
        guard let mediaContent = model.mediaContentProfile else {
            return false
        }
        return mediaContent.videoCount > 0 && model.importMediaSelection != .videosOnly
    }

    private var zeroCopyTitle: String {
        if let selectedMediaAvailabilityMessage {
            return selectedMediaAvailabilityMessage
        }
        if model.previewRows.contains(where: { $0.disposition == .excluded }) {
            return L10n.tr("Current choices exclude every matching file")
        }
        if model.previewRows.contains(where: { $0.isKnown }) {
            return L10n.tr("No new files to copy")
        }
        return L10n.tr("No files will be copied")
    }

    private var zeroCopyDetail: String {
        if let mediaContent = model.mediaContentProfile, mediaContent.supportedCount == 0 {
            return L10n.tr("No supported photo or video files were found in this source.")
        }
        if model.previewRows.contains(where: { $0.isKnown }) {
            return L10n.tr("These files are already imported, already copied, or already present at the destination.")
        }
        return L10n.tr("Change the selected media type, date customization, or destinations to continue.")
    }

    private func mediaSelectionTitle(_ selection: ImportMediaSelection) -> String {
        guard let mediaContent = model.mediaContentProfile else {
            return selection.displayTitle
        }
        return selection.displayTitle(photoCount: mediaContent.photoCount, videoCount: mediaContent.videoCount)
    }

    private func mediaContentSummary(_ profile: MediaContentProfile) -> String {
        var parts: [String] = []
        if profile.photoCount > 0 {
            parts.append(L10n.tr("\(profile.photoCount) photos"))
        }
        if profile.videoCount > 0 {
            parts.append(L10n.tr("\(profile.videoCount) videos"))
        }
        if profile.sidecarCount > 0 {
            parts.append(L10n.tr("\(profile.sidecarCount) support files"))
        }
        return parts.isEmpty ? L10n.tr("No supported media") : parts.joined(separator: " · ")
    }

    private func isMediaSelectionAvailable(_ selection: ImportMediaSelection) -> Bool {
        guard let mediaContent = model.mediaContentProfile else {
            return true
        }
        switch selection {
        case .photosAndVideos:
            return mediaContent.photoCount > 0 && mediaContent.videoCount > 0
        case .photosOnly:
            return mediaContent.photoCount > 0
        case .videosOnly:
            return mediaContent.videoCount > 0
        }
    }

    private func destinationRootTitle(for destination: ImportPreviewDestination) -> String {
        switch destination.root {
        case .library:
            return L10n.tr("Library")
        case .photos:
            return L10n.tr("Photos")
        case .videos:
            return L10n.tr("Videos")
        case .other:
            return L10n.tr("Destination")
        }
    }

    private func spaceText(for requirement: ImportPreviewSpaceRequirement) -> String {
        let required = L10n.fileSize(requirement.requiredBytes)
        guard let availableBytes = requirement.availableBytes else {
            return L10n.tr("Couldn’t check available space · \(required) planned")
        }
        let available = L10n.fileSize(availableBytes)
        return requirement.isSatisfied
            ? L10n.tr("\(required) needed · \(available) available")
            : L10n.tr("Not enough space: \(required) needed · \(available) available")
    }
}

struct ImportReviewUpdateControls: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.activeImportOperation == .reimportSelection {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(L10n.tr("Updating re-import selection…"))
            Button(L10n.tr("Cancel"), role: .cancel) {
                model.cancelImport()
            }
            .buttonStyle(.bordered)
            .disabled(!model.canCancelReimportSelection)
        }
    }
}

struct ImportReviewPrimaryAction: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchaseManager: PurchaseManager

    var body: some View {
        Button {
            model.importCurrentJob()
        } label: {
            Label(buttonTitle, systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canImportPlannedFiles)
        .help(model.importReadinessMessage ?? actionHint)
        .accessibilityHint(model.importReadinessMessage ?? actionHint)
        .accessibilityIdentifier("import.review.copy")
    }

    private var actionHint: String {
        L10n.tr("Begins copying the reviewed files")
    }

    private var buttonTitle: String {
        guard model.previewTotals.copyFiles > 0 else {
            return L10n.tr("Nothing to Import")
        }
        if !purchaseManager.canStartImport {
            return L10n.tr("Start Trial or Unlock")
        }
        return model.previewTotals.copyFiles == 1
            ? L10n.tr("Import 1 File")
            : L10n.tr("Import \(model.previewTotals.copyFiles) Files")
    }
}

private struct ImportReviewFooter: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSystemImage)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .fontWeight(.semibold)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if model.canImportPlannedFiles {
                Text(L10n.tr("Press Return to start"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let bytes = L10n.fileSize(model.previewTotals.copyBytes)
        let files = model.previewTotals.copyFiles == 1
            ? L10n.tr("1 file")
            : L10n.tr("\(model.previewTotals.copyFiles) files")
        let folders = model.previewDestinations.count == 1
            ? L10n.tr("1 folder")
            : L10n.tr("\(model.previewDestinations.count) folders")
        return "\(files) · \(bytes) · \(folders)"
    }

    private var statusTitle: String {
        model.importReadinessMessage ?? L10n.tr("Ready to import")
    }

    private var statusSystemImage: String {
        model.importReadinessMessage == nil
            ? "checkmark.circle.fill"
            : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        model.importReadinessMessage == nil ? .green : .orange
    }
}

struct DestinationTreeRow: View {
    @Environment(\.locale) private var locale
    let destination: ImportPreviewDestination
    let rootTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(rootTitle)
                    .fontWeight(.medium)
                Text(L10n.tr("└─ \(relativePath) · \(fileCount) · \(bytes)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destination.path)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("\(rootTitle), \(relativePath), \(fileCount), \(bytes)"))
    }

    private var fileCount: String {
        destination.fileCount == 1 ? L10n.tr("1 file") : L10n.tr("\(destination.fileCount) files")
    }

    private var relativePath: String {
        destination.relativePath.isEmpty ? L10n.tr("Root") : destination.relativePath
    }

    private var bytes: String {
        L10n.fileSize(destination.byteCount)
    }
}

private extension ImportPreviewRow {
    var isKnown: Bool {
        switch disposition {
        case .known, .alreadyExists, .copied:
            return true
        default:
            return false
        }
    }
}

extension ImportMediaSelection {
    func displayTitle(photoCount: Int, videoCount: Int) -> String {
        switch self {
        case .photosAndVideos:
            return displayTitle
        case .photosOnly:
            return L10n.tr("Photos (\(photoCount))")
        case .videosOnly:
            return L10n.tr("Videos (\(videoCount))")
        }
    }

    var displayTitle: String {
        switch self {
        case .photosAndVideos:
            return L10n.tr("Photos + Videos")
        case .photosOnly:
            return L10n.tr("Photos")
        case .videosOnly:
            return L10n.tr("Videos")
        }
    }
}

extension ImportDestinationLayout {
    var displayTitle: String {
        switch self {
        case .singleLibrary:
            return L10n.tr("Same Library")
        case .separateMediaFolders:
            return L10n.tr("Separate Folders")
        case .footageBackup:
            return L10n.tr("Videos")
        }
    }
}

extension ImportFolderGrouping {
    var displayTitle: String {
        switch self {
        case .byDay:
            return L10n.tr("By Capture Date")
        case .oneShootFolder:
            return L10n.tr("One Shoot")
        }
    }
}

extension MediaKind {
    var displayTitle: String {
        switch self {
        case .photo:
            return L10n.tr("Photo")
        case .video:
            return L10n.tr("Video")
        case .unsupported:
            return L10n.tr("Other")
        }
    }
}
