import Accessibility
import SDImportCore
import SwiftUI

struct ScanBothReviewView: View {
    @EnvironmentObject private var model: AppModel
    @AccessibilityFocusState private var headingFocused: Bool
    @StateObject private var quickLook = ImportQuickLookController()
    @State private var fileSource: UUID?
    @State private var fileSelections: [UUID?: ImportFileBrowser.Selection] = [:]

    let session: ScanBothSession
    let review: ScanBothReview

    private var isBusy: Bool { model.isWorking || model.isEjectingSource }

    private var fileEntries: [ScanBothSession.Entry] {
        session.entries.filter {
            !session.removedMountPaths.contains($0.volume.mountPath) && review.volumes[$0.id]?.rows.isEmpty == false
        }
    }

    private var activeFileSource: UUID? {
        fileEntries.contains(where: { $0.id == fileSource }) ? fileSource : nil
    }

    private var visibleEntries: [ScanBothSession.Entry] {
        fileEntries.filter { activeFileSource == nil || $0.id == activeFileSource }
    }

    private var selectedFile: (entry: ScanBothSession.Entry, row: ImportPreviewRow)? {
        guard let rowID = fileSelections[activeFileSource]?.rowID else { return nil }
        for entry in visibleEntries {
            if let row = fileRows(for: entry).first(where: { $0.id == rowID }) {
                return (entry, row)
            }
        }
        return nil
    }

