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

    public init(
        sourcePath: String,
        photosPath: String,
        videosPath: String,
        defaultLocation: String,
        historyRetention: RetentionPolicy = .defaultPolicy,
        autoPromptEnabled: Bool = false,
        hasCompletedOnboarding: Bool = false
    ) {
        self.sourcePath = sourcePath
        self.photosPath = photosPath
        self.videosPath = videosPath
        self.defaultLocation = defaultLocation
        self.historyRetention = historyRetention
        self.autoPromptEnabled = autoPromptEnabled
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    public static func defaultConfiguration(homeDirectory: URL) -> AppConfiguration {
        AppConfiguration(
            sourcePath: "/Volumes",
            photosPath: homeDirectory.appendingPathComponent("Pictures/Photos", isDirectory: true).path,
            videosPath: homeDirectory.appendingPathComponent("Downloads", isDirectory: true).path,
            defaultLocation: "TODO"
        )
    }
}
