import SDImportCommerce
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
    @EnvironmentObject private var purchaseManager: PurchaseManager
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
            .navigationTitle(L10n.tr("Settings"))
            .onAppear {
                model.validateDefaultPaths()
            }
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
        DestinationPathInputs(
            photos: model.importDefaults.photosPath,
            videos: model.importDefaults.videosPath
        )
    }

    private var mainWindowSettings: some View {
        VStack(spacing: 12) {
            Picker(L10n.tr("Settings section"), selection: $selectedPane) {
                Text(L10n.tr("General")).tag(SettingsPane.general)
                Text(L10n.tr("Advanced")).tag(SettingsPane.advanced)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
            .accessibilityLabel(L10n.tr("Settings section"))

            selectedForm
        }
    }

    @ViewBuilder
    private var selectedForm: some View {
        switch selectedPane {
        case .general:
            generalSettings
        case .advanced:
            advancedSettings
        }
    }

    private var generalSettings: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                settingsFeedbackCard

                SettingsGroup(L10n.tr("Default Destinations")) {
                    VStack(spacing: 0) {
                        FolderSettingRow(
                            title: L10n.tr("Photos"),
                            path: $model.importDefaults.photosPath,
                            validation: model.defaultPhotosValidation,
                            chooseAction: model.chooseDefaultPhotosFolder,
                            revealAction: model.revealPhotosFolder
                        )

                        Divider()
                            .padding(.vertical, 12)

                        FolderSettingRow(
                            title: L10n.tr("Videos"),
                            path: $model.importDefaults.videosPath,
                            validation: model.defaultVideosValidation,
                            chooseAction: model.chooseDefaultVideosFolder,
                            revealAction: model.revealVideosFolder
                        )
                    }
                }

                SettingsGroup(L10n.tr("Appearance")) {
                    LabeledContent(L10n.tr("Theme")) {
                        Picker(L10n.tr("Theme"), selection: $model.themePreference) {
                            ForEach(AppThemePreference.allCases) { theme in
                                Text(theme.settingsTitle).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        .onChange(of: model.themePreference) {
                            model.themePreferenceDidChange()
                        }
                    }
                }

                SettingsGroup(L10n.tr("Import Behavior")) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle(L10n.tr("Prompt when a card is mounted"), isOn: autoPromptBinding)
                                .disabled(!model.backgroundPromptCanConfigure)

                            Text(L10n.tr("Runs a small background helper after login so \(AppDistribution.current.displayName) can notice newly mounted cards."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 12) {
                                AppStatusLabel(
                                    title: L10n.tr("Background helper: \(model.backgroundPromptStatusTitle)"),
                                    systemImage: backgroundPromptStatusImage,
                                    role: backgroundPromptStatusRole
                                )
                                .font(.callout)

                                Spacer()

                                if !model.backgroundPromptCanConfigure {
                                    Button(model.backgroundPromptApplicationOwnership.authoritativeApplicationPath == nil ? L10n.tr("Open Applications") : L10n.tr("Open Installed Copy")) {
                                        model.openBackgroundPromptOwner()
                                    }
                                } else if model.backgroundPromptServiceStatus == .requiresApproval {
                                    Button(L10n.tr("Open Login Items")) {
                                        model.openBackgroundPromptSystemSettings()
                                    }
                                } else if model.backgroundPromptNeedsAttention && model.backgroundPromptCanRepair {
                                    Button(L10n.tr("Repair")) {
                                        model.repairBackgroundPrompt()
                                    }
                                }
                            }

                            if model.backgroundPromptNeedsAttention || !model.backgroundPromptCanConfigure {
                                Text(model.backgroundPromptStatusDetail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if AppDistribution.current.supportsSourceEjection {
                            Divider()
                                .padding(.vertical, 12)

                            VStack(alignment: .leading, spacing: 5) {
                                Toggle(L10n.tr("Eject source device after a successful import"), isOn: $model.ejectAfterSuccessfulImport)
                                    .onChange(of: model.ejectAfterSuccessfulImport) {
                                        model.savePreferences()
                                    }

                                Text(L10n.tr("After an error-free copy, ejects all removable storage volumes macOS identifies as belonging to the source device. Zero-copy scans still require manual ejection."))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Divider()
                            .padding(.vertical, 12)

                        VStack(alignment: .leading, spacing: 5) {
                            Toggle(
                                L10n.tr("Store portable import receipts on source drives"),
                                isOn: $model.portableImportReceiptsEnabled
                            )
                            .onChange(of: model.portableImportReceiptsEnabled) {
                                model.savePreferences()
                            }

                            Text(L10n.tr("Writes a validated, hidden .sd-import ledger after successful copies and uses it to avoid duplicate imports on other Macs. Read-only sources continue without portable history."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if purchaseManager.isMacAppStoreEdition {
                    SettingsGroup(L10n.tr("Purchase")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(purchaseManager.allowanceSummary)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button(L10n.tr("Unlock Unlimited Imports…")) {
                                    purchaseManager.isShowingPurchase = true
                                }
                                .disabled(purchaseManager.hasLifetimeUnlock)

                                Button(L10n.tr("Restore Purchases")) {
                                    Task {
                                        await purchaseManager.restorePurchases()
                                    }
                                }
                                .disabled(purchaseManager.isPerformingStoreOperation)
                            }

                            if let message = purchaseManager.statusMessage {
                                Text(message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                SettingsGroup(L10n.tr("Privacy & Support")) {
                    HStack(spacing: 10) {
                        Link(
                            L10n.tr("Privacy Policy"),
                            destination: URL(string: "https://macos-automation.vercel.app/privacy.html")!
                        )
                        Link(
                            L10n.tr("Support"),
                            destination: URL(string: "https://macos-automation.vercel.app/support.html")!
                        )
                    }
                }

                SettingsGroup(L10n.tr("Updates")) {
                    UpdaterSettingsView(appUpdater: appUpdater)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var advancedSettings: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                settingsFeedbackCard

                SettingsGroup(L10n.tr("History")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(L10n.tr("Keep import history"), selection: $model.historyRetention) {
                            ForEach(RetentionPolicy.supportedValues, id: \.self) { policy in
                                Text(policy.settingsTitle).tag(policy)
                            }
                        }
                        .onChange(of: model.historyRetention) {
                            model.savePreferences()
                        }

                        Text(L10n.tr("History records can be removed without deleting copied photos or videos."))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button {
                                model.pruneHistory(dryRun: true)
                            } label: {
                                Label(L10n.tr("Preview Cleanup"), systemImage: "doc.text.magnifyingglass")
                            }
                            .disabled(!canCleanHistory)

                            Button(role: .destructive) {
                                isShowingPruneConfirmation = true
                            } label: {
                                Label(L10n.tr("Delete Old History…"), systemImage: "trash")
                            }
                            .disabled(!canCleanHistory)
                            .alert(L10n.tr("Delete old history?"), isPresented: $isShowingPruneConfirmation) {
                                Button(L10n.tr("Delete Old History"), role: .destructive) {
                                    model.pruneHistory(dryRun: false)
                                }
                                Button(L10n.tr("Cancel"), role: .cancel) {}
                            } message: {
                                Text(L10n.tr("This deletes old \(AppDistribution.current.displayName) job records using the current retention setting. Copied media files are not deleted."))
                            }
                        }

                        if model.historyRetention.dayCount == nil {
                            Text(L10n.tr("Choose a retention period to preview or delete old history."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var settingsFeedbackCard: some View {
        if let feedback = model.settingsFeedback {
            SettingsFeedbackRow(feedback: feedback)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCardSurface()
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
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.leading, 16)

            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appCardSurface(cornerRadius: 10)
        }
    }
}

private struct SettingsFeedbackRow: View {
    let feedback: SettingsFeedback

    var body: some View {
        AppStatusLabel(
            title: feedback.message,
            systemImage: systemImage,
            role: feedback.role == .error ? .error : .info
        )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var systemImage: String {
        feedback.role == .error ? "exclamationmark.triangle.fill" : "info.circle"
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
                        .accessibilityLabel(L10n.tr("\(title) destination folder"))

                    FolderActionButtons(
                        title: title,
                        canReveal: validation.isUsable,
                        chooseAction: chooseAction,
                        revealAction: revealAction
                    )
                }

                DestinationStatusLine(result: validation)

                if isLoadingCapacity {
                    Label(L10n.tr("Checking available space…"), systemImage: "internaldrive")
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
            capacityText = L10n.tr("\(available) available of \(total)")
        } else {
            capacityText = L10n.tr("\(available) available")
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
                    Label(L10n.tr("Choose…"), systemImage: "folder.badge.plus")
                }
                .help(L10n.tr("Choose \(title) destination folder"))
                .accessibilityLabel(L10n.tr("Choose \(title) destination folder"))

                Button(action: revealAction) {
                    Label(L10n.tr("Reveal"), systemImage: "magnifyingglass")
                }
                .disabled(!canReveal)
                .help(L10n.tr("Reveal \(title) destination folder in Finder"))
                .accessibilityLabel(L10n.tr("Reveal \(title) destination folder in Finder"))
            }
            .fixedSize()

            HStack(spacing: 8) {
                Button(action: chooseAction) {
                    Image(systemName: "folder.badge.plus")
                }
                .help(L10n.tr("Choose \(title) destination folder"))
                .accessibilityLabel(L10n.tr("Choose \(title) destination folder"))

                Button(action: revealAction) {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(!canReveal)
                .help(L10n.tr("Reveal \(title) destination folder in Finder"))
                .accessibilityLabel(L10n.tr("Reveal \(title) destination folder in Finder"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct DestinationStatusLine: View {
    let result: PathValidationResult

    var body: some View {
        AppStatusLabel(
            title: message,
            systemImage: systemImage,
            role: statusRole
        )
            .font(.callout)
            .lineLimit(1)
    }

    private var message: String {
        switch result.status {
        case .empty:
            return L10n.tr("Choose a folder")
        case .missing:
            return L10n.tr("Unavailable")
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

    private var statusRole: AppStatusLabel.Role {
        switch result.status {
        case .ready, .missing:
            return .neutral
        default:
            return .warning
        }
    }
}

private extension AppThemePreference {
    var settingsTitle: String {
        switch self {
        case .system:
            return L10n.tr("System")
        case .light:
            return L10n.tr("Light")
        case .dark:
            return L10n.tr("Dark")
        }
    }
}

private extension RetentionPolicy {
    var settingsTitle: String {
        switch self {
        case .days(let days):
            return L10n.tr("\(days) days")
        case .forever:
            return L10n.tr("Forever")
        }
    }
}
