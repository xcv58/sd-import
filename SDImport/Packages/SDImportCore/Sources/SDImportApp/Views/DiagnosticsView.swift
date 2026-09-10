import SDImportCore
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                backgroundPromptSection
                diagnosticsExportSection
                if AppDistribution.current.canBrowseSystemCrashReports {
                    crashReportsSection
                }

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

    private var backgroundPromptSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                AppStatusLabel(
                    title: model.backgroundPromptStatusTitle,
                    systemImage: backgroundPromptStatusImage,
                    role: backgroundPromptStatusRole
                )
                .font(.callout)

                Text(model.backgroundPromptStatusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let state = model.backgroundPromptAgentState {
                    Text("Helper build \(state.agentBuild) · last started \(state.launchedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    if !model.backgroundPromptCanConfigure {
                        Button(model.backgroundPromptApplicationOwnership.authoritativeApplicationPath == nil ? "Open Applications" : "Open Installed Copy") {
                            model.openBackgroundPromptOwner()
                        }
                    } else if model.backgroundPromptServiceStatus == .requiresApproval {
                        Button("Open Login Items") {
                            model.openBackgroundPromptSystemSettings()
                        }
                    } else if model.backgroundPromptCanRepair {
                        Button("Repair Background Helper") {
                            model.repairBackgroundPrompt()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Background Prompt", systemImage: "externaldrive.badge.timemachine")
        }
    }

    private var backgroundPromptStatusImage: String {
        if !model.backgroundPromptCanConfigure {
            return "exclamationmark.triangle"
        }
        if !model.autoPromptEnabled {
            return "minus.circle"
        }
        return model.backgroundPromptNeedsAttention
            ? "exclamationmark.triangle"
            : "checkmark.circle"
    }

    private var backgroundPromptStatusRole: AppStatusLabel.Role {
        if !model.backgroundPromptCanConfigure {
            return .warning
        }
        if !model.autoPromptEnabled {
            return .neutral
        }
        return model.backgroundPromptNeedsAttention ? .warning : .success
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
                Text("\(AppDistribution.current.displayName) does not upload crash reports. If macOS saved a local report, reveal or export it here and review it before sharing.")
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
