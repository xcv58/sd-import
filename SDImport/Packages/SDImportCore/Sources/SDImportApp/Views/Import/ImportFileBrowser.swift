import AppKit
import SDImportCore
import SwiftUI

struct ImportFileBrowser: View {
    struct SourceFilter {
        let selection: Binding<UUID?>
        let options: [UUID?]
        let title: (UUID?) -> String
    }

    struct Selection {
        var filter: ImportPreviewFileFilter?
        var pinnedFilter: ImportPreviewFileFilter?
        var page = 0
        var rowID: Int64?

        func activeFilter(copyCount: Int) -> ImportPreviewFileFilter {
            filter ?? pinnedFilter ?? (copyCount == 0 ? .skipped : .copy)
        }

        mutating func keepCurrentFilter(copyCount: Int) {
            if filter == nil {
                pinnedFilter = activeFilter(copyCount: copyCount)
            }
        }

        mutating func selectFilter(_ filter: ImportPreviewFileFilter) {
            self.filter = filter
            page = 0
            rowID = nil
        }
    }

    enum ScrollTarget {
        case files
    }

    @Environment(\.locale) private var locale
    @AppStorage("SDImport.importPreviewMode") private var previewMode = ImportPreviewMode.grid
    @StateObject private var thumbnailProvider = ImportThumbnailProvider()

    @Binding var selection: Selection
    let rows: [ImportPreviewRow]
    let copyCount: Int
    let reimportAction: (ImportPreviewRow) -> ((Set<Int64>, Bool) -> Void)?
    let showQuickLook: (ImportPreviewRow) -> Void
    var sourceNames: [Int64: String] = [:]
    var sourceFilter: SourceFilter?

    private let filePageSize = 100

    private var fileFilter: ImportPreviewFileFilter {
        selection.activeFilter(copyCount: copyCount)
    }

    private var allItems: [ImportPreviewVisualItem] {
        visualItems()
    }

    private var filteredItems: [ImportPreviewVisualItem] {
        sortedItems(allItems.filter { item in
            item.rows.contains(where: fileFilter.includes)
        })
    }

    private var filePageCount: Int {
        max(1, Int(ceil(Double(filteredItems.count) / Double(filePageSize))))
    }

    private var currentFilePage: Int {
        min(selection.page, filePageCount - 1)
    }

    private var pagedItems: [ImportPreviewVisualItem] {
        let start = currentFilePage * filePageSize
        let end = min(start + filePageSize, filteredItems.count)
        guard start < end else {
            return []
        }
        return Array(filteredItems[start..<end])
    }

    private var selectedRow: ImportPreviewRow? {
        rows.first { $0.id == selection.rowID }
    }

