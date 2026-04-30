import SDImportCore
import SwiftUI

struct ImportPreviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            controls
            sessionList
            fileList
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        let totals = model.previewTotals()
        return HStack(alignment: .firstTextBaseline) {
            Text("Import Preview")
                .font(.headline)
            Spacer()
            Text("\(totals.copyFiles) files • \(byteString(totals.copyBytes))")
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
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

                        Toggle("Photos \(session.photoCount)", isOn: $session.includePhotos)
                            .disabled(session.photoCount == 0 || model.organizationPreset == .footageBackup)
                            .frame(width: 110, alignment: .leading)

                        Toggle("Videos \(session.videoCount)", isOn: $session.includeVideos)
                            .disabled(session.videoCount == 0)
                            .frame(width: 110, alignment: .leading)

                        if model.organizationPreset == .footageBackup, session.unsupportedCount > 0 {
                            Toggle("Sidecars \(session.unsupportedCount)", isOn: $session.includeSidecars)
                                .frame(width: 130, alignment: .leading)
                        } else if session.unsupportedCount > 0 {
                            Text("\(session.unsupportedCount) unsupported")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var fileList: some View {
        let rows = model.previewRows()
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("Files")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if model.previewTotals().skippedFiles > 0 {
                    Text("\(model.previewTotals().skippedFiles) skipped")
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
}

private struct ImportPreviewRowView: View {
    let row: ImportPreviewRow

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

                Text(row.destinationPath ?? row.sourcePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.willCopy ? .primary : .secondary)
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
