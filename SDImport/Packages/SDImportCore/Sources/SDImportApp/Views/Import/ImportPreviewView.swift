import SDImportCore
import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsExcludedFiles = false

    var body: some View {
        let rows = model.previewRows
        let totals = model.previewTotals

        AppSection("Preview", systemImage: "list.bullet.rectangle") {
            header(rows: rows, totals: totals)
            controls
            sessionList
            destinationSummary(rows: rows, totals: totals)
            if totals.copyFiles == 0 {
                zeroMatchSection(rows: rows)
                if showsExcludedFiles {
                    fileList(rows: rows, totals: totals)
                }
            } else {
                fileList(rows: rows, totals: totals)
            }
        }
    }

    private func header(rows: [ImportPreviewRow], totals: ImportPreviewTotals) -> some View {
        let skipped = skipBreakdown(rows: rows)

        return HStack(spacing: 8) {
            InfoPill(
                title: totals.copyFiles == 0
                    ? "Nothing to copy"
                    : (totals.copyFiles == 1 ? "1 file to copy" : "\(totals.copyFiles) files to copy"),
                systemImage: totals.copyFiles == 0 ? "checkmark.circle" : "arrow.down.circle",
                role: totals.copyFiles == 0 ? .neutral : .success
            )
            InfoPill(
                title: byteString(totals.copyBytes),
                systemImage: "externaldrive"
            )
            if skipped.knownFiles > 0 {
                InfoPill(
                    title: "\(skipped.knownFiles) known",
                    systemImage: "checkmark.seal",
                    role: .neutral
                )
            }
            if skipped.excludedFiles > 0 {
                InfoPill(
                    title: "\(skipped.excludedFiles) excluded",
                    systemImage: "minus.circle",
                    role: .warning
                )
            }
            if skipped.sidecarFiles > 0 {
                InfoPill(
                    title: "\(skipped.sidecarFiles) sidecars skipped",
                    systemImage: "paperclip",
                    role: .neutral
                )
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let mediaContent = model.mediaContentProfile {
                Label(mediaContent.cardContentsText, systemImage: "externaldrive.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let photoPairSummary = model.photoPairSummary,
               photoPairSummary.rawJPEGPairCount > 0 {
                Label("\(photoPairSummary.rawJPEGPairCount) RAW+JPEG pairs", systemImage: "photo.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isCustomImportMode {
                customControls
            } else {
                recommendedControls
            }
        }
    }

    private var recommendedControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Preset")
                    .foregroundStyle(.secondary)
                Picker("Preset", selection: workflowBinding) {
                    ForEach(ImportWorkflowProfile.allCases) { profile in
                        Text(profile.displayTitle).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
            }

            GridRow {
                Text("Folder grouping")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Picker("Folder grouping", selection: folderGroupingBinding) {
                        ForEach(ImportFolderGrouping.allCases) { grouping in
                            Text(grouping.displayTitle).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)

                    Button {
                        model.beginCustomImportMode()
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var customControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(customModeSummary, systemImage: "slider.horizontal.3")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Media to import")
                        .foregroundStyle(.secondary)
                    Picker("Media to import", selection: customMediaSelectionBinding) {
                        ForEach(ImportMediaSelection.allCases) { selection in
                            Text(mediaSelectionTitle(selection))
                                .tag(selection)
                                .disabled(!isMediaSelectionAvailable(selection))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                GridRow {
                    Text("Organization")
                        .foregroundStyle(.secondary)
                    Picker("Organization", selection: customOrganizationBinding) {
                        ForEach(ImportOrganizationPreset.allCases) { preset in
                            Text(preset.displayTitle).tag(preset)
                        }
                    }
                    .frame(width: 260)
                }

                GridRow {
                    Text("Folder grouping")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Picker("Folder grouping", selection: folderGroupingBinding) {
                            ForEach(ImportFolderGrouping.allCases) { grouping in
                                Text(grouping.displayTitle).tag(grouping)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)

                        Button {
                            model.resetToRecommendedImportMode()
                        } label: {
                            Label("Reset to Preset", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let warning = selectedMediaAvailabilityMessage {
                Label(warning, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var workflowBinding: Binding<ImportWorkflowProfile> {
        Binding {
            model.workflowProfile
        } set: { profile in
            model.applyWorkflowProfile(profile)
        }
    }

    private var customMediaSelectionBinding: Binding<ImportMediaSelection> {
        Binding {
            model.importMediaSelection
        } set: { selection in
            model.useCustomMediaSelection(selection)
        }
    }

    private var customOrganizationBinding: Binding<ImportOrganizationPreset> {
        Binding {
            model.organizationPreset
        } set: { preset in
            model.useCustomOrganizationPreset(preset)
        }
    }

    private var folderGroupingBinding: Binding<ImportFolderGrouping> {
        Binding {
            model.folderGrouping
        } set: { grouping in
            model.useFolderGrouping(grouping)
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.folderGrouping == .oneShootFolder {
                shootFolderSessionRow
            } else {
                ForEach($model.previewSessions) { $session in
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            Text(session.date)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 96, alignment: .leading)

                            TextField("Label", text: $session.label)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 180, maxWidth: 300)

                            sessionMediaControls(session: session, includePhotos: $session.includePhotos, includeVideos: $session.includeVideos)

                            sessionSidecarControl(
                                unsupportedCount: session.unsupportedCount,
                                includeSidecars: $session.includeSidecars
                            )
                        }
                    }
                }
            }
        }
    }

    private var shootFolderSessionRow: some View {
        let photoCount = model.previewSessions.reduce(0) { $0 + $1.photoCount }
        let videoCount = model.previewSessions.reduce(0) { $0 + $1.videoCount }
        let unsupportedCount = model.previewSessions.reduce(0) { $0 + $1.unsupportedCount }
        let dates = model.previewSessions.map(\.date)

        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text(ImportPlanBuilder.dateRangeTitle(for: dates))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(ImportPlanBuilder.dateRangeTitle(for: dates))
                    .frame(width: 184, alignment: .leading)

                TextField("Shoot name", text: $model.location)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 300)

                sessionMediaControls(
                    photoCount: photoCount,
                    videoCount: videoCount,
                    includePhotos: allSessionsBinding(\.includePhotos),
                    includeVideos: allSessionsBinding(\.includeVideos)
                )

                sessionSidecarControl(
                    unsupportedCount: unsupportedCount,
                    includeSidecars: allSessionsBinding(\.includeSidecars)
                )
            }
        }
    }

    @ViewBuilder
    private func sessionMediaControls(
        session: ImportPreviewSession,
        includePhotos: Binding<Bool>,
        includeVideos: Binding<Bool>
    ) -> some View {
        sessionMediaControls(
            photoCount: session.photoCount,
            videoCount: session.videoCount,
            includePhotos: includePhotos,
            includeVideos: includeVideos
        )
    }

    @ViewBuilder
    private func sessionMediaControls(
        photoCount: Int,
        videoCount: Int,
        includePhotos: Binding<Bool>,
        includeVideos: Binding<Bool>
    ) -> some View {
        if model.importMediaSelection == .photosAndVideos, photoCount > 0 {
            Toggle("Photos \(photoCount)", isOn: includePhotos)
                .frame(width: 110, alignment: .leading)
        } else if photoCount > 0 {
            Label(
                model.importMediaSelection.includes(.photo)
                    ? "Photos \(photoCount)"
                    : "Photos \(photoCount) excluded",
                systemImage: model.importMediaSelection.includes(.photo) ? "photo" : "minus.circle"
            )
            .foregroundStyle(model.importMediaSelection.includes(.photo) ? .primary : .secondary)
            .frame(width: 160, alignment: .leading)
        }

        if model.importMediaSelection == .photosAndVideos, videoCount > 0 {
            Toggle("Videos \(videoCount)", isOn: includeVideos)
                .frame(width: 110, alignment: .leading)
        } else if videoCount > 0 {
            Label(
                model.importMediaSelection.includes(.video)
                    ? "Videos \(videoCount)"
                    : "Videos \(videoCount) excluded",
                systemImage: model.importMediaSelection.includes(.video) ? "video" : "minus.circle"
            )
            .foregroundStyle(model.importMediaSelection.includes(.video) ? .primary : .secondary)
            .frame(width: 160, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sessionSidecarControl(
        unsupportedCount: Int,
        includeSidecars: Binding<Bool>
    ) -> some View {
        if model.organizationPreset == .footageBackup, unsupportedCount > 0 {
            Toggle("Keep sidecars \(unsupportedCount)", isOn: includeSidecars)
                .frame(width: 180, alignment: .leading)
                .help("Includes non-photo/video files from the card, such as metadata, thumbnails, proxies, or camera support files.")
        } else if unsupportedCount > 0 {
            Text("\(unsupportedCount) non-media files skipped")
                .foregroundStyle(.secondary)
        }
    }

    private func allSessionsBinding(_ keyPath: WritableKeyPath<ImportPreviewSession, Bool>) -> Binding<Bool> {
        Binding {
            model.previewSessions.contains { $0[keyPath: keyPath] }
        } set: { isIncluded in
            model.setPreviewSessionInclusion(keyPath, to: isIncluded)
        }
    }

    @ViewBuilder
    private func destinationSummary(rows: [ImportPreviewRow], totals: ImportPreviewTotals) -> some View {
        let destinations = model.previewDestinations
        let requirements = model.previewSpaceRequirements
        let excludedCount = rows.filter { $0.status == "Excluded" }.count

        if !destinations.isEmpty || !requirements.isEmpty || (excludedCount > 0 && totals.copyFiles > 0) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()

                if !destinations.isEmpty {
                    Text("Destinations")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    ForEach(destinations.prefix(3)) { destination in
                        DestinationSummaryRow(destination: destination)
                    }

                    if destinations.count > 3 {
                        Text("\(destinations.count - 3) more destinations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !requirements.isEmpty {
                    ForEach(requirements) { requirement in
                        Label(spaceText(for: requirement), systemImage: requirement.isSatisfied ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(requirement.isSatisfied ? Color.secondary : Color.orange)
                    }
                }

                if excludedCount > 0, let summary = exclusionSummary(rows: rows) {
                    Label(summary, systemImage: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func zeroMatchSection(rows: [ImportPreviewRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Label(zeroMatchTitle(rows: rows), systemImage: "info.circle")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(zeroMatchDetail(rows: rows))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(zeroMatchReasons(rows: rows), id: \.self) { reason in
                    Label(reason, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                if canRecoverPhotos {
                    Button {
                        model.applyWorkflowProfile(.photoImport)
                    } label: {
                        Label("Import Photos", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                }

                if canRecoverVideos {
                    Button {
                        model.applyWorkflowProfile(.footageBackup)
                    } label: {
                        Label("Import Videos", systemImage: "video")
                    }
                    .buttonStyle(.bordered)
                }

                if !rows.isEmpty {
                    Button {
                        showsExcludedFiles.toggle()
                    } label: {
                        Label(showsExcludedFiles ? "Hide Skipped Files" : "Show Skipped Files", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func fileList(rows: [ImportPreviewRow], totals: ImportPreviewTotals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Files")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if totals.skippedFiles > 0 {
                    Text("\(totals.skippedFiles) skipped")
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Status").font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    Text("File").font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    Text("Kind").font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                    Text("Destination").font(.caption).foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        ImportPreviewRowView(row: row)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)
        }
    }

    private var customModeSummary: String {
        let profile = model.customImportBaseWorkflowProfile ?? model.workflowProfile
        return "Custom settings started from \(profile.displayTitle)"
    }

    private var selectedMediaAvailabilityMessage: String? {
        guard !isMediaSelectionAvailable(model.importMediaSelection) else {
            return nil
        }
        switch model.importMediaSelection {
        case .photosAndVideos:
            return "No supported photos or videos were found on this card."
        case .photosOnly:
            return "No photos were found on this card."
        case .videosOnly:
            return "No videos were found on this card."
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

    private func mediaSelectionTitle(_ selection: ImportMediaSelection) -> String {
        guard let mediaContent = model.mediaContentProfile else {
            return selection.displayTitle
        }

        switch selection {
        case .photosAndVideos:
            return "Photos + Videos"
        case .photosOnly:
            return "Photos (\(mediaContent.photoCount))"
        case .videosOnly:
            return "Videos (\(mediaContent.videoCount))"
        }
    }

    private func isMediaSelectionAvailable(_ selection: ImportMediaSelection) -> Bool {
        guard let mediaContent = model.mediaContentProfile else {
            return true
        }

        switch selection {
        case .photosAndVideos:
            return mediaContent.supportedCount > 0
        case .photosOnly:
            return mediaContent.photoCount > 0
        case .videosOnly:
            return mediaContent.videoCount > 0
        }
    }

    private func zeroMatchTitle(rows: [ImportPreviewRow]) -> String {
        if let warning = selectedMediaAvailabilityMessage {
            return warning.replacingOccurrences(of: " on this card.", with: "")
        }
        if rows.contains(where: { $0.status == "Excluded" }) {
            return "Current selection excludes every matching file"
        }
        if rows.contains(where: { $0.status == "Known" || $0.status == "Already exists" || $0.status == "Copied" }) {
            return "No new files to copy"
        }
        return "No files will be copied"
    }

    private func zeroMatchDetail(rows: [ImportPreviewRow]) -> String {
        if let mediaContent = model.mediaContentProfile {
            let contents = mediaContent.contentsSentence
            switch model.importMediaSelection {
            case .photosOnly where mediaContent.photoCount == 0:
                return "This card contains \(contents). Choose another media type to import."
            case .videosOnly where mediaContent.videoCount == 0:
                return "This card contains \(contents). Choose another media type to import."
            case .photosAndVideos where mediaContent.supportedCount == 0:
                return "This card contains \(contents). There are no supported photo or video files to import."
            default:
                break
            }
        }

        if let summary = exclusionSummary(rows: rows) {
            return summary
        }
        if rows.contains(where: { $0.status == "Known" || $0.status == "Already exists" || $0.status == "Copied" }) {
            return "The files in this preview are already imported, already copied, or already exist at the destination."
        }
        return "Review the selected media type and destination settings before importing."
    }

    private func zeroMatchReasons(rows: [ImportPreviewRow]) -> [String] {
        var reasons: [String] = []
        let skipped = skipBreakdown(rows: rows)

        if skipped.knownFiles > 0 {
            reasons.append("\(countText(skipped.knownFiles, singular: "file is", plural: "files are")) already known, already copied, or already present at the destination.")
        }
        if skipped.excludedFiles > 0, let summary = exclusionSummary(rows: rows) {
            reasons.append(summary)
        }
        if skipped.sidecarFiles > 0 {
            reasons.append("\(countText(skipped.sidecarFiles, singular: "sidecar is", plural: "sidecars are")) skipped unless Footage Backup keeps sidecars.")
        }
        if let mediaContent = model.mediaContentProfile, mediaContent.supportedCount == 0 {
            reasons.append("No supported photo or video files were found in the current source.")
        }

        return reasons.isEmpty ? ["No importable files match the current preview settings."] : reasons
    }

    private func exclusionSummary(rows: [ImportPreviewRow]) -> String? {
        let excludedRows = rows.filter { $0.status == "Excluded" }
        guard !excludedRows.isEmpty else {
            return nil
        }

        let photoCount = excludedRows.filter { $0.mediaKind == .photo }.count
        let videoCount = excludedRows.filter { $0.mediaKind == .video }.count
        let sidecarCount = excludedRows.filter { $0.mediaKind == .unsupported }.count
        let parts = [
            photoCount > 0 ? countText(photoCount, singular: "photo", plural: "photos") : nil,
            videoCount > 0 ? countText(videoCount, singular: "video", plural: "videos") : nil,
            sidecarCount > 0 ? countText(sidecarCount, singular: "sidecar", plural: "sidecars") : nil
        ].compactMap(\.self)

        guard !parts.isEmpty else {
            return nil
        }
        return "\(parts.joined(separator: " and ")) excluded because \(model.importMediaSelection.displayTitle) is selected."
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func countText(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }

    private func skipBreakdown(rows: [ImportPreviewRow]) -> ImportPreviewSkipBreakdown {
        ImportPreviewSkipBreakdown(
            knownFiles: rows.filter {
                !$0.willCopy && ($0.status == "Known" || $0.status == "Already exists" || $0.status == "Copied")
            }.count,
            excludedFiles: rows.filter { !$0.willCopy && $0.status == "Excluded" }.count,
            sidecarFiles: rows.filter {
                !$0.willCopy && $0.mediaKind == .unsupported && $0.status != "Excluded"
            }.count
        )
    }

    private func spaceText(for requirement: ImportPreviewSpaceRequirement) -> String {
        let required = byteString(requirement.requiredBytes)
        let available = byteString(requirement.availableBytes)
        if requirement.isSatisfied {
            return "\(required) needed, \(available) available at \(requirement.displayPath)"
        }
        return "Not enough space: \(required) needed, \(available) available at \(requirement.displayPath)"
    }
}

private struct ImportPreviewSkipBreakdown: Hashable {
    let knownFiles: Int
    let excludedFiles: Int
    let sidecarFiles: Int
}

private struct DestinationSummaryRow: View {
    let destination: ImportPreviewDestination

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(destination.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("\(destination.fileCount) files, \(ByteCountFormatter.string(fromByteCount: destination.byteCount, countStyle: .file))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(destination.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .padding(.vertical, 2)
    }
}

private struct ImportPreviewRowView: View {
    let row: ImportPreviewRow

    private var destinationText: String {
        if let destinationPath = row.destinationPath {
            return destinationPath
        }
        return row.willCopy ? "Destination pending" : row.status
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Label(row.status, systemImage: row.willCopy ? "arrow.down.circle" : "minus.circle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(row.willCopy ? .primary : .secondary)
                    .frame(width: 78, alignment: .leading)

                Text(row.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 150, alignment: .leading)

                Text(row.mediaKind.displayTitle)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                Text(destinationText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.willCopy ? .primary : .secondary)
                    .help(row.destinationPath ?? row.sourcePath)
            }
        }
        .font(.callout)
    }
}

private extension ImportMediaSelection {
    var displayTitle: String {
        switch self {
        case .photosAndVideos:
            return "Photos + Videos"
        case .photosOnly:
            return "Photos"
        case .videosOnly:
            return "Videos"
        }
    }
}

private extension ImportOrganizationPreset {
    var displayTitle: String {
        switch self {
        case .classicDatedFolders:
            return "Classic"
        case .shootSessionsByDate:
            return "Shoot Sessions"
        case .footageBackup:
            return "Footage Backup"
        }
    }
}

private extension ImportFolderGrouping {
    var displayTitle: String {
        switch self {
        case .byDay:
            return "By Day"
        case .oneShootFolder:
            return "One Shoot Folder"
        }
    }
}

private extension ImportWorkflowProfile {
    var displayTitle: String {
        switch self {
        case .photoImport:
            return "Photo Import"
        case .footageBackup:
            return "Footage Backup"
        case .mixedShootSession:
            return "Mixed Shoot Session"
        }
    }
}

private extension MediaContentProfile {
    var cardContentsText: String {
        "Card contains: \(contentsSentence)"
    }

    var contentsSentence: String {
        "\(countText(photoCount, singular: "photo", plural: "photos")) · \(countText(videoCount, singular: "video", plural: "videos")) · \(countText(sidecarCount, singular: "sidecar", plural: "sidecars"))"
    }

    private func countText(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }
}

private extension MediaKind {
    var displayTitle: String {
        switch self {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        case .unsupported:
            return "Sidecar"
        }
    }
}
