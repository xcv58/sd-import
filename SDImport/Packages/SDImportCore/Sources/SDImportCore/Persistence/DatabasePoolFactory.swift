import Foundation
import GRDB

public struct DatabasePoolFactory {
    public let databaseURL: URL
    public let fileManager: FileManager

    public init(databaseURL: URL, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    public func makeMigratedPool() throws -> DatabasePool {
        let directoryURL = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try SchemaMigrator.migrate(pool)
        return pool
    }

    public static func defaultApplicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SDImportError.missingApplicationSupportDirectory
        }

        return applicationSupport.appendingPathComponent("SD Import", isDirectory: true)
    }

    public static func defaultDatabaseURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        try defaultApplicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("state.sqlite", isDirectory: false)
    }
}
