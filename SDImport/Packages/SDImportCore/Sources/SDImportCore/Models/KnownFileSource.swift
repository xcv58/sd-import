import Foundation

public enum KnownFileSource: String, Codable, Hashable, Sendable {
    case localLedger = "local_ledger"
    case portableLedger = "portable_ledger"
    case destination = "destination"

    public var skippedStatusTitle: String {
        switch self {
        case .portableLedger:
            return L10n.tr("Other Mac")
        case .localLedger:
            return L10n.tr("Known")
        case .destination:
            return L10n.tr("Already Exists")
        }
    }
}
