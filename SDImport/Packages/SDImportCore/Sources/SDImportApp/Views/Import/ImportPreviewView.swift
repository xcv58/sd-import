import SDImportCore
import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let rows = model.previewRows()
        let totals = model.previewTotals(rows: rows)

        AppSection("Preview", systemImage: "list.bullet.rectangle") {
            header(totals: totals)
            controls
            sessionList
            destinationSummary(rows: rows)
            fileList(rows: rows, totals: totals)
        }
    }

    private func header(totals: ImportPreviewTotals) -> some View {
        HStack(spacing: 8) {
            InfoPill(
                title: totals.copyFiles == 1 ? "1 file" : "\(totals.copyFiles) files",
                systemImage: "doc"
            )
            InfoPill(
                title: byteString(totals.copyBytes),
                systemImage: "externaldrive"
            )
            if totals.skippedFiles > 0 {
                InfoPill(
                    title: "\(totals.skippedFiles) skipped",
                    systemImage: "forward",
                    role: .neutral
                )
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Workflow")
                        .foregroundStyle(.secondary)
                    Picker("Workflow", selection: workflowBinding) {
                        ForEach(ImportWorkflowProfile.allCases) { profile in
                            Text(profile.displayTitle).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                GridRow {
                    Text("Folder")
                        .foregroundStyle(.secondary)
                    Picker("Folder", selection: $model.folderGrouping) {
                        ForEach(ImportFolderGrouping.allCases) { grouping in
                            Text(grouping.displayTitle).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .onChange(of: model.folderGrouping) {
                        model.folderGroupingDidChange()
                    }
                }
            }

            if let mediaContent = model.mediaContentProfile {
                Label(mediaContent.summaryText, systemImage: "sparkle.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let photoPairSummary = model.photoPairSummary,
               photoPairSummary.rawJPEGPairCount > 0 {
                Label("\(photoPairSummary.rawJPEGPairCount) RAW+JPEG pairs", systemImage: "photo.on.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Import")
                            .foregroundStyle(.secondary)
                        Picker("Import", selection: $model.importMediaSelection) {
                            ForEach(ImportMediaSelection.allCases) { selection in
                                Text(selection.displayTitle).tag(selection)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: model.importMediaSelection) {
                            model.applyMediaSelectionToPreviewSessions()
                        }
                    }

                    GridRow {
                        Text("Organize")
                            .foregroundStyle(.secondary)
                        Picker("Organize", selection: $model.organizationPreset) {
                            ForEach(ImportOrganizationPreset.allCases) { preset in
                                Text(preset.displayTitle).tag(preset)
                            }
                        }
                        .frame(width: 260)
                        .onChange(of: model.organizationPreset) {
                            model.organizationPresetDidChange()
                        }
                    }
                }
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
        if model.workflowProfile == .mixedShootSession, photoCount > 0 {
            Toggle("Photos \(photoCount)", isOn: includePhotos)
                .frame(width: 110, alignment: .leading)
        } else if photoCount > 0 {
            Label(
                model.workflowProfile == .photoImport
                    ? "Photos \(photoCount)"
                    : "Photos \(photoCount) excluded",
                systemImage: model.workflowProfile == .photoImport ? "photo" : "minus.circle"
            )
            .foregroundStyle(model.workflowProfile == .photoImport ? .primary : .secondary)
            .frame(width: 160, alignment: .leading)
        }

        if model.workflowProfile == .mixedShootSession, videoCount > 0 {
            Toggle("Videos \(videoCount)", isOn: includeVideos)
                .frame(width: 110, alignment: .leading)
        } else if videoCount > 0 {
            Label(
                model.workflowProfile == .footageBackup
                    ? "Videos \(videoCount)"
                    : "Videos \(videoCount) excluded",
                systemImage: model.workflowProfile == .footageBackup ? "video" : "minus.circle"
            )
            .foregroundStyle(model.workflowProfile == .footageBackup ? .primary : .secondary)
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
            for index in model.previewSessions.indices {
                model.previewSessions[index][keyPath: keyPath] = isIncluded
            }
        }
    }

    @ViewBuilder
    private func destinationSummary(rows: [ImportPreviewRow]) -> some View {
        let destinations = model.previewDestinationDirectories(rows: rows)
        let requirements = model.previewSpaceRequirements(rows: rows)
        let excludedCount = rows.filter { $0.status == "Excluded" }.count

        if !destinations.isEmpty || !requirements.isEmpty || excludedCount > 0 {
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

                if excludedCount > 0 {
                    Label("\(excludedCount) supported files are excluded by the current import selection", systemImage: "minus.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
    var summaryText: String {
        let recommendation: String
        switch confidence {
        case .exact:
            recommendation = "Recommended"
        case .dominant:
            recommendation = "Recommended by card contents"
        case .mixed:
            recommendation = "Mixed card"
        case .remembered:
            recommendation = "Remembered for this card"
        case .empty:
            recommendation = "No supported media"
        }

        return "\(recommendation): \(recommendedWorkflow.displayTitle) • \(photoCount) photos • \(videoCount) videos • \(sidecarCount) sidecars"
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
