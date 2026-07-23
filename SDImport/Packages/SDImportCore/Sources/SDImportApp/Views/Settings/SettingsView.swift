import SDImportCore
import Sparkle
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingPruneConfirmation = false

    let updater: SPUUpdater?

    var body: some View {
        TabView {
            generalForm
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            advancedForm
                .tabItem {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
        }
        .scenePadding()
        .frame(width: 680, height: 560)
        .onAppear {
            model.validatePaths()
        }
        .onDisappear {
            model.savePreferences()
        }
        .onChange(of: model.photosPath) {
            model.validatePaths()
        }
        .onChange(of: model.videosPath) {
            model.validatePaths()
        }
    }

    private var generalForm: some View {
        Form {
            Section("Default Destinations") {
                FolderSettingRow(
                    title: "Photos",
                    path: $model.photosPath,
                    validation: model.photosValidation,
                    chooseAction: model.choosePhotosFolder,
                    revealAction: model.revealPhotosFolder
                )

                FolderSettingRow(
                    title: "Videos",
                    path: $model.videosPath,
                    validation: model.videosValidation,
                    chooseAction: model.chooseVideosFolder,
                    revealAction: model.revealVideosFolder
                )
            }

            Section("Appearance") {
                Picker("Theme", selection: $model.themePreference) {
                    ForEach(AppThemePreference.allCases) { theme in
                        Text(theme.settingsTitle).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.themePreference) {
                    model.themePreferenceDidChange()
                }
            }

            Section("Import Behavior") {
                Toggle("Prompt when a card is mounted", isOn: $model.autoPromptEnabled)
                    .onChange(of: model.autoPromptEnabled) {
                        model.savePreferences()
                        model.updateLoginItemRegistration()
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Eject source after a successful import", isOn: $model.ejectAfterSuccessfulImport)
                        .onChange(of: model.ejectAfterSuccessfulImport) {
                            model.savePreferences()
                        }

                    Text("Only removable sources are ejected after an error-free copy. Zero-copy scans still offer a manual Eject button.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Updates") {
                UpdaterSettingsView(updater: updater)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedForm: some View {
        Form {
            Section("History") {
                Picker("Keep import history", selection: $model.historyRetention) {
                    ForEach(RetentionPolicy.supportedValues, id: \.self) { policy in
                        Text(policy.settingsTitle).tag(policy)
                    }
                }
                .onChange(of: model.historyRetention) {
                    model.savePreferences()
                }

                Text("History records can be removed without deleting copied photos or videos.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        model.pruneHistory(dryRun: true)
                    } label: {
                        Label("Preview Prune", systemImage: "doc.text.magnifyingglass")
                    }

                    Button(role: .destructive) {
                        isShowingPruneConfirmation = true
                    } label: {
                        Label("Prune History", systemImage: "trash")
                    }
                    .disabled(model.isWorking)
                    .alert("Prune old history?", isPresented: $isShowingPruneConfirmation) {
                        Button("Prune History", role: .destructive) {
                            model.pruneHistory(dryRun: false)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This deletes old SD Import job records using the current retention setting. Copied media files are not deleted.")
                    }
                }

                if !model.statusMessage.isEmpty, model.statusMessage != "Ready" {
                    Label(model.statusMessage, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderSettingRow: View {
    let title: String
    @Binding var path: String
    let validation: PathValidationResult
    let chooseAction: () -> Void
    let revealAction: () -> Void

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(title, text: $path)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(title) destination folder")

                    Button {
                        chooseAction()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose \(title.lowercased()) folder")
                    .accessibilityLabel("Choose \(title.lowercased()) folder")

                    Button {
                        revealAction()
                    } label: {
                        Image(systemName: "arrow.forward.square")
                    }
                    .disabled(!validation.isUsable)
                    .help("Reveal \(title.lowercased()) folder in Finder")
                    .accessibilityLabel("Reveal \(title.lowercased()) folder in Finder")
                }

                DestinationStatusLine(result: validation)

                if validation.isUsable, let capacityText {
                    Label(capacityText, systemImage: "internaldrive")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var capacityText: String? {
        guard let capacity = try? DestinationSpaceChecker.fileSystemCapacity(for: validation.expandedPath) else {
            return nil
        }
        let available = ByteCountFormatter.string(fromByteCount: capacity.availableBytes, countStyle: .file)
        if let totalBytes = capacity.totalBytes {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(available) available of \(total)"
        }
        return "\(available) available"
    }
}

private struct DestinationStatusLine: View {
    let result: PathValidationResult

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(foregroundStyle)
            .lineLimit(1)
    }

    private var message: String {
        switch result.status {
        case .empty:
            return "Choose a folder"
        case .missing:
            return "Unavailable"
        default:
            return result.message
        }
    }

    private var systemImage: String {
        switch result.status {
        case .ready:
            return "checkmark.circle"
        case .missing:
            return "externaldrive.badge.questionmark"
        default:
            return "exclamationmark.triangle"
        }
    }

    private var foregroundStyle: Color {
        switch result.status {
        case .ready, .missing:
            return .secondary
        default:
            return .orange
        }
    }
}

private extension AppThemePreference {
    var settingsTitle: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

private extension RetentionPolicy {
    var settingsTitle: String {
        switch self {
        case .days(let days):
            return "\(days) days"
        case .forever:
            return "Forever"
        }
    }
}
