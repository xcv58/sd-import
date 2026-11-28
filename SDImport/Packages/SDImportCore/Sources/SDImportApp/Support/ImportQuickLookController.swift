@preconcurrency import AppKit
@preconcurrency import QuickLookUI

@MainActor
final class ImportQuickLookController: NSObject, ObservableObject, @preconcurrency QLPreviewPanelDataSource {
    private var urls: [URL] = []

    func present(row: ImportPreviewRow, among rows: [ImportPreviewRow]) {
        let relatedRows = row.visualGroupID.map { id in rows.filter { $0.visualGroupID == id } } ?? rows
        present(
            urls: relatedRows.map { URL(fileURLWithPath: $0.sourcePath, isDirectory: false) },
            selectedURL: URL(fileURLWithPath: row.sourcePath, isDirectory: false)
        )
    }

    func present(urls: [URL], selectedURL: URL) {
        let availableURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard
            !availableURLs.isEmpty,
            let selectedIndex = availableURLs.firstIndex(of: selectedURL),
            let panel = QLPreviewPanel.shared()
        else {
            return
        }

        self.urls = availableURLs
        panel.dataSource = self
        panel.currentPreviewItemIndex = selectedIndex
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        QLPreviewPanel.shared()?.close()
        urls = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else {
            return nil
        }
        return urls[index] as NSURL
    }
}
