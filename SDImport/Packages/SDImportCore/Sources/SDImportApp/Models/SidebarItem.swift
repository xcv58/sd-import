import SDImportCore
import Foundation

enum SidebarItem: String, CaseIterable, Identifiable {
    case `import`
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .import:
            return L10n.tr("Import")
        case .history:
            return L10n.tr("History")
        case .settings:
            return L10n.tr("Settings")
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
