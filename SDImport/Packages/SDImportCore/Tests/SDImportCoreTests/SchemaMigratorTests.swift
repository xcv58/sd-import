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

        let values = try pool.read { db -> (Int64?, Bool, Bool) in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM job_files LIMIT 1") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (row["mtime_epoch_seconds"], row["portable_receipt_override"], row["reimport_requested"])
        }
        #expect(values.0 == nil)
        #expect(values.1 == false)
        #expect(values.2 == false)
        let repository = JobRepository(pool: pool)
        #expect(try repository.needsDestinationReview(jobID: "legacy-job") == false)
        let migratedJob = try repository.fetchJob(id: "legacy-job")
        let legacyJob = try #require(migratedJob)
        #expect(legacyJob.volumeMountPath == nil)
        #expect(legacyJob.rescanOfJobID == nil)
        let recordedAsForgotten = try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT local_history_forgotten FROM jobs WHERE job_id = 'legacy-job'")
        }
        #expect(recordedAsForgotten == false)
    }

    @Test("preserves unresolved copy evidence from the earlier journal schema")
    func upgradesEarlierCopyJournal() throws {
        let directoryURL = try temporaryDirectory()
        let pool = try DatabasePool(path: directoryURL.appendingPathComponent("state.sqlite").path)
        try SchemaMigrator.makeMigrator().migrate(pool, upTo: SchemaMigrator.copyAttemptMigrationIdentifier)
        let destination = directoryURL.appendingPathComponent("IMG.JPG")
        try pool.write { db in
            try db.execute(sql: """
                ALTER TABLE import_copy_attempts DROP COLUMN copy_committed;
                INSERT INTO jobs (job_id, created_at, mount_path, location, photos_root, videos_root, status)
                VALUES ('draft-job', '2026-11-15T00:00:00Z', '/Volumes/CARD', 'TEST', '/tmp/photos', '/tmp/videos', 'IMPORTING');
                INSERT INTO job_files (id, job_id, src_path, filename, ext, size, mtime, media_type, decision, copy_status)
                VALUES (1, 'draft-job', '/Volumes/CARD/IMG.JPG', 'IMG.JPG', '.jpg', 17, '2026-11-15T00:00:00Z',
                    'photo', 'NEW', 'PENDING');
                """)
            let attempt = ImportCopyAttempt(
                id: UUID(), fileID: 1, jobID: "draft-job", sourcePath: "/Volumes/CARD/IMG.JPG",
                destinationPath: destination.path,
                fingerprint: .compute(size: 17, modificationDateString: "2026-11-15T00:00:00Z")
            )
            try db.execute(
                sql: "INSERT INTO import_copy_attempts (file_id, attempt_json) VALUES (1, ?)",
                arguments: [JSONEncoder().encode(attempt)]
            )
        }
        try SchemaMigrator.migrate(pool)
        let repository = JobRepository(pool: pool)
        #expect(try repository.hasUnresolvedCopies(jobID: "draft-job"))
        #expect(try repository.isUnverifiedDestination(destination))
        #expect(try repository.copyAttempts(jobID: "draft-job").count == 1)
        let existingBytes = Data("existing destination".utf8)
        try existingBytes.write(to: destination)
        #expect(try RecoveryService(jobRepository: repository).recoverInterruptedImports().recoveredJobs == 1)
        #expect(try !repository.hasUnresolvedCopies(jobID: "draft-job"))
        #expect(try repository.needsDestinationReview(jobID: "draft-job"))
        #expect(try repository.isUnverifiedDestination(destination))
        #expect(try Data(contentsOf: destination) == existingBytes)
    }

}
