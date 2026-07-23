import SDImportCore
import SwiftUI

private enum SettingsPane: String {
    case general
    case advanced
}

private struct DestinationPathInputs: Hashable {
    let photos: String
    let videos: String
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("SDImport.selectedSettingsPane") private var selectedPane = SettingsPane.general
    @State private var isShowingPruneConfirmation = false
    @State private var validatedDestinationInputs: DestinationPathInputs?

    let appUpdater: AppUpdater

    var body: some View {
        mainWindowSettings
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: 860, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Settings")
            .onDisappear {
                Task {
                    await model.validateAndSaveDestinationSettings()
                }
            }
            .task(id: destinationPathInputs) {
                let inputs = destinationPathInputs
                guard let previousInputs = validatedDestinationInputs else {
                    validatedDestinationInputs = inputs
                    return
                }
                guard inputs != previousInputs else {
                    return
                }

                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else {
                    return
                }
                await model.validateAndSaveDestinationSettings()
                if inputs == destinationPathInputs {
                    validatedDestinationInputs = inputs
                }
            }
    }

    private var destinationPathInputs: DestinationPathInputs {
        DestinationPathInputs(photos: model.photosPath, videos: model.videosPath)
    }

    private var mainWindowSettings: some View {
        VStack(spacing: 12) {
            Picker("Settings section", selection: $selectedPane) {
                Text("General").tag(SettingsPane.general)
                Text("Advanced").tag(SettingsPane.advanced)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
            .accessibilityLabel("Settings section")

            selectedForm
        }
    }

    @ViewBuilder
    private var selectedForm: some View {
        switch selectedPane {
        case .general:
            generalForm
        case .advanced:
            advancedForm
        }
    }

    private var generalForm: some View {
        Form {
            settingsFeedbackSection

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
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Prompt when a card is mounted", isOn: autoPromptBinding)

                    Text("Runs a small background helper after login so SD Import can notice newly mounted cards.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                UpdaterSettingsView(appUpdater: appUpdater)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedForm: some View {
        Form {
            settingsFeedbackSection

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
                        Label("Preview Cleanup", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(!canCleanHistory)

                    Button(role: .destructive) {
                        isShowingPruneConfirmation = true
                    } label: {
                        Label("Delete Old History…", systemImage: "trash")
                    }
                    .disabled(!canCleanHistory)
                    .alert("Delete old history?", isPresented: $isShowingPruneConfirmation) {
                        Button("Delete Old History", role: .destructive) {
                            model.pruneHistory(dryRun: false)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This deletes old SD Import job records using the current retention setting. Copied media files are not deleted.")
                    }
                }

                if model.historyRetention.dayCount == nil {
                    Text("Choose a retention period to preview or delete old history.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var settingsFeedbackSection: some View {
        if let feedback = model.settingsFeedback {
            Section {
                SettingsFeedbackRow(feedback: feedback)
            }
        }
    }

    private var autoPromptBinding: Binding<Bool> {
        Binding {
            model.autoPromptEnabled
        } set: { enabled in
            model.setAutoPromptEnabled(enabled)
        }
    }

    private var canCleanHistory: Bool {
        !model.isWorking && model.historyRetention.dayCount != nil
    }
}

private struct SettingsFeedbackRow: View {
    let feedback: SettingsFeedback

    var body: some View {
        Label(feedback.message, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(foregroundStyle)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var systemImage: String {
        feedback.role == .error ? "exclamationmark.triangle.fill" : "info.circle"
    }

    private var foregroundStyle: Color {
        feedback.role == .error ? .red : .secondary
    }
}

private struct FolderSettingRow: View {
    let title: String
    @Binding var path: String
    let validation: PathValidationResult
    let chooseAction: () -> Void
    let revealAction: () -> Void

    @State private var capacityText: String?
    @State private var isLoadingCapacity = false

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(title, text: $path)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(title) destination folder")

                    FolderActionButtons(
                        title: title,
                        canReveal: validation.isUsable,
                        chooseAction: chooseAction,
                        revealAction: revealAction
                    )
                }

                DestinationStatusLine(result: validation)

                if isLoadingCapacity {
                    Label("Checking available space…", systemImage: "internaldrive")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let capacityText {
                    Label(capacityText, systemImage: "internaldrive")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .task(id: capacityLookupID) {
            await loadCapacity()
        }
    }

    private var capacityLookupID: String {
        "\(validation.expandedPath)|\(validation.isUsable)"
    }

    private func loadCapacity() async {
        capacityText = nil
        guard validation.isUsable else {
            isLoadingCapacity = false
            return
        }

        isLoadingCapacity = true
        let path = validation.expandedPath
        let capacity = await Task.detached(priority: .utility) {
            try? DestinationSpaceChecker.fileSystemCapacity(for: path)
        }.value

        guard !Task.isCancelled, path == validation.expandedPath else {
            return
        }

        isLoadingCapacity = false
        guard let capacity else {
            return
        }

        let available = ByteCountFormatter.string(fromByteCount: capacity.availableBytes, countStyle: .file)
        if let totalBytes = capacity.totalBytes {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            capacityText = "\(available) available of \(total)"
        } else {
            capacityText = "\(available) available"
        }
    }
}

private struct FolderActionButtons: View {
    let title: String
    let canReveal: Bool
    let chooseAction: () -> Void
    let revealAction: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Button(action: chooseAction) {
                    Label("Choose…", systemImage: "folder.badge.plus")
                }
                .help("Choose \(title.lowercased()) destination folder")
                .accessibilityLabel("Choose \(title.lowercased()) destination folder")

                Button(action: revealAction) {
                    Label("Reveal", systemImage: "magnifyingglass")
                }
                .disabled(!canReveal)
                .help("Reveal \(title.lowercased()) destination folder in Finder")
                .accessibilityLabel("Reveal \(title.lowercased()) destination folder in Finder")
            }
            .fixedSize()

            HStack(spacing: 8) {
                Button(action: chooseAction) {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Choose \(title.lowercased()) destination folder")
                .accessibilityLabel("Choose \(title.lowercased()) destination folder")

                Button(action: revealAction) {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(!canReveal)
                .help("Reveal \(title.lowercased()) destination folder in Finder")
                .accessibilityLabel("Reveal \(title.lowercased()) destination folder in Finder")
            }
        }
        .accessibilityElement(children: .contain)
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
