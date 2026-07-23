import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                diagnosticsExportSection
                crashReportsSection

                if let statusText {
                    AppStatusLabel(
                        title: statusText,
                        systemImage: model.setupError == nil ? "info.circle" : "exclamationmark.triangle",
                        role: model.setupError == nil ? .info : .error
                    )
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(AppSurfacePalette.contentBackground)
    }

    private var diagnosticsExportSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Exports the app and macOS versions, settings, recent job counts, and selected-job file statuses. Media files, file names, and full paths are omitted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack {
                        diagnosticsButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        diagnosticsButtons
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Diagnostics Export", systemImage: "waveform.path.ecg")
        }
    }

    private var diagnosticsButtons: some View {
        Group {
            Button {
                model.copyDiagnostics()
            } label: {
                Label("Copy Diagnostics", systemImage: "doc.on.doc")
            }

            Button {
                model.exportDiagnostics()
            } label: {
                Label("Export Diagnostics", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var crashReportsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("SD Import does not upload crash reports. If macOS saved a local report, reveal or export it here and review it before sharing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack {
                        crashReportButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        crashReportButtons
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Crash Reports", systemImage: "exclamationmark.triangle")
        }
    }

    private var crashReportButtons: some View {
        Group {
            Button {
                model.revealCrashReportsFolder()
            } label: {
                Label("Reveal Crash Reports", systemImage: "folder")
            }

            Button {
                model.exportLatestCrashReport()
            } label: {
                Label("Export Latest Crash Report", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var statusText: String? {
        if let setupError = model.setupError, !setupError.isEmpty {
            return setupError
        }
        guard !model.statusMessage.isEmpty, model.statusMessage != "Ready" else {
            return nil
        }
        return model.statusMessage
    }
}
