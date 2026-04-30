import Foundation
import GRDB
import Testing

@testable import SDImportCore

@Suite("SchemaMigrator")
struct SchemaMigratorTests {
    @Test("creates the initial native schema")
    func createsInitialSchema() throws {
        let directoryURL = try temporaryDirectory()
        let databaseURL = directoryURL.appendingPathComponent("state.sqlite")
        let pool = try DatabasePoolFactory(databaseURL: databaseURL).makeMigratedPool()

        let tableNames = try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                ORDER BY name
                """
            )
        }

        #expect(tableNames.contains("settings"))
        #expect(tableNames.contains("bookmarks"))
        #expect(tableNames.contains("items"))
        #expect(tableNames.contains("jobs"))
        #expect(tableNames.contains("job_files"))
        #expect(tableNames.contains("schema_migrations"))

        let userVersion = try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(userVersion == Int(SchemaMigrator.currentUserVersion))
    }
}
