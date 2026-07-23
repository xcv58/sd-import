import Foundation

enum SidebarItem: String, CaseIterable, Identifiable {
    case `import`
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .import:
            return "Import"
        case .history:
            return "History"
        }
    }

    var systemImage: String {
        switch self {
        case .import:
            return "square.and.arrow.down"
        case .history:
            return "clock.arrow.circlepath"
        }
    }

    var shortcutHint: String {
        switch self {
        case .import:
            return "⌘1"
        case .history:
            return "⌘2"
        }
    }

    func panel(offsetBy offset: Int) -> SidebarItem {
        let items = Self.allCases
        guard let currentIndex = items.firstIndex(of: self) else {
            return self
        }
        let nextIndex = (currentIndex + offset + items.count) % items.count
        return items[nextIndex]
    }
}
