import AppKit
import SDImportCommerce
import SDImportCore
import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("SDImport.importPreviewMode") private var previewMode = ImportPreviewMode.grid
    @State private var selectedFileFilter: ImportPreviewFileFilter?
    @State private var filePage = 0
    @State private var selectedRowID: Int64?
    @State private var showsDateCustomization = false
    @StateObject private var thumbnailProvider = ImportThumbnailProvider()
    @StateObject private var quickLook = ImportQuickLookController()
    @AccessibilityFocusState private var reviewHeadingIsFocused: Bool

    private let filePageSize = 100

    private var fileFilter: ImportPreviewFileFilter {
        selectedFileFilter ?? (model.previewTotals.copyFiles == 0 ? .skipped : .copy)
    }

    private var filteredRows: [ImportPreviewRow] {
        sortedRows(model.previewRows.filter(fileFilter.includes))
    }

    private var filePageCount: Int {
        max(1, Int(ceil(Double(filteredRows.count) / Double(filePageSize))))
    }

    private var currentFilePage: Int {
        min(filePage, filePageCount - 1)
    }

    private var pagedRows: [ImportPreviewRow] {
        let start = currentFilePage * filePageSize
        let end = min(start + filePageSize, filteredRows.count)
        guard start < end else {
            return []
        }
        return Array(filteredRows[start..<end])
    }

    private var selectedRow: ImportPreviewRow? {
        model.previewRows.first { $0.id == selectedRowID }
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader

            AppPage(maxContentWidth: .infinity) {
                LazyVStack(
                    alignment: .leading,
                    spacing: 14,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ImportSourceSummaryView(
                        allowsChange: true,
                        allowsRescan: true,
                        compact: true
                    )

                    if model.previewTotals.copyFiles == 0 {
                        zeroCopyCard
                    } else {
                        importPlanCard
                    }
                    fileBrowser
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
                ImportFileInspector(row: selectedRow) {
                    presentQuickLook(for: selectedRow)
                }
                .frame(minWidth: 260, idealWidth: 300)
            }
        }
        .onAppear {
            reviewHeadingIsFocused = true
        }
        .onChange(of: model.cardPath) {
            thumbnailProvider.cancelAll()
            quickLook.dismiss()
            selectedFileFilter = nil
            filePage = 0
            selectedRowID = nil
        }
        .onChange(of: model.previewRows.count) {
            filePage = 0
            if selectedRow == nil {
                selectedRowID = nil
            }
        }
        .onChange(of: model.importUIPhase) {
            if model.importUIPhase != .review {
                thumbnailProvider.cancelAll()
                quickLook.dismiss()
            }
        }
    }

    private var reviewHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Review import"))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityFocused($reviewHeadingIsFocused)
                    .accessibilityIdentifier("import.phase.review.heading")
                Text(L10n.tr("Confirm what will be copied and where it will go."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

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
                ImportDestinationFields()
                defaultsAction
                sessionControls
            }

            portableReceiptOverride
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
        InfoPill(
            title: model.previewTotals.copyFiles == 1
                ? L10n.tr("1 file ready")
                : L10n.tr("\(model.previewTotals.copyFiles) files ready"),
            systemImage: "arrow.down.circle",
            role: .success
        )
        InfoPill(
            title: ByteCountFormatter.string(fromByteCount: model.previewTotals.copyBytes, countStyle: .file),
            systemImage: "externaldrive"
        )
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
            optionRow(
                L10n.tr("Copy"),
                maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth
            ) {
                Picker(L10n.tr("Copy"), selection: mediaSelectionBinding) {
                    ForEach(ImportMediaSelection.allCases) { selection in
                        Text(mediaSelectionTitle(selection))
                            .tag(selection)
                            .disabled(!isMediaSelectionAvailable(selection))
                    }
                }
                .id(mediaSelectionPickerIdentity)
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if showsMixedDestinationLayout {
                optionRow(
                    L10n.tr("Save to"),
                    maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth
                ) {
                    Picker(L10n.tr("Save to"), selection: destinationLayoutBinding) {
                        ForEach([ImportDestinationLayout.singleLibrary, .separateMediaFolders]) { layout in
                            Text(layout.displayTitle).tag(layout)
                        }
                    }
                    .id("import-destination-layout-picker")
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            optionRow(
                L10n.tr("Organize"),
                maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth
            ) {
                Picker(L10n.tr("Organize"), selection: folderGroupingBinding) {
                    ForEach(ImportFolderGrouping.allCases) { grouping in
                        Text(grouping.displayTitle).tag(grouping)
                    }
                }
                .id("import-folder-grouping-picker")
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private func optionRow<Content: View>(
        _ title: String,
        maximumControlWidth: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ImportFormLayout.columnSpacing) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: ImportFormLayout.labelWidth, alignment: .leading)
                optionRowControl(maximumWidth: maximumControlWidth) {
                    content()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                optionRowControl(maximumWidth: maximumControlWidth) {
                    content()
                }
            }
        }
    }

    @ViewBuilder
    private func optionRowControl<Content: View>(
        maximumWidth: CGFloat?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let maximumWidth {
            content()
                .frame(
                    minWidth: ImportFormLayout.minimumControlWidth,
                    idealWidth: maximumWidth,
                    maxWidth: maximumWidth
                )
        } else {
            content()
                .frame(
                    minWidth: ImportFormLayout.minimumControlWidth,
                    maxWidth: .infinity
                )
        }
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
        }

        if model.folderGrouping == .byDay, model.previewSessions.count > 1 {
            DisclosureGroup(L10n.tr("Customize Dates"), isExpanded: $showsDateCustomization) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($model.previewSessions) { $session in
                        sessionEditor(session: $session)
                    }
                }
                .padding(.top, 8)
            }
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

    @ViewBuilder
    private var portableReceiptOverride: some View {
        let count = model.previewRows.filter(\.isPortableKnown).count
        if count > 0 {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    portableReceiptLabel(count: count)
                    Button(L10n.tr("Import Anyway")) {
                        model.importPortableKnownFilesAnyway()
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    portableReceiptLabel(count: count)
                    Button(L10n.tr("Import Anyway")) {
                        model.importPortableKnownFilesAnyway()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func portableReceiptLabel(count: Int) -> some View {
        AppStatusLabel(
            title: count == 1
                ? L10n.tr("1 file was imported on another Mac")
                : L10n.tr("\(count) files were imported on another Mac"),
            systemImage: "externaldrive.badge.checkmark",
            role: .neutral
        )
        .font(.caption)
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
        AppSection(L10n.tr("Nothing New"), systemImage: "checkmark.seal") {
            Text(zeroCopyTitle)
                .font(.headline)
            Text(zeroCopyDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasSupportedMedia {
                Divider()
                importOptionControls
                ImportDestinationFields()
                defaultsAction
                sessionControls
            }

            portableReceiptOverride

            HStack(spacing: 8) {
                if canRecoverPhotos {
                    Button(L10n.tr("Import Photos")) {
                        selectFileFilter(.copy)
                        model.applyWorkflowProfile(.photoImport)
                    }
                    .buttonStyle(.bordered)
                }
                if canRecoverVideos {
                    Button(L10n.tr("Import Videos")) {
                        selectFileFilter(.copy)
                        model.applyWorkflowProfile(.footageBackup)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var fileBrowser: some View {
        Section {
            fileBrowserBody
        } header: {
            fileBrowserToolbar
                .padding(14)
                .background(
                    .bar,
                    in: .rect(
                        topLeadingRadius: 8,
                        topTrailingRadius: 8
                    )
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AppSurfacePalette.separator.opacity(0.55))
                        .frame(height: 1)
                }
                .zIndex(1)
        }
    }

    private var fileBrowserBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if filteredRows.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("No Matching Files"),
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if previewMode == .list {
                    fileTable
                } else {
                    fileGrid
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.tr("Import file preview"))

            if filePageCount > 1 {
                filePagination
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .background(
            .bar,
            in: .rect(
                bottomLeadingRadius: 8,
                bottomTrailingRadius: 8
            )
        )
    }

    private var fileBrowserToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                fileBrowserHeading
                Spacer(minLength: 8)
                filterPicker
                modePicker
            }

            VStack(alignment: .leading, spacing: 8) {
                fileBrowserHeading
                HStack(spacing: 8) {
                    filterMenu
                    modePicker
                }
            }
        }
    }

    private var fileBrowserHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.tr("Files"))
                .font(.headline)
            Text(fileBrowserSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var fileBrowserSubtitle: String {
        let count = L10n.tr("\(filteredRows.count) of \(model.previewRows.count)")
        return model.previewTotals.copyFiles == 0
            ? L10n.tr("\(count) · Nothing selected")
            : count
    }

    private var filterPicker: some View {
        Picker(L10n.tr("File Filter"), selection: fileFilterBinding) {
            ForEach(ImportPreviewFileFilter.allCases) { filter in
                Text(filterTitle(filter)).tag(filter)
            }
        }
        .id(fileFilterPickerIdentity)
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 430)
        .accessibilityLabel(L10n.tr("File filter"))
        .accessibilityIdentifier("import.review.file-filter")
    }

    private var filterMenu: some View {
        Picker(L10n.tr("File Filter"), selection: fileFilterBinding) {
            ForEach(ImportPreviewFileFilter.allCases) { filter in
                Text(filterTitle(filter)).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 180)
    }

    private var modePicker: some View {
        Picker(L10n.tr("Preview Mode"), selection: $previewMode) {
            Label(L10n.tr("List"), systemImage: "list.bullet").tag(ImportPreviewMode.list)
            Label(L10n.tr("Grid"), systemImage: "square.grid.2x2").tag(ImportPreviewMode.grid)
        }
        .id("import-preview-mode-picker")
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 120)
        .accessibilityLabel(L10n.tr("Preview mode"))
        .accessibilityIdentifier("import.review.preview-mode")
    }

    private var fileTable: some View {
        LazyVStack(spacing: 0) {
            fileListHeader

            ForEach(pagedRows) { row in
                Button {
                    selectedRowID = row.id
                } label: {
                    ImportPreviewListRow(
                        row: row,
                        destinationText: destinationText(for: row),
                        isSelected: selectedRowID == row.id
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    selectedRowID = row.id
                    presentQuickLook(for: row)
                })
                .contextMenu {
                    Button(L10n.tr("Quick Look")) {
                        selectedRowID = row.id
                        presentQuickLook(for: row)
                    }
                }
                .accessibilityHint(L10n.tr("Press Space for Quick Look"))
            }
        }
        .onKeyPress(.space) {
            presentSelectedQuickLook()
            return .handled
        }
        .accessibilityIdentifier("import.review.file-table")
    }

    private var fileListHeader: some View {
        HStack(spacing: 12) {
            Text(L10n.tr("Status"))
                .frame(width: 112, alignment: .leading)
            Text(L10n.tr("File"))
                .frame(minWidth: 150, maxWidth: 240, alignment: .leading)
            Text(L10n.tr("Kind"))
                .frame(width: 72, alignment: .leading)
            Text(L10n.tr("Size"))
                .frame(width: 80, alignment: .trailing)
            Text(L10n.tr("Destination"))
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
        .accessibilityHidden(true)
    }

    private var fileGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 155, maximum: 240), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(visualItems(from: pagedRows)) { item in
                Button {
                    selectedRowID = item.primaryRow.id
                } label: {
                    ImportPreviewGridCell(
                        item: item,
                        isSelected: item.rows.contains { $0.id == selectedRowID },
                        thumbnailProvider: thumbnailProvider
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    selectedRowID = item.primaryRow.id
                    presentQuickLook(for: item.primaryRow)
                })
                .onKeyPress(.space) {
                    selectedRowID = item.primaryRow.id
                    presentQuickLook(for: item.primaryRow)
                    return .handled
                }
                .accessibilityHint(L10n.tr("Press Space for Quick Look"))
                .accessibilityIdentifier("import.review.grid-item.\(item.primaryRow.id)")
            }
        }
        .padding(.vertical, 4)
        .onKeyPress(.space) {
            presentSelectedQuickLook()
            return .handled
        }
    }

    private var filePagination: some View {
        HStack(spacing: 10) {
            Text(filePageRangeText)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                filePage = max(0, currentFilePage - 1)
                selectedRowID = nil
            } label: {
                Label(L10n.tr("Previous Page"), systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .disabled(currentFilePage == 0)
            .help(L10n.tr("Previous page"))

            Text(L10n.tr("Page \(currentFilePage + 1) of \(filePageCount)"))
                .monospacedDigit()

            Button {
                filePage = min(filePageCount - 1, currentFilePage + 1)
                selectedRowID = nil
            } label: {
                Label(L10n.tr("Next Page"), systemImage: "chevron.right")
            }
            .labelStyle(.iconOnly)
            .disabled(currentFilePage == filePageCount - 1)
            .help(L10n.tr("Next page"))
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("File pages"))
    }

    private var filePageRangeText: String {
        let start = currentFilePage * filePageSize + 1
        let end = min(start + filePageSize - 1, filteredRows.count)
        return L10n.tr("Showing \(start)\u{2013}\(end) of \(filteredRows.count)")
    }

    private var fileFilterBinding: Binding<ImportPreviewFileFilter> {
        Binding {
            fileFilter
        } set: { filter in
            selectFileFilter(filter)
        }
    }

    private func selectFileFilter(_ filter: ImportPreviewFileFilter) {
        selectedFileFilter = filter
        filePage = 0
        selectedRowID = nil
    }

    private var inspectorBinding: Binding<Bool> {
        Binding {
            selectedRow != nil
        } set: { isPresented in
            if !isPresented {
                selectedRowID = nil
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
        model.importMediaSelection == .photosAndVideos
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
        switch selection {
        case .photosAndVideos:
            return L10n.tr("Photos + Videos")
        case .photosOnly:
            return L10n.tr("Photos (\(mediaContent.photoCount))")
        case .videosOnly:
            return L10n.tr("Videos (\(mediaContent.videoCount))")
        }
    }

    // macOS can otherwise reuse an NSSegmentedControl while LazyVStack is
    // prefetching the review page, then apply a selection to stale segments.
    // Recreate only when the dynamic segment titles actually change.
    private var mediaSelectionPickerIdentity: String {
        let photoCount = model.mediaContentProfile?.photoCount ?? -1
        let videoCount = model.mediaContentProfile?.videoCount ?? -1
        return "import-media-selection-picker-\(photoCount)-\(videoCount)"
    }

    private var fileFilterPickerIdentity: String {
        let allCount = model.previewRows.count
        let copyCount = model.previewTotals.copyFiles
        let skippedCount = allCount - copyCount
        return "import-file-filter-picker-\(allCount)-\(copyCount)-\(skippedCount)-\(model.previewAttentionCount)"
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

    private func filterTitle(_ filter: ImportPreviewFileFilter) -> String {
        "\(filter.title) \(model.previewRows.filter(filter.includes).count)"
    }

    private func sortedRows(_ rows: [ImportPreviewRow]) -> [ImportPreviewRow] {
        rows.enumerated()
            .sorted { lhs, rhs in
                let leftPriority = lhs.element.disposition.attention.rawValue
                let rightPriority = rhs.element.disposition.attention.rawValue
                if leftPriority != rightPriority {
                    return leftPriority > rightPriority
                }
                if lhs.element.willCopy != rhs.element.willCopy {
                    return lhs.element.willCopy
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func destinationText(for row: ImportPreviewRow) -> String {
        if case .rename(let originalPath, let destinationPath, _) = row.disposition {
            return "\(URL(fileURLWithPath: originalPath).lastPathComponent) → \(URL(fileURLWithPath: destinationPath).lastPathComponent)"
        }
        return row.destinationPath ?? row.status
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
        let required = ByteCountFormatter.string(fromByteCount: requirement.requiredBytes, countStyle: .file)
        guard let availableBytes = requirement.availableBytes else {
            return L10n.tr("Couldn’t check available space · \(required) planned")
        }
        let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        return requirement.isSatisfied
            ? L10n.tr("\(required) needed · \(available) available")
            : L10n.tr("Not enough space: \(required) needed · \(available) available")
    }

    private func visualItems(from rows: [ImportPreviewRow]) -> [ImportPreviewVisualItem] {
        let displayedPairs = rows.compactMap { row in
            row.visualGroupID.map { ($0, row) }
        }
        let displayedGroups = Dictionary(grouping: displayedPairs) { $0.0 }
            .mapValues { $0.map(\.1) }
        let totalPairs = model.previewRows.compactMap { row in
            row.visualGroupID.map { ($0, row) }
        }
        let totalGroupCounts = Dictionary(grouping: totalPairs) { $0.0 }
            .mapValues(\.count)
        var handledGroups: Set<String> = []
        var items: [ImportPreviewVisualItem] = []
        for row in rows {
            guard let groupID = row.visualGroupID else {
                items.append(
                    ImportPreviewVisualItem(id: "file:\(row.id)", rows: [row], totalGroupCount: 1)
                )
                continue
            }
            guard handledGroups.insert(groupID).inserted else {
                continue
            }
            let groupedRows = displayedGroups[groupID] ?? [row]
            let totalGroupCount = totalGroupCounts[groupID] ?? groupedRows.count
            items.append(
                ImportPreviewVisualItem(
                    id: "group:\(groupID)",
                    rows: groupedRows,
                    totalGroupCount: totalGroupCount
                )
            )
        }
        return items
    }

    private func presentSelectedQuickLook() {
        guard let selectedRow else {
            return
        }
        presentQuickLook(for: selectedRow)
    }

    private func presentQuickLook(for row: ImportPreviewRow) {
        let groupRows: [ImportPreviewRow]
        if let groupID = row.visualGroupID {
            groupRows = model.previewRows.filter { $0.visualGroupID == groupID }
        } else {
            groupRows = model.previewRows
        }
        quickLook.present(
            urls: groupRows.map { URL(fileURLWithPath: $0.sourcePath, isDirectory: false) },
            selectedURL: URL(fileURLWithPath: row.sourcePath, isDirectory: false)
        )
    }
}

private struct ImportReviewPrimaryAction: View {
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
        .help(model.importReadinessMessage ?? L10n.tr("Start importing the reviewed files"))
        .accessibilityHint(model.importReadinessMessage ?? L10n.tr("Begins copying the reviewed files"))
        .accessibilityIdentifier("import.review.copy")
    }

    private var buttonTitle: String {
        guard model.previewTotals.copyFiles > 0 else {
            return L10n.tr("Nothing to Import")
        }
        if !purchaseManager.canStartImport {
            return L10n.tr("Unlock Unlimited Imports")
        }
        return model.previewTotals.copyFiles == 1
            ? L10n.tr("Import 1 File")
            : L10n.tr("Import \(model.previewTotals.copyFiles) Files")
    }
}

private struct ImportReviewFooter: View {
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
        let bytes = ByteCountFormatter.string(fromByteCount: model.previewTotals.copyBytes, countStyle: .file)
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

private enum ImportPreviewMode: String {
    case list
    case grid
}

private enum ImportPreviewFileFilter: String, CaseIterable, Identifiable {
    case all
    case copy
    case skipped
    case attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return L10n.tr("All")
        case .copy:
            return L10n.tr("Copy")
        case .skipped:
            return L10n.tr("Skipped")
        case .attention:
            return L10n.tr("Attention")
        }
    }

    func includes(_ row: ImportPreviewRow) -> Bool {
        switch self {
        case .all:
            return true
        case .copy:
            return row.willCopy
        case .skipped:
            return !row.willCopy
        case .attention:
            return row.disposition.attention >= .attention
        }
    }
}

private struct PreviewStatusBadge: View {
    let row: ImportPreviewRow

    var body: some View {
        Label(row.status, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
            .accessibilityLabel(L10n.tr("Status, \(row.status)"))
    }

    private var systemImage: String {
        switch row.disposition.attention {
        case .blocking:
            return "exclamationmark.triangle.fill"
        case .attention:
            return "exclamationmark.circle"
        case .informational:
            return "minus.circle"
        case .normal:
            return row.willCopy ? "arrow.down.circle" : "checkmark.circle"
        }
    }

    private var color: Color {
        switch row.disposition.attention {
        case .blocking:
            return .red
        case .attention:
            return .orange
        case .informational:
            return .secondary
        case .normal:
            return row.willCopy ? .green : .secondary
        }
    }
}

private struct ImportPreviewListRow: View {
    let row: ImportPreviewRow
    let destinationText: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            PreviewStatusBadge(row: row)
                .frame(width: 112, alignment: .leading)

            Text(row.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 150, maxWidth: 240, alignment: .leading)

            Text(row.mediaKind.displayTitle)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(destinationText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.willCopy ? .primary : .secondary)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                .help(row.destinationPath ?? row.sourcePath)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppSurfacePalette.separator.opacity(0.55))
                .frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let size = ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file)
        return "\(row.filename), \(row.status), \(row.mediaKind.displayTitle), \(size), \(destinationText)"
    }
}

private struct DestinationTreeRow: View {
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
                Text(L10n.tr("└─ \(relativePath) · \(destination.fileCount) files · \(bytes)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destination.path)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("\(rootTitle), \(relativePath), \(destination.fileCount) files, \(bytes)"))
    }

    private var relativePath: String {
        destination.relativePath.isEmpty ? L10n.tr("Root") : destination.relativePath
    }

    private var bytes: String {
        ByteCountFormatter.string(fromByteCount: destination.byteCount, countStyle: .file)
    }
}

private struct ImportPreviewVisualItem: Identifiable {
    let id: String
    let rows: [ImportPreviewRow]
    let totalGroupCount: Int

    var primaryRow: ImportPreviewRow {
        if rows.first?.visualGroupKind == .rawJPEG {
            return rows.first(where: { ["jpg", "jpeg"].contains(URL(fileURLWithPath: $0.filename).pathExtension.lowercased()) })
                ?? rows[0]
        }
        if rows.first?.visualGroupKind == .videoSidecars {
            return rows.first(where: { $0.mediaKind == .video }) ?? rows[0]
        }
        return rows[0]
    }

    var title: String {
        if rows.first?.visualGroupKind == .rawJPEG {
            return URL(fileURLWithPath: primaryRow.filename).deletingPathExtension().lastPathComponent
        }
        return primaryRow.filename
    }

    var subtitle: String {
        switch rows.first?.visualGroupKind {
        case .rawJPEG:
            return rows.count == totalGroupCount
                ? L10n.tr("RAW + JPEG · \(rows.count) files")
                : L10n.tr("\(primaryRow.mediaKind.displayTitle) · \(rows.count) of \(totalGroupCount) paired files")
        case .videoSidecars:
            if rows.count == totalGroupCount {
                return L10n.tr("Video + \(max(0, rows.count - 1)) sidecars")
            }
            return L10n.tr("\(primaryRow.mediaKind.displayTitle) · \(rows.count) of \(totalGroupCount) grouped files")
        case nil:
            return primaryRow.mediaKind.displayTitle
        }
    }

    var status: String {
        let copyCount = rows.filter(\.willCopy).count
        return ImportPreviewGroupDispositionSummary(
            copyCount: copyCount,
            skippedCount: rows.count - copyCount
        ).mixedStatusTitle ?? primaryRow.status
    }
}

private struct ImportPreviewGridCell: View {
    let item: ImportPreviewVisualItem
    let isSelected: Bool
    let thumbnailProvider: ImportThumbnailProvider

    @State private var image: NSImage?
    @State private var requestID: UUID?
    @State private var durationText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.secondary.opacity(0.10))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: placeholderImage)
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }

                if item.primaryRow.mediaKind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }

                VStack {
                    HStack {
                        Spacer()
                        Text(item.status)
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    if let durationText {
                        HStack {
                            Spacer()
                            Text(durationText)
                                .font(.caption2)
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
                .padding(6)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Text(item.title)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            resetThumbnailRequest()
        }
        .onChange(of: item.primaryRow.sourcePath) {
            resetThumbnailRequest()
        }
        .onDisappear {
            thumbnailProvider.cancel(requestID)
            requestID = nil
        }
        .task(id: item.primaryRow.sourcePath) {
            durationText = nil
            guard item.primaryRow.mediaKind == .video else {
                return
            }
            durationText = await thumbnailProvider.durationText(for: sourceURL)
        }
    }

    private var sourceURL: URL {
        URL(fileURLWithPath: item.primaryRow.sourcePath, isDirectory: false)
    }

    private var placeholderImage: String {
        switch item.primaryRow.mediaKind {
        case .photo:
            return "photo"
        case .video:
            return "video"
        case .unsupported:
            return "doc"
        }
    }

    private var accessibilityLabel: String {
        "\(item.title), \(item.subtitle), \(item.status)"
    }

    private func startThumbnailRequest() {
        requestID = thumbnailProvider.requestThumbnail(
            for: sourceURL,
            modificationDate: item.primaryRow.modificationDateString,
            size: CGSize(width: 240, height: 180),
            scale: NSScreen.main?.backingScaleFactor ?? 2
        ) { thumbnail in
            image = thumbnail
        }
    }

    private func resetThumbnailRequest() {
        thumbnailProvider.cancel(requestID)
        requestID = nil
        image = nil
        durationText = nil
        startThumbnailRequest()
    }
}

private struct ImportFileInspector: View {
    let row: ImportPreviewRow
    let quickLookAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(row.filename)
                    .font(.headline)
                    .textSelection(.enabled)
                PreviewStatusBadge(row: row)

                inspectorField(L10n.tr("Type"), value: row.mediaKind.displayTitle)
                inspectorField(L10n.tr("Capture Date"), value: L10n.storedMessage(row.date))
                inspectorField(
                    L10n.tr("Size"),
                    value: ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file)
                )
                inspectorField(L10n.tr("Source"), value: row.sourcePath)
                inspectorField(L10n.tr("Destination"), value: row.destinationPath ?? L10n.tr("No destination"))

                if case .rename(let originalPath, let destinationPath, let reason) = row.disposition {
                    inspectorField(L10n.tr("Original Name"), value: URL(fileURLWithPath: originalPath).lastPathComponent)
                    inspectorField(L10n.tr("Resolved Name"), value: URL(fileURLWithPath: destinationPath).lastPathComponent)
                    if let reason {
                        inspectorField(L10n.tr("Reason"), value: L10n.storedMessage(reason))
                    }
                }

                Button {
                    quickLookAction()
                } label: {
                    Label(L10n.tr("Quick Look"), systemImage: "eye")
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle(L10n.tr("File Details"))
    }

    private func inspectorField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension ImportPreviewRow {
    var isPortableKnown: Bool {
        if case .known(let source) = disposition {
            return source == .portableLedger
        }
        return false
    }

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
