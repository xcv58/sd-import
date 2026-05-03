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
}
