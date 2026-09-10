import Foundation

public struct MountPrivacyPolicy: Equatable, Sendable {
    public let includesCapacityBeforeConsent: Bool
    public let probesMediaBeforeConsent: Bool
    public let usesDistributedNotificationHandoff: Bool

    init(
        includesCapacityBeforeConsent: Bool,
        probesMediaBeforeConsent: Bool,
        usesDistributedNotificationHandoff: Bool
    ) {
        self.includesCapacityBeforeConsent = includesCapacityBeforeConsent
        self.probesMediaBeforeConsent = probesMediaBeforeConsent
        self.usesDistributedNotificationHandoff = usesDistributedNotificationHandoff
    }
}

public enum AppDistribution: String, Codable, Sendable {
    case direct
    case macAppStore = "app-store"

    public static let appStoreBundleIdentifier = "media.jenny.sdimport"
    public static let appStoreAgentBundleIdentifier = "media.jenny.sdimport.agent"
    public static let appGroupIdentifier = "group.media.jenny.sdimport"
    public static let lifetimeProductIdentifier = "media.jenny.sdimport.unlimited"

    public var displayName: String {
        switch self {
        case .direct: "SD Import"
        case .macAppStore: "SD Card Import"
        }
    }

    public static var current: AppDistribution {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "SDImportDistribution") as? String,
            let distribution = AppDistribution(rawValue: value)
        else {
            return .direct
        }
        return distribution
    }

    public var requiresConsentBeforeMediaProbe: Bool {
        !mountPrivacyPolicy.probesMediaBeforeConsent
    }

    public var mountPrivacyPolicy: MountPrivacyPolicy {
        switch self {
        case .direct:
            MountPrivacyPolicy(
                includesCapacityBeforeConsent: true,
                probesMediaBeforeConsent: true,
                usesDistributedNotificationHandoff: true
            )
        case .macAppStore:
            MountPrivacyPolicy(
                includesCapacityBeforeConsent: false,
                probesMediaBeforeConsent: false,
                usesDistributedNotificationHandoff: false
            )
        }
    }

    public var usesSharedAppGroupContainer: Bool {
        self == .macAppStore
    }

    public var importsUnsandboxedLegacyState: Bool {
        self == .direct
    }

    public var canBrowseSystemCrashReports: Bool {
        self == .direct
    }

    public var supportsSourceEjection: Bool {
        true
    }

    public var staleBookmarkHandling: StaleBookmarkHandling {
        switch self {
        case .direct:
            .refresh
        case .macAppStore:
            .requireNewSelection
        }
    }

    public func retainedDestinationPath(
        _ path: String,
        hasAuthorizedAccess: Bool
    ) -> String {
        switch self {
        case .direct:
            path
        case .macAppStore:
            hasAuthorizedAccess ? path : ""
        }
    }
}
