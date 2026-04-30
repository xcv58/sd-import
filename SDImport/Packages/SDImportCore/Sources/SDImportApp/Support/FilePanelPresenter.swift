import AppKit
import Foundation

enum FilePanelPresenter {
    @MainActor
    static func chooseDirectory(title: String, initialPath: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let initialPath, !initialPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (initialPath as NSString).expandingTildeInPath)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor
    static func chooseSaveURL(title: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
