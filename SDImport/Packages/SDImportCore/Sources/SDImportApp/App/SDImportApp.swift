import AppKit
import SDImportCore
import SwiftUI

@main
@MainActor
struct SDImportApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var appUpdater = AppUpdater()

    var body: some Scene {
        WindowGroup("SD Import") {
            RootView(appUpdater: appUpdater)
                .environmentObject(model)
                .preferredColorScheme(model.themePreference.colorScheme)
                .frame(minWidth: 760, minHeight: 560)
        }
        .commands {
            SidebarCommands()

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

            CommandMenu("Navigate") {
                Button("Import") {
                    model.selectPanel(.import)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("History") {
                    model.selectPanel(.history)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Settings") {
                    model.selectPanel(.settings)
                }
                .keyboardShortcut("3", modifiers: [.command])

                Divider()

                Button("Next Panel") {
                    model.selectNextPanel()
                }
                .keyboardShortcut(.tab, modifiers: [.control])

                Button("Previous Panel") {
                    model.selectPreviousPanel()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }

            CommandGroup(after: .help) {
                Button("Diagnostics...") {
                    openWindow(id: "diagnostics")
                }
            }
        }

        Settings {
            SettingsView(appUpdater: appUpdater)
                .environmentObject(model)
                .preferredColorScheme(model.themePreference.colorScheme)
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(model)
                .preferredColorScheme(model.themePreference.colorScheme)
                .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 720, height: 500)
    }
}

private extension AppThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
