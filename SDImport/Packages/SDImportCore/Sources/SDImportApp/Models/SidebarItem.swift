import Foundation

enum SidebarItem: String, CaseIterable, Identifiable {
    case `import`
    case history
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .import:
            return "Import"
        case .history:
            return "History"
        case .settings:
            return "Settings"
        case .diagnostics:
            return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .import:
            return "square.and.arrow.down"
        case .history:
            return "clock.arrow.circlepath"
        case .settings:
            return "gearshape"
        case .diagnostics:
            return "stethoscope"
        }
    }

    var shortcutHint: String {
        switch self {
        case .import:
            return "⌘1"
        case .history:
            return "⌘2"
        case .settings:
            return "⌘3"
        case .diagnostics:
            return "⌘4"
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