    var body: some View {
        Section {
            fileBrowserBody.onDisappear { thumbnailProvider.cancelAll() }
        } header: {
            VStack(alignment: .leading, spacing: 10) {
                fileBrowserToolbar
                if let sourceFilter {
                    ImportPlanOptionRow(
                        L10n.tr("Source"), maximumControlWidth: ImportFormLayout.compactSegmentedControlWidth
                    ) {
                        ImportReviewSegmentedControl(
                            title: L10n.tr("Source"), selection: sourceFilter.selection,
                            options: sourceFilter.options, optionTitle: sourceFilter.title
                        )
                    }
                }
            }
                .id(ScrollTarget.files)
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
                if filteredItems.isEmpty {
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
        let count = L10n.tr("\(filteredItems.count) of \(allItems.count)")
        return copyCount == 0
            ? L10n.tr("\(count) · Nothing selected")
            : count
    }

    private var filterPicker: some View {
        ImportReviewSegmentedControl(
            title: L10n.tr("File filter"),
            selection: fileFilterBinding,
            options: ImportPreviewFileFilter.allCases,
            optionTitle: filterTitle
        )
        .frame(maxWidth: 430)
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
        ImportReviewSegmentedControl(
            title: L10n.tr("Preview mode"),
            selection: $previewMode,
            options: [.list, .grid],
            optionTitle: { $0 == .list ? L10n.tr("List") : L10n.tr("Grid") },
            systemImage: { $0 == .list ? "list.bullet" : "square.grid.2x2" }
        )
        .frame(width: 120)
        .accessibilityIdentifier("import.review.preview-mode")
    }

    private var fileTable: some View {
        LazyVStack(spacing: 0) {
            fileListHeader

            ForEach(pagedItems) { item in
                if item.rows.count == 1 {
                    previewListButton(row: item.primaryRow)
                } else {
                    DisclosureGroup {
                        ForEach(item.rows) { row in
                            previewListButton(row: row)
                                .padding(.leading, 8)
                        }
                    } label: {
                        ImportPreviewListGroupLabel(
                            item: item,
                            destinationText: destinationText(for: item.primaryRow)
                        )
                        .contextMenu {
                            ReimportSelectionActions(rows: item.rows, setReimportSelection: reimportAction(item.primaryRow))
                        }
                    }
                    .disclosureGroupStyle(FullWidthDisclosureGroupStyle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                }
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
            ForEach(pagedItems) { item in
                Button {
                    selection.rowID = item.primaryRow.id
                } label: {
                    ImportPreviewGridCell(
                        item: item,
                        isSelected: item.rows.contains { $0.id == selection.rowID },
                        thumbnailProvider: thumbnailProvider
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    selection.rowID = item.primaryRow.id
                    showQuickLook(item.primaryRow)
                })
                .onKeyPress(.space) {
                    selection.rowID = item.primaryRow.id
                    showQuickLook(item.primaryRow)
                    return .handled
                }
                .contextMenu {
                    ReimportSelectionActions(rows: item.rows, setReimportSelection: reimportAction(item.primaryRow))
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
                selection.page = max(0, currentFilePage - 1)
                selection.rowID = nil
            } label: {
                Label(L10n.tr("Previous Page"), systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .disabled(currentFilePage == 0)
            .help(L10n.tr("Previous page"))

            Text(L10n.tr("Page \(currentFilePage + 1) of \(filePageCount)"))
                .monospacedDigit()

            Button {
                selection.page = min(filePageCount - 1, currentFilePage + 1)
                selection.rowID = nil
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
        let end = min(start + filePageSize - 1, filteredItems.count)
        return L10n.tr("Showing \(start)\u{2013}\(end) of \(filteredItems.count)")
    }

    private var fileFilterBinding: Binding<ImportPreviewFileFilter> {
        Binding {
            fileFilter
        } set: { filter in
            selection.selectFilter(filter)
        }
    }

    private func filterTitle(_ filter: ImportPreviewFileFilter) -> String {
        let count = allItems.filter { item in
            item.rows.contains(where: filter.includes)
        }.count
        return "\(filter.title) \(count)"
    }

    private func sortedItems(_ items: [ImportPreviewVisualItem]) -> [ImportPreviewVisualItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                let leftPriority = lhs.element.rows.map(\.disposition.attention.rawValue).max() ?? 0
                let rightPriority = rhs.element.rows.map(\.disposition.attention.rawValue).max() ?? 0
                if leftPriority != rightPriority {
                    return leftPriority > rightPriority
                }
                let leftWillCopy = lhs.element.rows.contains(where: \.willCopy)
                let rightWillCopy = rhs.element.rows.contains(where: \.willCopy)
                if leftWillCopy != rightWillCopy {
                    return leftWillCopy
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func previewListButton(row: ImportPreviewRow) -> some View {
        Button {
            selection.rowID = row.id
        } label: {
            ImportPreviewListRow(
                row: row,
                destinationText: destinationText(for: row),
                isSelected: selection.rowID == row.id,
                sourceName: sourceNames[row.id]
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selection.rowID = row.id
            showQuickLook(row)
        })
        .contextMenu {
            Button(L10n.tr("Quick Look")) {
                selection.rowID = row.id
                showQuickLook(row)
            }
            ReimportSelectionActions(rows: [row], setReimportSelection: reimportAction(row))
        }
        .accessibilityHint(L10n.tr("Press Space for Quick Look"))
    }

    private func destinationText(for row: ImportPreviewRow) -> String {
        if case .rename(let originalPath, let destinationPath, _) = row.disposition {
            return "\(URL(fileURLWithPath: originalPath).lastPathComponent) → \(URL(fileURLWithPath: destinationPath).lastPathComponent)"
        }
        return row.destinationPath ?? row.status
    }

    private struct GroupKey: Hashable {
        let source: String?
        let group: String
    }

    private func groupKey(for row: ImportPreviewRow) -> GroupKey? {
        row.visualGroupID.map { GroupKey(source: sourceNames[row.id], group: $0) }
    }

    private func visualItems() -> [ImportPreviewVisualItem] {
        let pairs = rows.compactMap { row in groupKey(for: row).map { ($0, row) } }
        var groups = Dictionary(grouping: pairs, by: \.0).mapValues { $0.map(\.1) }
        var items: [ImportPreviewVisualItem] = []
        for row in rows {
            let sourceName = sourceNames[row.id]
            if let key = groupKey(for: row) {
                guard let members = groups.removeValue(forKey: key) else { continue }
                items.append(ImportPreviewVisualItem(
                    id: "group:\(row.id)", rows: members, totalGroupCount: members.count, sourceName: sourceName
                ))
            } else {
                items.append(ImportPreviewVisualItem(
                    id: "file:\(row.id)", rows: [row], totalGroupCount: 1, sourceName: sourceName
                ))
            }
        }
        return items
    }

    private func presentSelectedQuickLook() {
        guard let selectedRow else {
            return
        }
        showQuickLook(selectedRow)
    }


}

private enum ImportPreviewMode: String {
    case list
    case grid
}

enum ImportPreviewFileFilter: String, CaseIterable, Identifiable {
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
    @Environment(\.locale) private var locale
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

private struct ImportPreviewListGroupLabel: View {
    let item: ImportPreviewVisualItem
    let destinationText: String

    var body: some View {
        HStack(spacing: 12) {
            Label(item.status, systemImage: "rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.rows.first?.visualGroupKind == .insta360Clip ? "Insta360" : item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 150, maxWidth: 240, alignment: .leading)

            Text(item.primaryRow.mediaKind.displayTitle)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(L10n.fileSize(item.rows.reduce(Int64(0)) { $0 + $1.size }))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(destinationText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }
}

private struct ImportPreviewListRow: View {
    @Environment(\.locale) private var locale
    let row: ImportPreviewRow
    let destinationText: String
    let isSelected: Bool
    let sourceName: String?

    var body: some View {
        HStack(spacing: 12) {
            PreviewStatusBadge(row: row)
                .frame(width: 112, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sourceName {
                    Text(sourceName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 150, maxWidth: 240, alignment: .leading)

            Text(row.mediaKind.displayTitle)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            Text(L10n.fileSize(row.size))
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
        let size = L10n.fileSize(row.size)
        let details = "\(row.filename), \(row.status), \(row.mediaKind.displayTitle), \(size), \(destinationText)"
        return [sourceName, details].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct ImportPreviewVisualItem: Identifiable {
    let id: String
    let rows: [ImportPreviewRow]
    let totalGroupCount: Int
    let sourceName: String?

    var primaryRow: ImportPreviewRow {
        if rows.first?.visualGroupKind == .rawJPEG {
            return rows.first(where: { ["jpg", "jpeg"].contains(URL(fileURLWithPath: $0.filename).pathExtension.lowercased()) })
                ?? rows[0]
        }
        if rows.first?.visualGroupKind == .videoSidecars
            || rows.first?.visualGroupKind == .insta360Clip {
            return rows.first(where: {
                URL(fileURLWithPath: $0.filename).pathExtension.lowercased() == "insv"
            }) ?? rows.first(where: { $0.mediaKind == .video }) ?? rows[0]
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
        [sourceName, groupDescription].compactMap { $0 }.joined(separator: " · ")
    }

    private var groupDescription: String {
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
        case .insta360Clip:
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
    @Environment(\.locale) private var locale
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

struct ImportFileInspector: View {
    @Environment(\.locale) private var locale
    let row: ImportPreviewRow
    let quickLookAction: () -> Void
    let setReimportSelection: ((Set<Int64>, Bool) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(row.filename)
                    .font(.headline)
                    .textSelection(.enabled)
                PreviewStatusBadge(row: row)
                ReimportSelectionActions(rows: [row], setReimportSelection: setReimportSelection)
                    .buttonStyle(.bordered)

                inspectorField(L10n.tr("Type"), value: row.mediaKind.displayTitle)
                inspectorField(L10n.tr("Capture Date"), value: L10n.storedMessage(row.date))
                inspectorField(
                    L10n.tr("Size"),
                    value: L10n.fileSize(row.size)
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

private struct ReimportSelectionActions: View {
    let rows: [ImportPreviewRow]
    let setReimportSelection: ((Set<Int64>, Bool) -> Void)?

    var body: some View {
        let eligible = rows.filter(\.canReimport)
        let selected = rows.filter(\.canSkipReimport)
        if let setReimportSelection, !eligible.isEmpty {
            Button(L10n.tr("Import Anyway")) {
                setReimportSelection(Set(eligible.map(\.id)), true)
            }
            .accessibilityIdentifier("import.review.reimport-selection")
        }
        if let setReimportSelection, !selected.isEmpty {
            Button(L10n.tr("Skip Again")) {
                setReimportSelection(Set(selected.map(\.id)), false)
            }
        }
    }
}

struct ImportReimportControls: View {
    @Environment(\.locale) private var locale
    let rows: [ImportPreviewRow]
    let setReimportSelection: (Set<Int64>, Bool) -> Void

    var body: some View {
        let eligible = rows.filter(\.canReimport)
        let selected = rows.filter(\.canSkipReimport)
        if !eligible.isEmpty || !selected.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !eligible.isEmpty {
                    Button(L10n.tr("Include All Previously Imported Files")) {
                        setReimportSelection(Set(eligible.map(\.id)), true)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("import.review.reimport-all")
                }
                if !selected.isEmpty {
                    Button(L10n.tr("Clear Re-import Selection")) {
                        setReimportSelection(Set(selected.map(\.id)), false)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
