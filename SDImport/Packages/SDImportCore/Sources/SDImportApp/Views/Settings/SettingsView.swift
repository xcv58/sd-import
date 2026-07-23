import SDImportCore
import Sparkle
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    let updater: SPUUpdater?

    var body: some View {
        AppPage {
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
        .onChange(of: model.photosPath) {
            model.validatePaths()
        }
        .onChange(of: model.videosPath) {
            model.validatePaths()
        }
    }

    private var destinations: some View {
        AppSection("Default Destinations", systemImage: "folder") {
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
        }
    }

    private var general: some View {
        AppSection("General", systemImage: "gearshape") {
            SettingsFormRow("Theme") {
                Picker(selection: $model.themePreference) {
                    ForEach(AppThemePreference.allCases) { theme in
                        Text(theme.settingsTitle).tag(theme)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityLabel("Theme")
                .pickerStyle(.segmented)
                .frame(width: SettingsLayout.segmentedControlWidth)
                .onChange(of: model.themePreference) {
                    model.themePreferenceDidChange()
                }
            }

            SettingsFormRow("History") {
                Picker(selection: $model.historyRetention) {
                    ForEach(RetentionPolicy.supportedValues, id: \.self) { policy in
                        Text(policy.settingsTitle).tag(policy)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .accessibilityLabel("History")
                .frame(width: SettingsLayout.compactPickerWidth)
                .onChange(of: model.historyRetention) {
                    model.savePreferences()
                }
            }

            SettingsFormRow {
                Toggle("Prompt on card mount", isOn: $model.autoPromptEnabled)
                    .onChange(of: model.autoPromptEnabled) {
                        model.savePreferences()
                        model.updateLoginItemRegistration()
                    }
            }

            SettingsFormRow {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Eject source after successful import", isOn: $model.ejectAfterSuccessfulImport)
                        .onChange(of: model.ejectAfterSuccessfulImport) {
                            model.savePreferences()
                        }

                    Text("Only removable sources are ejected after an error-free copy. Zero-copy scans still offer a manual Eject button.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var updates: some View {
        AppSection("Updates", systemImage: "arrow.clockwise") {
            UpdaterSettingsView(
                updater: updater,
                leadingInset: SettingsLayout.controlColumnStart
            )
        }
    }
}

private enum SettingsLayout {
    static let labelWidth: CGFloat = 118
    static let columnSpacing: CGFloat = 12
    static let controlWidth: CGFloat = 620
    static let segmentedControlWidth: CGFloat = 280
    static let compactPickerWidth: CGFloat = 140
    static let controlColumnStart = labelWidth + columnSpacing
}

private struct SettingsFormRow<Content: View>: View {
    private let title: String?
    private let content: Content

    init(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.columnSpacing) {
            Group {
                if let title {
                    Text(title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                } else {
                    Color.clear
                }
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .trailing)
            .padding(.top, 5)

            content
                .frame(maxWidth: SettingsLayout.controlWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
    }
}

private struct FolderSettingRow: View {
    let title: String
    @Binding var path: String
    let validation: PathValidationResult
    let action: () -> Void

    var body: some View {
        SettingsFormRow(title) {
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

                DestinationStatusLine(result: validation)

                if validation.isUsable, let capacityText {
                    Label(capacityText, systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: SettingsLayout.controlWidth)
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
            .font(.caption)
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
