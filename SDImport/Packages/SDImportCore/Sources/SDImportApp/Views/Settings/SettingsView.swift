import SDImportCore
import Sparkle
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    let updater: SPUUpdater?

    var body: some View {
        TabView {
            destinations
                .tabItem {
                    Label("Destinations", systemImage: "folder")
                }

            general
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            updates
                .tabItem {
                    Label("Updates", systemImage: "arrow.clockwise")
                }
        }
        .frame(width: 560, height: 340)
    }

    private var destinations: some View {
        Form {
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
            TextField("Location", text: $model.location)
                .onSubmit {
                    model.savePreferences()
                }
        }
        .padding(20)
        .onDisappear {
            model.savePreferences()
        }
    }

    private var general: some View {
        Form {
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
        .padding(20)
    }

    private var updates: some View {
        Form {
            UpdaterSettingsView(updater: updater)
        }
        .padding(20)
    }
}

private struct FolderSettingRow: View {
    let title: String
    @Binding var path: String
    let action: () -> Void

    var body: some View {
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