    var body: some View {
        ScrollViewReader { scroll in
            AppPage(maxContentWidth: .infinity) {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    heading
                    sharedPlan
                    volumeSummaries
                    if !fileEntries.isEmpty { files }
                    if AppDistribution.current.supportsSourceEjection {
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
            .onChange(of: fileSelections[activeFileSource]?.filter) { _, filter in
                if filter != nil { scroll.scrollTo(ImportFileBrowser.ScrollTarget.files, anchor: .top) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .inspector(isPresented: inspectorBinding) {
            if let selectedFile {
                ImportFileInspector(
                    row: selectedFile.row,
                    quickLookAction: { showQuickLook(selectedFile.row, on: selectedFile.entry) },
                    setReimportSelection: reimportAction(for: selectedFile.entry)
                )
                .frame(minWidth: 260, idealWidth: 300)
                .disabled(isBusy)
            }
        }
        .onAppear { headingFocused = true }
        .onDisappear { quickLook.dismiss() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("Review import"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
                .accessibilityIdentifier("import.phase.review.heading")
            Text(session.deviceName)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var volumeSummaries: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { volumeCards(minimumWidth: 260) }
            VStack(spacing: 14) { volumeCards(minimumWidth: 0) }
        }
    }

    private func volumeCards(minimumWidth: CGFloat) -> some View {
        ForEach(session.entries) { entry in
            ScanBothVolumeReview(
                entry: entry, title: session.volumeTitle(for: entry), plan: review.volumes[entry.id],
                canInclude: session.canInclude(entry),
                isDisconnected: model.ejectedSourceJobID == nil
                    && session.removedMountPaths.contains(entry.volume.mountPath)
            )
            .frame(minWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding {
            selectedFile != nil
        } set: { isPresented in
            if !isPresented { fileSelections[activeFileSource]?.rowID = nil }
        }
    }

    private var fileSelection: Binding<ImportFileBrowser.Selection> {
        let source = activeFileSource
        return Binding {
            fileSelections[source] ?? .init()
        } set: {
            fileSelections[source] = $0
        }
    }

    private var sourceSelection: Binding<UUID?> {
        Binding {
            activeFileSource
        } set: { source in
            fileSelections[activeFileSource]?.rowID = nil
            fileSource = source
        }
    }

    private func fileRows(for entry: ScanBothSession.Entry) -> [ImportPreviewRow] {
        review.volumes[entry.id]?.displayRows(isSkipped: entry.disposition == .skipped) ?? []
    }

    private func visibleCopyCount(in entries: [ScanBothSession.Entry]) -> Int {
        entries.filter(\.awaitsImport).reduce(0) { $0 + (review.volumes[$1.id]?.totals.copyFiles ?? 0) }
    }

    @ViewBuilder
    private var files: some View {
        let entries = visibleEntries
        let rowsByEntry = entries.map { ($0, fileRows(for: $0)) }
        let entriesByRowID = Dictionary(uniqueKeysWithValues: rowsByEntry.flatMap { entry, rows in
            rows.map { ($0.id, entry) }
        })
        let names: [Int64: String] = entries.count > 1 ? Dictionary(uniqueKeysWithValues: rowsByEntry.flatMap { entry, rows in
            let title = session.volumeTitle(for: entry)
            return rows.map { ($0.id, title) }
        }) : [:]
        if let entry = entries.first, entries.count == 1, let reimport = reimportAction(for: entry) {
            ImportReimportControls(rows: fileRows(for: entry), setReimportSelection: reimport)
                .disabled(isBusy)
        }
        ImportFileBrowser(
            selection: fileSelection, rows: rowsByEntry.flatMap { $0.1 },
            copyCount: visibleCopyCount(in: entries),
            reimportAction: { row in entriesByRowID[row.id].flatMap(reimportAction(for:)) },
            showQuickLook: { row in
                if let entry = entriesByRowID[row.id] { showQuickLook(row, on: entry) }
            },
            sourceNames: names, sourceFilter: fileSourceFilter
        )
        .disabled(isBusy)
    }

    private var fileSourceFilter: ImportFileBrowser.SourceFilter? {
        let entries = fileEntries
        guard entries.count > 1 else { return nil }
        return ImportFileBrowser.SourceFilter(
            selection: sourceSelection, options: [nil] + entries.map { Optional($0.id) },
            title: { id in
                entries.first(where: { $0.id == id }).map(session.volumeTitle(for:)) ?? L10n.tr("All")
            }
        )
    }

    private func reimportAction(for entry: ScanBothSession.Entry) -> ((Set<Int64>, Bool) -> Void)? {
        guard !session.hasStartedImports, entry.awaitsImport, let jobID = entry.jobID,
              !session.removedMountPaths.contains(entry.volume.mountPath), !model.needsRescan(jobID) else { return nil }
        return { fileIDs, requested in
            fileSelections[activeFileSource, default: .init()].keepCurrentFilter(
                copyCount: visibleCopyCount(in: visibleEntries)
            )
            model.setReimportSelection(fileIDs, requested: requested, volumeID: entry.id)
        }
    }

    private func showQuickLook(_ row: ImportPreviewRow, on entry: ScanBothSession.Entry) {
        quickLook.present(row: row, among: review.volumes[entry.id]?.rows ?? [])
    }

    private var sharedPlan: some View {
        let media = session.entries.filter(\.awaitsImport).compactMap { review.sources[$0.id]?.mediaContent }
        let photoCount = media.reduce(0) { $0 + $1.photoCount }
        let videoCount = media.reduce(0) { $0 + $1.videoCount }
        return AppSection(L10n.tr("Import Plan"), systemImage: "list.bullet.rectangle") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { ImportPlanCopyPills(totals: review.totals(in: session)) }
                VStack(alignment: .leading, spacing: 7) { ImportPlanCopyPills(totals: review.totals(in: session)) }
            }
            VStack(alignment: .leading, spacing: 10) {
                ImportPlanOptionRow(L10n.tr("Copy"), maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth) {
                    ImportReviewSegmentedControl(
                        title: L10n.tr("Copy"), selection: binding(\.mediaSelection),
                        options: ImportMediaSelection.allCases,
                        optionTitle: { $0.displayTitle(photoCount: photoCount, videoCount: videoCount) }
                    )
                    .accessibilityIdentifier("import.scan-both.media")
                }
                ImportPlanOptionRow(L10n.tr("Organize"), maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth) {
                    ImportReviewSegmentedControl(
                        title: L10n.tr("Organize"), selection: binding(\.folderGrouping),
                        options: ImportFolderGrouping.allCases, optionTitle: { $0.displayTitle }
                    )
                    .accessibilityIdentifier("import.scan-both.grouping")
                }
                ImportPlanOptionRow(L10n.tr("Shoot")) {
                    ShootNameField(name: binding(\.shootName))
                        .accessibilityIdentifier("import.scan-both.shoot")
                }
            }
            .disabled(isBusy || session.hasStartedImports)
            ImportPlanOptionRow(L10n.tr("Shared Destination")) { destination }
            if session.hasStartedImports {
                Label(L10n.tr("Plan settings are locked after imports start."), systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            destinations
        }
    }

    @ViewBuilder
    private var destinations: some View {
        let queued = review.queuedEntries(in: session)
        if !queued.isEmpty {
            Divider()
            Text(L10n.tr("Destinations"))
                .font(.subheadline.weight(.semibold))
            ForEach(queued) { entry in
                ForEach(review.volumes[entry.id]?.destinations ?? []) { destination in
                    DestinationTreeRow(destination: destination, rootTitle: session.volumeTitle(for: entry))
                }
            }
        }
    }

    private var destination: some View {
        let validation = model.scanBothDestinationValidation
        let needsAccess = model.scanBothDestinationNeedsAccess
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if session.destinationPath.isEmpty {
                        Text(L10n.tr("Choose a destination folder")).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: (session.destinationPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(session.destinationPath)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(AppSurfacePalette.separator.opacity(0.45)) }
                if session.hasPendingResults, !session.hasStartedImports || needsAccess {
                    Button {
                        model.chooseScanBothDestination()
                    } label: {
                        if needsAccess {
                            Label(L10n.tr("Allow Access"), systemImage: "lock.open")
                        } else {
                            Image(systemName: "folder")
                        }
                    }
                    .help(L10n.tr("Choose a destination folder"))
                    .accessibilityLabel(needsAccess ? L10n.tr("Allow Access") : L10n.tr("Choose a destination folder"))
                    .disabled(isBusy)
                    .accessibilityIdentifier("import.scan-both.destination")
                }
            }
            if let message = model.scanBothDestinationChangeMessage {
                AppStatusLabel(title: message, systemImage: "exclamationmark.triangle", role: .warning)
            } else if needsAccess {
                AppStatusLabel(title: L10n.tr("Permission needed"), systemImage: "lock", role: .warning)
                    .font(.callout)
            } else if !session.destinationPath.isEmpty {
                ValidationStatusView(result: validation)
            }
        }
    }

    private var footer: some View {
        let feedback = model.folderAccessFeedback?.text ?? review.blockingMessage
        return VStack(alignment: .leading, spacing: 8) {
            if let feedback, !feedback.isEmpty {
                AppStatusLabel(title: feedback, systemImage: "exclamationmark.triangle.fill", role: .error)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("import.scan-both.review-error")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    footerSummary
                    Spacer(minLength: 0)
                    footerActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    footerSummary
                    footerActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(AppSurfacePalette.contentBackground)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: feedback, initial: true) { _, message in
            if let message, !message.isEmpty { AccessibilityNotification.Announcement(message).post() }
        }
    }

    @ViewBuilder
    private var footerSummary: some View {
        let queue = review.queuedEntries(in: session)
        if !queue.isEmpty {
            let totals = review.totals(in: session)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("\(scanBothFileCount(totals.copyFiles)) · \(L10n.fileSize(totals.copyBytes))"))
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("import.scan-both.total")
                HStack(spacing: 6) {
                    Text(L10n.tr("Import order"))
                    Text(queue.map { session.volumeTitle(for: $0) }.joined(separator: " → "))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        HStack(spacing: 8) {
            ImportReviewUpdateControls()
            Button(L10n.tr("Change Source")) { model.changeScanBothSource() }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            if session.hasPendingResults {
                Button {
                    model.startSharedScanBothImports()
                } label: {
                    Label(L10n.tr("Start Imports"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStartSharedScanBothImports)
                .accessibilityIdentifier("import.scan-both.start")
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ScanBothReview, Value>) -> Binding<Value> {
        Binding(
            get: { review[keyPath: keyPath] },
            set: { model.updateSharedScanBothReview(keyPath, to: $0) }
        )
    }
}

private struct ScanBothVolumeReview: View {
    @EnvironmentObject private var model: AppModel

    let entry: ScanBothSession.Entry
    let title: String
    let plan: ScanBothReview.VolumePlan?
    let canInclude: Bool
    let isDisconnected: Bool

    private var isBusy: Bool { model.isWorking || model.isEjectingSource }

    var body: some View {
        AppSection(title, systemImage: "externaldrive") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = entry.summary {
                        LabeledContent(L10n.tr("Scanned"), value: scanBothFileCount(summary.scannedFiles))
                            .foregroundStyle(.secondary)
                        if summary.mountPath != entry.volume.mountPath {
                            ScanBothPath(path: summary.mountPath)
                        }
                        ScanPortableReceiptWarning(summary: summary)
                    } else if case .skipped(let issue) = entry.state {
                        warning(issue.message)
                    }
                    if isDisconnected { warning(L10n.tr("Card is not mounted")) }
                }
                Spacer(minLength: 8)
                dispositionActions
            }
            if let result = entry.result {
                ScanBothCopySummary(result: result, interruption: entry.copyInterruption)
            }
            if let plan, !isDisconnected {
                if entry.awaitsImport, entry.result == nil, plan.confirmation != nil {
                    LabeledContent(
                        L10n.tr("Copy"),
                        value: L10n.tr("\(scanBothFileCount(plan.totals.copyFiles)) · \(L10n.fileSize(plan.totals.copyBytes))")
                    )
                    if plan.hasConflict {
                        warning(L10n.tr("Needs attention"))
                    } else if plan.totals.copyFiles == 0 {
                        Text(L10n.tr("Nothing to import")).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dispositionActions: some View {
        switch entry.disposition {
        case .pending:
            if let summary = entry.summary, model.needsRescan(summary.jobID) {
                Button(L10n.tr("Rescan Source")) {
                    model.rescanSource(startingAt: summary.mountPath, recoveringJobID: summary.jobID)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                .accessibilityValue(title)
            }
            if entry.canSkip {
                Button(L10n.tr("Skip")) { model.skipScanBothImport(entry.id) }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    .accessibilityValue(title)
                    .accessibilityIdentifier("import.scan-both.skip.\(entry.volume.mountPath)")
            }
        case .skipped:
            Text(L10n.tr("Skipped")).foregroundStyle(.secondary)
            if canInclude {
                Button(L10n.tr("Include")) { model.includeScanBothImport(entry.id) }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    .accessibilityValue(title)
            }
        case .imported:
            Text(L10n.tr("Imported")).foregroundStyle(.secondary)
        }
    }

    private func warning(_ text: String) -> some View {
        AppStatusLabel(title: text, systemImage: "exclamationmark.triangle", role: .warning)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ScanBothCopySummary: View {
    let result: ImportResult
    let interruption: String?

    var body: some View {
        LabeledContent(L10n.tr("Copied"), value: scanBothFileCount(result.importedFiles))
        if result.failedFiles > 0 {
            LabeledContent(L10n.tr("Failed"), value: scanBothFileCount(result.failedFiles))
        }
        if let interruption {
            AppStatusLabel(title: interruption, systemImage: "exclamationmark.triangle", role: .warning)
        }
        if let warning = result.portableReceiptWarning {
            AppStatusLabel(
                title: L10n.portableReceiptWarning(warning, sizeWarning: result.portableReceiptSizeWarning),
                systemImage: "exclamationmark.triangle", role: .warning
            )
        }
    }
}

private struct ScanBothPath: View {
    let path: String

    var body: some View {
        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

private func scanBothFileCount(_ count: Int) -> String {
    count == 1 ? L10n.tr("1 file") : L10n.tr("\(count) files")
}
