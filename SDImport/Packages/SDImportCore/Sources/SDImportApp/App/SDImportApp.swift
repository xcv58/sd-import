import AppKit
import SDImportCommerce
import SDImportCore
import SwiftUI

@main
@MainActor
struct SDImportApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var appUpdater = AppUpdater()
    @StateObject private var purchaseManager: PurchaseManager

    init() {
        let purchaseManager = PurchaseManager()
        let model = AppModel(purchaseManager: purchaseManager)
        _model = StateObject(wrappedValue: model)
        _purchaseManager = StateObject(wrappedValue: purchaseManager)
        ApplicationLifecycleCoordinator.shared.install(
            didBecomeActive: { [weak model] in
                model?.applicationDidBecomeActive()
            },
            mainWindowWillPresent: { [weak model] in
                model?.mainWindowWillPresent()
            },
            mainWindowDidAppear: { [weak model] in
                model?.mainWindowDidAppear()
            }
        )
#if DEBUG
        if BackgroundPromptRuntimeQA.preparesApplication() {
            Task { @MainActor in
                do {
                    try await LoginItemController.setEnabled(false)
                    try await LoginItemController.setEnabled(true)
                } catch {
                    NSLog("SD Import helper runtime QA registration failed: %@", error.localizedDescription)
                }
            }
        }
        if BackgroundPromptRuntimeQA.unregistersHelper() {
            Task { @MainActor in
                try? await LoginItemController.setEnabled(false)
                try? BackgroundPromptRuntimeQA.clearHelperLifecycleMarker()
                NSApp.terminate(nil)
            }
        }
#endif
    }

    var body: some Scene {
        Window(AppDistribution.current.displayName, id: "main") {
            RootView(appUpdater: appUpdater)
                .environmentObject(model)
                .environmentObject(purchaseManager)
                .preferredColorScheme(model.themePreference.colorScheme)
                .frame(minWidth: 760, minHeight: 560)
                .background(MainWindowIdentifierView())
                .onAppear {
                    MainWindowPresentationCoordinator.shared.installWindowOpener {
                        openWindow(id: "main")
                    }
                    ApplicationLifecycleCoordinator.shared.mainWindowDidAppear()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            SidebarCommands()

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    showPanel(.settings)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: appUpdater)
            }

            CommandGroup(replacing: .newItem) {
                Button("Import From Card...") {
                    showPanel(.import)
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Refresh History") {
                    model.refreshHistory()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            CommandGroup(before: .windowArrangement) {
                Button("Show \(AppDistribution.current.displayName)") {
                    showMainWindow()
                }
            }

            CommandMenu("Navigate") {
                Button("Import") {
                    showPanel(.import)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("History") {
                    showPanel(.history)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Settings") {
                    showPanel(.settings)
                }
                .keyboardShortcut("3", modifiers: [.command])

                Divider()

                Button("Next Panel") {
                    model.selectNextPanel()
                    showMainWindow()
                }
                .keyboardShortcut(.tab, modifiers: [.control])

                Button("Previous Panel") {
                    model.selectPreviousPanel()
                    showMainWindow()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }

            CommandGroup(after: .help) {
                Button("Diagnostics...") {
                    openWindow(id: "diagnostics")
                }
            }
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView()
                .environmentObject(model)
                .preferredColorScheme(model.themePreference.colorScheme)
                .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 720, height: 500)
    }

    private func showPanel(_ panel: SidebarItem) {
        model.selectPanel(panel)
        showMainWindow()
    }

    private func showMainWindow() {
        ApplicationLifecycleCoordinator.shared.mainWindowWillPresent()
        MainWindowPresenter.present()
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
