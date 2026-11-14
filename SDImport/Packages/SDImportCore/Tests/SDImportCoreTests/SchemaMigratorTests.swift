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

        let jobFileColumns = try pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('job_files')")
        }
        #expect(jobFileColumns.contains("mtime_epoch_seconds"))
        #expect(jobFileColumns.contains("portable_receipt_override"))

        let userVersion = try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(userVersion == Int(SchemaMigrator.currentUserVersion))
    }

    @Test("upgrades v3 imports with safe receipt and review defaults")
    func upgradesVersionThreeJobFiles() throws {
        let directoryURL = try temporaryDirectory()
        let databaseURL = directoryURL.appendingPathComponent("state.sqlite")
        let pool = try DatabasePool(path: databaseURL.path)
        let migrator = SchemaMigrator.makeMigrator()
        try migrator.migrate(pool, upTo: SchemaMigrator.knownFileSourceMigrationIdentifier)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO jobs (
                    job_id, created_at, mount_path, location, photos_root, videos_root, status
                ) VALUES ('legacy-job', '2026-07-31T00:00:00Z', '/Volumes/CARD', 'TEST',
                    '/tmp/photos', '/tmp/videos', 'SCANNED')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO job_files (
                    job_id, src_path, filename, ext, size, mtime, media_type, decision, copy_status
                ) VALUES ('legacy-job', '/Volumes/CARD/IMG.JPG', 'IMG.JPG', '.jpg', 17,
                    '2026-07-31T12:00:00', 'photo', 'NEW', 'PENDING')
                """
            )
        }

        try SchemaMigrator.migrate(pool)

        let values = try pool.read { db -> (Int64?, Bool) in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM job_files LIMIT 1") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (row["mtime_epoch_seconds"], row["portable_receipt_override"])
        }
        #expect(values.0 == nil)
        #expect(values.1 == false)
        #expect(try JobRepository(pool: pool).needsDestinationReview(jobID: "legacy-job") == false)
    }
}
