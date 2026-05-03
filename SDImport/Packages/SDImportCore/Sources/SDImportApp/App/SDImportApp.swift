import AppKit
import SDImportCore
import SwiftUI

@main
@MainActor
struct SDImportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    private let appUpdater = AppUpdater()

    var body: some Scene {
        WindowGroup("SD Import") {
            RootView(updater: appUpdater.updater)
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

            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    model.selectPanel(.settings)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: [.command])
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

                Button("Diagnostics") {
                    model.selectPanel(.diagnostics)
                }
                .keyboardShortcut("4", modifiers: [.command])

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
        }
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
