import SDImportCore
import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let rows = model.previewRows()
        let totals = model.previewTotals(rows: rows)

        VStack(alignment: .leading, spacing: 14) {
            header(totals: totals)
            controls
            sessionList
            destinationSummary(rows: rows)
            fileList(rows: rows, totals: totals)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func header(totals: ImportPreviewTotals) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Import Preview")
                .font(.headline)
            Spacer()
            Text("\(totals.copyFiles) files • \(byteString(totals.copyBytes))")
                .foregroundStyle(.secondary)
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
            ForEach($model.previewSessions) { $session in
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text(session.date)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 96, alignment: .leading)

                        TextField("Label", text: $session.label)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180, maxWidth: 300)

                        if model.workflowProfile == .mixedShootSession, session.photoCount > 0 {
                            Toggle("Photos \(session.photoCount)", isOn: $session.includePhotos)
                                .frame(width: 110, alignment: .leading)
                        } else if session.photoCount > 0 {
                            Label(
                                model.workflowProfile == .photoImport
                                    ? "Photos \(session.photoCount)"
                                    : "Photos \(session.photoCount) excluded",
                                systemImage: model.workflowProfile == .photoImport ? "photo" : "minus.circle"
                            )
                            .foregroundStyle(model.workflowProfile == .photoImport ? .primary : .secondary)
                            .frame(width: 160, alignment: .leading)
                        }

                        if model.workflowProfile == .mixedShootSession, session.videoCount > 0 {
                            Toggle("Videos \(session.videoCount)", isOn: $session.includeVideos)
                                .frame(width: 110, alignment: .leading)
                        } else if session.videoCount > 0 {
                            Label(
                                model.workflowProfile == .footageBackup
                                    ? "Videos \(session.videoCount)"
                                    : "Videos \(session.videoCount) excluded",
                                systemImage: model.workflowProfile == .footageBackup ? "video" : "minus.circle"
                            )
                            .foregroundStyle(model.workflowProfile == .footageBackup ? .primary : .secondary)
                            .frame(width: 160, alignment: .leading)
                        }

                        if model.organizationPreset == .footageBackup, session.unsupportedCount > 0 {
                            Toggle("Keep sidecars \(session.unsupportedCount)", isOn: $session.includeSidecars)
                                .frame(width: 180, alignment: .leading)
                                .help("Includes non-photo/video files from the card, such as metadata, thumbnails, proxies, or camera support files.")
                        } else if session.unsupportedCount > 0 {
                            Text("\(session.unsupportedCount) non-media files skipped")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
                    Text("Will Copy To")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    ForEach(destinations.prefix(3)) { destination in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(destination.title)
                                    .lineLimit(1)
                                Text("\(destination.fileCount) files, \(byteString(destination.byteCount))")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            Text(destination.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
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
