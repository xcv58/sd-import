import Foundation

public struct LegacyStateLocation: Hashable, Codable, Sendable {
    public let stateDirectory: URL
    public let databaseURL: URL
    public let configURL: URL
    public let reportsDirectoryURL: URL
    public let progressDirectoryURL: URL

    public init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
        self.databaseURL = stateDirectory.appendingPathComponent("state.db", isDirectory: false)
        self.configURL = stateDirectory.appendingPathComponent("config.json", isDirectory: false)
        self.reportsDirectoryURL = stateDirectory.appendingPathComponent("reports", isDirectory: true)
        self.progressDirectoryURL = stateDirectory.appendingPathComponent("progress", isDirectory: true)
    }

    public func exists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: databaseURL.path)
            || fileManager.fileExists(atPath: configURL.path)
    }
}

public struct LegacyStateImporter {
    public let legacyLocation: LegacyStateLocation
    public let nativeStateDirectory: URL
    public let fileManager: FileManager

    public init(
        legacyLocation: LegacyStateLocation,
        nativeStateDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.legacyLocation = legacyLocation
        self.nativeStateDirectory = nativeStateDirectory
        self.fileManager = fileManager
    }

    public static func defaultLegacyLocation(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LegacyStateLocation {
        LegacyStateLocation(
            stateDirectory: homeDirectory.appendingPathComponent(".sd-import", isDirectory: true)
        )
    }

    public func canImportLegacyState() -> Bool {
        legacyLocation.exists(fileManager: fileManager)
    }
}
