import Accessibility
import SDImportCore
import SwiftUI

struct ScanBothReviewView: View {
    @EnvironmentObject private var model: AppModel
    @AccessibilityFocusState private var headingFocused: Bool
    @StateObject private var quickLook = ImportQuickLookController()
    @State private var fileSelections: [UUID: ImportFileBrowser.Selection] = [:]

    let session: ScanBothSession
    let review: ScanBothReview

    private var isBusy: Bool { model.isWorking || model.isEjectingSource }

    private var selectedFile: (entry: ScanBothSession.Entry, row: ImportPreviewRow)? {
        for entry in session.entries where !session.removedMountPaths.contains(entry.volume.mountPath) {
            guard let id = fileSelections[entry.id]?.rowID,
                  let row = review.volumes[entry.id]?.displayRows(isSkipped: entry.disposition == .skipped)
                      .first(where: { $0.id == id }) else { continue }
            return (entry, row)
        }
        return nil
    }

    var body: some View {
        AppPage {
            VStack(alignment: .leading, spacing: 14) {
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
                sharedPlan
                ForEach(session.entries) { entry in
                    ScanBothVolumeReview(
                        entry: entry, title: session.volumeTitle(for: entry), plan: review.volumes[entry.id],
                        destinationRoot: session.destinationRoot?.resolvedURL.path,
                        canInclude: session.canInclude(entry),
                        isDisconnected: model.ejectedSourceJobID == nil
                            && session.removedMountPaths.contains(entry.volume.mountPath),
                        fileSelection: fileSelection(for: entry),
                        setReimportSelection: reimportAction(for: entry),
                        showQuickLook: { showQuickLook($0, on: entry) }
                    )
                }
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

    private var inspectorBinding: Binding<Bool> {
        Binding {
            selectedFile != nil
        } set: { isPresented in
            if !isPresented, let entry = selectedFile?.entry {
                fileSelections[entry.id]?.rowID = nil
            }
        }
    }

    private func fileSelection(for entry: ScanBothSession.Entry) -> Binding<ImportFileBrowser.Selection> {
        Binding {
            fileSelections[entry.id] ?? .init()
        } set: { updated in
            if updated.rowID != nil {
                for sibling in session.entries where sibling.id != entry.id {
                    fileSelections[sibling.id]?.rowID = nil
                }
            }
            fileSelections[entry.id] = updated
        }
    }

    private func reimportAction(for entry: ScanBothSession.Entry) -> ((Set<Int64>, Bool) -> Void)? {
        guard !session.hasStartedImports, entry.awaitsImport, let jobID = entry.jobID,
              !session.removedMountPaths.contains(entry.volume.mountPath), !model.needsRescan(jobID) else { return nil }
        return { fileIDs, requested in
            let copyCount = review.volumes[entry.id]?.totals.copyFiles ?? 0
            fileSelections[entry.id, default: .init()].keepCurrentFilter(copyCount: copyCount)
            model.setReimportSelection(fileIDs, requested: requested, volumeID: entry.id)
        }
    }

    private func showQuickLook(_ row: ImportPreviewRow, on entry: ScanBothSession.Entry) {
        quickLook.present(row: row, among: review.volumes[entry.id]?.rows ?? [])
    }

    private var sharedPlan: some View {
        AppSection(L10n.tr("Import Plan"), systemImage: "list.bullet.rectangle") {
            destination
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    shootField.frame(minWidth: 190)
                    mediaPicker.fixedSize(horizontal: true, vertical: false)
                    organizationPicker.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 10) {
                    shootField
                    mediaPicker
                    organizationPicker
                }
            }
            .disabled(isBusy || session.hasStartedImports)
            if session.hasStartedImports {
                Label(L10n.tr("Plan settings are locked after imports start."), systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shootField: some View {
        LabeledContent(L10n.tr("Shoot")) {
            TextField(L10n.tr("Shoot name"), text: binding(\.shootName))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("import.scan-both.shoot")
        }
    }

    private var mediaPicker: some View {
        Picker(L10n.tr("Copy"), selection: binding(\.mediaSelection)) {
            Text(L10n.tr("Photos + Videos")).tag(ImportMediaSelection.photosAndVideos)
            Text(L10n.tr("Photos")).tag(ImportMediaSelection.photosOnly)
            Text(L10n.tr("Videos")).tag(ImportMediaSelection.videosOnly)
        }
        .accessibilityIdentifier("import.scan-both.media")
    }

    private var organizationPicker: some View {
        Picker(L10n.tr("Organize"), selection: binding(\.folderGrouping)) {
            Text(L10n.tr("By Capture Date")).tag(ImportFolderGrouping.byDay)
            Text(L10n.tr("One Shoot")).tag(ImportFolderGrouping.oneShootFolder)
        }
        .accessibilityIdentifier("import.scan-both.grouping")
    }

    private var destination: some View {
        let validation = model.scanBothDestinationValidation
        let needsAccess = model.scanBothDestinationNeedsAccess
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Shared Destination")).fontWeight(.medium)
                    if session.destinationPath.isEmpty {
                        Text(L10n.tr("Choose a destination folder")).foregroundStyle(.secondary)
                    } else {
                        ScanBothPath(path: session.destinationPath)
                    }
                }
                Spacer()
                if session.hasPendingResults, !session.hasStartedImports || needsAccess {
                    Button(needsAccess ? L10n.tr("Allow Access") : L10n.tr("Choose…")) {
                        model.chooseScanBothDestination()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                    .accessibilityIdentifier("import.scan-both.destination")
                }
            }
            if let message = model.scanBothDestinationChangeMessage {
                AppStatusLabel(title: message, systemImage: "exclamationmark.triangle", role: .warning)
            } else if !session.destinationPath.isEmpty, !validation.isUsable {
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
    @State private var showsFiles = false

    let entry: ScanBothSession.Entry
    let title: String
    let plan: ScanBothReview.VolumePlan?
    let destinationRoot: String?
    let canInclude: Bool
    let isDisconnected: Bool
    @Binding var fileSelection: ImportFileBrowser.Selection
    let setReimportSelection: ((Set<Int64>, Bool) -> Void)?
    let showQuickLook: (ImportPreviewRow) -> Void

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
                    ForEach(plan.paths, id: \.self) { path in
                        Label {
                            ScanBothPath(path: path, relativeTo: destinationRoot)
                        } icon: {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.rows.isEmpty {
                    filesDisclosure(for: plan)
                }
            }
        }
    }

    private func filesDisclosure(for plan: ScanBothReview.VolumePlan) -> some View {
        let isSkipped = entry.disposition == .skipped
        return DisclosureGroup(isExpanded: $showsFiles) {
            if showsFiles {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let setReimportSelection {
                        ImportReimportControls(rows: plan.rows, setReimportSelection: setReimportSelection)
                    }
                    ImportFileBrowser(
                        selection: $fileSelection, rows: plan.displayRows(isSkipped: isSkipped),
                        copyCount: isSkipped ? 0 : plan.totals.copyFiles, setReimportSelection: setReimportSelection,
                        showQuickLook: showQuickLook
                    )
                }
                .padding(.top, 8)
                .disabled(isBusy)
            }
        } label: {
            Text(L10n.tr("File Details")).accessibilityValue(title)
        }
        .onChange(of: showsFiles) { _, expanded in
            if !expanded { fileSelection.rowID = nil }
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
    var relativeTo: String?

    private var displayPath: String {
        if let relativeTo {
            let prefix = relativeTo.hasSuffix("/") ? relativeTo : relativeTo + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Text(verbatim: displayPath)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

private func scanBothFileCount(_ count: Int) -> String {
    count == 1 ? L10n.tr("1 file") : L10n.tr("\(count) files")
}
