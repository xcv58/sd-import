import Foundation
import GRDB
import Testing

@testable import SDImportCore

@Suite("LegacyStateImporter")
struct LegacyStateImporterTests {
    @Test("detects legacy state without modifying it")
    func detectsLegacyStateWithoutModifyingIt() throws {
        let homeURL = try temporaryDirectory()
        let legacyDirectory = homeURL.appendingPathComponent(".sd-import", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )

        let legacyDatabase = legacyDirectory.appendingPathComponent("state.db")
        try Data("legacy".utf8).write(to: legacyDatabase)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: legacyDatabase.path)

        let location = LegacyStateImporter.defaultLegacyLocation(homeDirectory: homeURL)
        let importer = LegacyStateImporter(
            legacyLocation: location,
            nativeStateDirectory: homeURL.appendingPathComponent("Library/Application Support/SD Import", isDirectory: true)
        )

        #expect(importer.canImportLegacyState())
        #expect(location.databaseURL == legacyDatabase)

        let afterAttributes = try FileManager.default.attributesOfItem(atPath: legacyDatabase.path)
        #expect(originalAttributes[.size] as? Int == afterAttributes[.size] as? Int)
        #expect(try Data(contentsOf: legacyDatabase) == Data("legacy".utf8))
    }

    @Test("imports legacy history and native dedupe fingerprints without modifying legacy files")
    func importsLegacyHistoryAndDedupe() throws {
        let homeURL = try temporaryDirectory()
        let nativePool = try migratedPool()
        let legacyDirectory = homeURL.appendingPathComponent(".sd-import", isDirectory: true)
        let legacyDatabase = legacyDirectory.appendingPathComponent("state.db")
        let legacyConfig = legacyDirectory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)

        let size: Int64 = 42
        let mtime = "2024-07-15T10:00:00"
        let relativePath = "DCIM/100MSDCF/IMG_0001.JPG"
        let sourcePath = legacyDirectory.appendingPathComponent(relativePath).path
        let legacyFingerprint = FileFingerprint.compute(size: size, modificationDateString: mtime)
        let nativeFingerprint = FileFingerprint.compute(
            size: size,
            modificationDateString: mtime,
            identityHint: relativePath
        )

        do {
            let queue = try DatabaseQueue(path: legacyDatabase.path)
            try queue.write { db in
                try db.execute(sql: legacySchemaSQL)
                try db.execute(
                    sql: """
                    INSERT INTO items (hash, size, first_seen_at, first_job_id, first_source_path)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [legacyFingerprint.value, size, "2024-07-15T10:00:00", "legacy-job", sourcePath]
                )
                try db.execute(
                    sql: """
                    INSERT INTO jobs (
                        job_id, created_at, mount_path, volume_name, volume_uuid, location, status,
                        scanned_files, new_files, known_files, unsupported_files, conflict_files,
                        imported_files, skipped_files, failed_files, report_path
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        "legacy-job",
                        "2024-07-15T10:00:00",
                        "/Volumes/CARD",
                        "CARD",
                        "uuid",
                        "LEGACY",
                        "IMPORTED",
                        1,
                        1,
                        0,
                        0,
                        0,
                        1,
                        0,
                        0,
                        legacyDirectory.appendingPathComponent("reports/legacy-job.md").path
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO job_files (
                        job_id, src_path, rel_path, filename, ext, size, mtime, media_type, hash,
                        decision, dest_dir, dest_path, copy_status, error
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        "legacy-job",
                        sourcePath,
                        relativePath,
                        "IMG_0001.JPG",
                        ".jpg",
                        size,
                        mtime,
                        "photo",
                        legacyFingerprint.value,
                        "NEW",
                        "/photos/2024-07-15 LEGACY",
                        "/photos/2024-07-15 LEGACY/IMG_0001.JPG",
                        "COPIED",
                        nil
                    ]
                )
            }
        }

        try Data(#"{"default_location":"LEGACY"}"#.utf8).write(to: legacyConfig)
        let originalDatabaseBytes = try Data(contentsOf: legacyDatabase)

        let location = LegacyStateImporter.defaultLegacyLocation(homeDirectory: homeURL)
        let importer = LegacyStateImporter(
            legacyLocation: location,
            nativeStateDirectory: homeURL.appendingPathComponent("Library/Application Support/SD Import", isDirectory: true)
        )
        let summary = try importer.importLegacyState(
            into: nativePool,
            defaultPhotosRoot: "/photos",
            defaultVideosRoot: "/videos"
        )
        let secondSummary = try importer.importLegacyState(
            into: nativePool,
            defaultPhotosRoot: "/photos",
            defaultVideosRoot: "/videos"
        )

        let jobRepository = JobRepository(pool: nativePool)
        let dedupeRepository = DedupeRepository(pool: nativePool)
        let settingsRepository = SettingsRepository(pool: nativePool)
        let maybeImportedJob = try jobRepository.fetchJob(id: "legacy-job")
        let importedJob = try #require(maybeImportedJob)
        let importedFiles = try jobRepository.fetchJobFiles(jobID: "legacy-job")
        let importedFile = try #require(importedFiles.first)

        #expect(summary.didImport)
        #expect(summary.itemsImported == 1)
        #expect(summary.jobsImported == 1)
        #expect(summary.jobFilesImported == 1)
        #expect(summary.nativeFingerprintsImported == 1)
        #expect(summary.configurationImported)
        #expect(secondSummary.didImport == false)
        #expect(importedJob.appVersion == "legacy-python")
        #expect(importedFile.finalDestinationPath == "/photos/2024-07-15 LEGACY/IMG_0001.JPG")
        #expect(try dedupeRepository.contains(legacyFingerprint))
        #expect(try dedupeRepository.contains(nativeFingerprint))
        #expect(try settingsRepository.fetchConfiguration()?.defaultLocation == "LEGACY")
        #expect(try Data(contentsOf: legacyDatabase) == originalDatabaseBytes)
    }
}

private let legacySchemaSQL = """
CREATE TABLE items (
    hash TEXT NOT NULL,
    size INTEGER NOT NULL,
    first_seen_at TEXT NOT NULL,
    first_job_id TEXT,
    first_source_path TEXT,
    PRIMARY KEY (hash, size)
);

CREATE TABLE jobs (
    job_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    mount_path TEXT NOT NULL,
    volume_name TEXT,
    volume_uuid TEXT,
    location TEXT,
    status TEXT NOT NULL,
    scanned_files INTEGER NOT NULL DEFAULT 0,
    new_files INTEGER NOT NULL DEFAULT 0,
    known_files INTEGER NOT NULL DEFAULT 0,
    unsupported_files INTEGER NOT NULL DEFAULT 0,
    conflict_files INTEGER NOT NULL DEFAULT 0,
    imported_files INTEGER NOT NULL DEFAULT 0,
    skipped_files INTEGER NOT NULL DEFAULT 0,
    failed_files INTEGER NOT NULL DEFAULT 0,
    report_path TEXT
);

CREATE TABLE job_files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT NOT NULL,
    src_path TEXT NOT NULL,
    rel_path TEXT,
    filename TEXT,
    ext TEXT,
    size INTEGER,
    mtime TEXT,
    media_type TEXT,
    hash TEXT,
    decision TEXT,
    dest_dir TEXT,
    dest_path TEXT,
    copy_status TEXT,
    error TEXT,
    UNIQUE(job_id, src_path),
    FOREIGN KEY(job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
);
"""
