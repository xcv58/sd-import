import SDImportCore
import Sparkle
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    let updater: SPUUpdater?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                destinations
                general
                updates
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        .onDisappear {
            model.savePreferences()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.title)
                .fontWeight(.semibold)
            Text(model.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private var destinations: some View {
        SettingsSection(title: "Destinations", systemImage: "folder") {
            FolderSettingRow(
                title: "Card or source",
                path: $model.cardPath,
                action: model.chooseCardFolder
            )
            FolderSettingRow(
                title: "Photos",
                path: $model.photosPath,
                action: model.choosePhotosFolder
            )
            FolderSettingRow(
                title: "Videos",
                path: $model.videosPath,
                action: model.chooseVideosFolder
            )
            LabeledContent("Location") {
                TextField("Location", text: $model.location)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit {
                        model.savePreferences()
                    }
            }
        }
    }

    private var general: some View {
        SettingsSection(title: "General", systemImage: "gearshape") {
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
        SettingsSection(title: "Updates", systemImage: "arrow.clockwise") {
            UpdaterSettingsView(updater: updater)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FolderSettingRow: View {
    let title: String
    @Binding var path: String
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: $path)
                    .textFieldStyle(.roundedBorder)

                Button {
                    action()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose \(title.lowercased())")
            }
            .frame(maxWidth: 520)
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
