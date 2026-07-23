import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let storageKey = "app.configuration"

    public var sourcePath: String
    public var photosPath: String
    public var videosPath: String
    public var defaultLocation: String
    public var historyRetention: RetentionPolicy
    public var autoPromptEnabled: Bool
    public var ejectAfterSuccessfulImport: Bool
    public var hasCompletedOnboarding: Bool
    public var lastWorkflowProfile: ImportWorkflowProfile
    public var lastMediaSelection: ImportMediaSelection
    public var lastDestinationLayout: ImportDestinationLayout
    public var preferredMixedDestinationLayout: ImportDestinationLayout
    public var lastFolderGrouping: ImportFolderGrouping
    public var themePreference: AppThemePreference
    public var workflowProfilesByVolume: [String: ImportWorkflowProfile]
    public var hiddenRecentPaths: [String]

    public init(
        sourcePath: String,
        photosPath: String,
        videosPath: String,
        defaultLocation: String,
        historyRetention: RetentionPolicy = .defaultPolicy,
        autoPromptEnabled: Bool = false,
        ejectAfterSuccessfulImport: Bool = false,
        hasCompletedOnboarding: Bool = false,
        lastWorkflowProfile: ImportWorkflowProfile = .mixedShootSession,
        lastMediaSelection: ImportMediaSelection? = nil,
        lastDestinationLayout: ImportDestinationLayout? = nil,
        preferredMixedDestinationLayout: ImportDestinationLayout = .singleLibrary,
        lastFolderGrouping: ImportFolderGrouping = .byDay,
        themePreference: AppThemePreference = .system,
        workflowProfilesByVolume: [String: ImportWorkflowProfile] = [:],
        hiddenRecentPaths: [String] = []
    ) {
        self.sourcePath = sourcePath
        self.photosPath = photosPath
        self.videosPath = videosPath
        self.defaultLocation = defaultLocation
        self.historyRetention = historyRetention
        self.autoPromptEnabled = autoPromptEnabled
        self.ejectAfterSuccessfulImport = ejectAfterSuccessfulImport
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.lastWorkflowProfile = lastWorkflowProfile
        self.lastMediaSelection = lastMediaSelection ?? lastWorkflowProfile.mediaSelection
        self.lastDestinationLayout = lastDestinationLayout ?? ImportDestinationLayout(
            organizationPreset: lastWorkflowProfile.organizationPreset
        )
        self.preferredMixedDestinationLayout = preferredMixedDestinationLayout == .footageBackup
            ? .singleLibrary
            : preferredMixedDestinationLayout
        self.lastFolderGrouping = lastFolderGrouping
        self.themePreference = themePreference
        self.workflowProfilesByVolume = workflowProfilesByVolume
        self.hiddenRecentPaths = hiddenRecentPaths
    }

    public static func defaultConfiguration(homeDirectory: URL) -> AppConfiguration {
        AppConfiguration(
            sourcePath: "/Volumes",
            photosPath: homeDirectory.appendingPathComponent("Pictures/Photos", isDirectory: true).path,
            videosPath: homeDirectory.appendingPathComponent("Downloads", isDirectory: true).path,
            defaultLocation: "Untitled"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sourcePath
        case photosPath
        case videosPath
        case defaultLocation
        case historyRetention
        case autoPromptEnabled
        case ejectAfterSuccessfulImport
        case hasCompletedOnboarding
        case lastWorkflowProfile
        case lastMediaSelection
        case lastDestinationLayout
        case preferredMixedDestinationLayout
        case lastFolderGrouping
        case themePreference
        case workflowProfilesByVolume
        case hiddenRecentPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        photosPath = try container.decode(String.self, forKey: .photosPath)
        videosPath = try container.decode(String.self, forKey: .videosPath)
        defaultLocation = try container.decode(String.self, forKey: .defaultLocation)
        historyRetention = try container.decodeIfPresent(RetentionPolicy.self, forKey: .historyRetention) ?? .defaultPolicy
        autoPromptEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoPromptEnabled) ?? false
        ejectAfterSuccessfulImport = try container.decodeIfPresent(
            Bool.self,
            forKey: .ejectAfterSuccessfulImport
        ) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        lastWorkflowProfile = try container.decodeIfPresent(
            ImportWorkflowProfile.self,
            forKey: .lastWorkflowProfile
        ) ?? .mixedShootSession
        lastMediaSelection = try container.decodeIfPresent(
            ImportMediaSelection.self,
            forKey: .lastMediaSelection
        ) ?? lastWorkflowProfile.mediaSelection
        lastDestinationLayout = try container.decodeIfPresent(
            ImportDestinationLayout.self,
            forKey: .lastDestinationLayout
        ) ?? ImportDestinationLayout(organizationPreset: lastWorkflowProfile.organizationPreset)
        let decodedPreferredMixedDestinationLayout = try container.decodeIfPresent(
            ImportDestinationLayout.self,
            forKey: .preferredMixedDestinationLayout
        )
        preferredMixedDestinationLayout = decodedPreferredMixedDestinationLayout == .footageBackup
            ? .singleLibrary
            : decodedPreferredMixedDestinationLayout ?? (
                lastDestinationLayout == .footageBackup ? .singleLibrary : lastDestinationLayout
            )
        lastFolderGrouping = try container.decodeIfPresent(
            ImportFolderGrouping.self,
            forKey: .lastFolderGrouping
        ) ?? .byDay
        themePreference = try container.decodeIfPresent(
            AppThemePreference.self,
            forKey: .themePreference
        ) ?? .system
        workflowProfilesByVolume = try container.decodeIfPresent(
            [String: ImportWorkflowProfile].self,
            forKey: .workflowProfilesByVolume
        ) ?? [:]
        hiddenRecentPaths = try container.decodeIfPresent([String].self, forKey: .hiddenRecentPaths) ?? []
    }
}
