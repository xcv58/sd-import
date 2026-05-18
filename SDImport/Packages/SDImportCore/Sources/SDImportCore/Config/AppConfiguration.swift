import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let storageKey = "app.configuration"

    public var sourcePath: String
    public var photosPath: String
    public var videosPath: String
    public var defaultLocation: String
    public var historyRetention: RetentionPolicy
    public var autoPromptEnabled: Bool
    public var hasCompletedOnboarding: Bool
    public var lastWorkflowProfile: ImportWorkflowProfile
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
        hasCompletedOnboarding: Bool = false,
        lastWorkflowProfile: ImportWorkflowProfile = .mixedShootSession,
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
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.lastWorkflowProfile = lastWorkflowProfile
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
        case hasCompletedOnboarding
        case lastWorkflowProfile
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
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        lastWorkflowProfile = try container.decodeIfPresent(
            ImportWorkflowProfile.self,
            forKey: .lastWorkflowProfile
        ) ?? .mixedShootSession
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
