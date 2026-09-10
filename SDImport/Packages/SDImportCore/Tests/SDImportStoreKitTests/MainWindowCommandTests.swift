import AppKit
import SDImportCore
import XCTest

@MainActor
final class MainWindowCommandTests: XCTestCase {
    func testMenuCommandsReopenClosedMainWindow() async throws {
        _ = try await waitForMainWindow()
        let appMenuTitle = try XCTUnwrap(NSApp.mainMenu?.item(at: 0)?.title)

        for (menu, command, expectedPanel) in [
            ("Window", "Show SD Card Import", "Import"),
            ("File", "Import From Card...", "Import"),
            ("Navigate", "History", "History"),
            ("Navigate", "Settings", "Settings"),
            ("Navigate", "Import", "Import"),
            ("Navigate", "Next Panel", "History"),
            ("Navigate", "Previous Panel", "Import"),
            (appMenuTitle, "Settings…", "Settings")
        ] {
            let window = try await waitForMainWindow()
            window.performClose(nil)
            XCTAssertFalse(window.isVisible, "Main window must be closed before testing \(command)")
            try invoke(menu: menu, command: command)
            let reopened = try await waitForMainWindow()
            XCTAssertEqual(reopened.title, expectedPanel, command)
            XCTAssertEqual(mainWindows.filter(\.isVisible).count, 1, "\(command) must not duplicate the main window")
        }
    }

    func testImportKeyboardShortcutAndDockReopen() async throws {
        let window = try await waitForMainWindow()
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        let shortcut = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "i",
            charactersIgnoringModifiers: "i",
            isARepeat: false,
            keyCode: 34
        ))
        XCTAssertEqual(NSApp.mainMenu?.performKeyEquivalent(with: shortcut), true)
        let imported = try await waitForMainWindow()
        XCTAssertEqual(imported.title, "Import")

        imported.performClose(nil)
        XCTAssertFalse(imported.isVisible)
        XCTAssertEqual(NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false), true)
        _ = try await waitForMainWindow()
    }

    func testShowCommandRestoresMinimizedWindowAndLeavesDiagnosticsOpen() async throws {
        let window = try await waitForMainWindow()
        window.miniaturize(nil)
        try invoke(menu: "Window", command: "Show SD Card Import")
        let restored = try await waitForMainWindow()
        XCTAssertTrue(restored === window)
        XCTAssertFalse(restored.isMiniaturized)

        try invoke(menu: "Help", command: "Diagnostics...")
        for _ in 0..<100 where !NSApp.windows.contains(where: { $0.title == "Diagnostics" && $0.isVisible }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let diagnostics = try XCTUnwrap(NSApp.windows.first { $0.title == "Diagnostics" && $0.isVisible })
        defer { diagnostics.close() }
        restored.performClose(nil)
        XCTAssertFalse(restored.isVisible)
        try invoke(menu: "Window", command: "Show SD Card Import")
        _ = try await waitForMainWindow()
        XCTAssertTrue(diagnostics.isVisible)
    }

    private var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier == MainWindowPresenter.windowIdentifier }
    }

    private func waitForMainWindow() async throws -> NSWindow {
        for _ in 0..<100 {
            if let window = mainWindows.first(where: { $0.isVisible && !$0.isMiniaturized }) {
                // Let SwiftUI apply the selected panel's navigation title.
                try await Task.sleep(for: .milliseconds(100))
                return window
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(nil as NSWindow?, "Main window did not become visible")
    }

    private func invoke(menu title: String, command: String) throws {
        let menu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: title)?.submenu)
        menu.update()
        let item = try XCTUnwrap(menu.item(withTitle: command))
        XCTAssertTrue(item.isEnabled, "\(title) → \(command) must remain enabled without a main window")
        menu.performActionForItem(at: menu.index(of: item))
    }
}
