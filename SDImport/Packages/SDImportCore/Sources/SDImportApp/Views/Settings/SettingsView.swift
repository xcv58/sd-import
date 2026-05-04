import SDImportCore
import Sparkle
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    let updater: SPUUpdater?

    var body: some View {
        AppPage(title: "Settings", status: model.statusMessage) {
            VStack(alignment: .leading, spacing: 18) {
                destinations
                general
                updates
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            model.validatePaths()
        }
        .onDisappear {
            model.savePreferences()
        }
        .onChange(of: model.cardPath) {
            model.sourcePathDidChange()
        }
        .onChange(of: model.photosPath) {
            model.validatePaths()
        }
        .onChange(of: model.videosPath) {
            model.validatePaths()
        }
    }

    private var destinations: some View {
        AppSection("Destinations", systemImage: "folder") {
            FolderSettingRow(
                title: "Card or source",
                path: $model.cardPath,
                validation: model.sourceValidation,
                action: model.chooseCardFolder
            )
            FolderSettingRow(
                title: "Photos",
                path: $model.photosPath,
                validation: model.photosValidation,
                action: model.choosePhotosFolder
            )
            FolderSettingRow(
                title: "Videos",
                path: $model.videosPath,
                validation: model.videosValidation,
                action: model.chooseVideosFolder
            )
            LabeledContent("Shoot name") {
                TextField("Shoot name", text: $model.location)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit {
                        model.savePreferences()
                    }
            }
        }
    }

    private var general: some View {
        AppSection("General", systemImage: "gearshape") {
            Picker("Theme", selection: $model.themePreference) {
                ForEach(AppThemePreference.allCases) { theme in
                    Text(theme.settingsTitle).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .onChange(of: model.themePreference) {
                model.themePreferenceDidChange()
            }

            Picker("History", selection: $model.historyRetention) {
                ForEach(RetentionPolicy.supportedValues, id: \.self) { policy in
                    Text(policy.settingsTitle).tag(policy)
                }
            }
            .onChange(of: model.historyRetention) {
                model.savePreferences()
            }

            Toggle("Prompt on card mount", isOn: $model.autoPromptEnabled)
                .onChange(of: model.autoPromptEnabled) {
                    model.savePreferences()
                    model.updateLoginItemRegistration()
                }
        }
    }

    private var updates: some View {
        AppSection("Updates", systemImage: "arrow.clockwise") {
            UpdaterSettingsView(updater: updater)
        }
    }
}

private struct FolderSettingRow: View {
    let title: String
    @Binding var path: String
    let validation: PathValidationResult
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TextField(title, text: $path)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        action()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose \(title.lowercased())")
                    .accessibilityLabel("Choose \(title.lowercased())")
                }

                PathStatusLine(result: validation)

                if validation.isUsable, let capacityText {
                    Label(capacityText, systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 520)
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

private struct PathStatusLine: View {
    let result: PathValidationResult

    var body: some View {
        Label(result.message, systemImage: result.isUsable ? "checkmark.circle" : "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(result.isUsable ? Color.secondary : Color.orange)
            .lineLimit(1)
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
