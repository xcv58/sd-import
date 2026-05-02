import SwiftUI

@main
@MainActor
struct SDImportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    private let appUpdater = AppUpdater()

    var body: some Scene {
        WindowGroup("SD Import") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appUpdater.updater)
            }

            CommandGroup(after: .newItem) {
                Button("Import From Card...") {
                    model.selection = .import
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Refresh History") {
                    model.refreshHistory()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(updater: appUpdater.updater)
                .environmentObject(model)
        }
    }
}
