import Foundation
import GRDB

public struct LegacyImportSummary: Equatable, Sendable {
    public let didImport: Bool
    public let itemsImported: Int
    public let jobsImported: Int
    public let jobFilesImported: Int
    public let nativeFingerprintsImported: Int
    public let configurationImported: Bool

    public init(
        didImport: Bool,
        itemsImported: Int = 0,
        jobsImported: Int = 0,
        jobFilesImported: Int = 0,
        nativeFingerprintsImported: Int = 0,
        configurationImported: Bool = false
    ) {
        self.didImport = didImport
        self.itemsImported = itemsImported
        self.jobsImported = jobsImported
        self.jobFilesImported = jobFilesImported
        self.nativeFingerprintsImported = nativeFingerprintsImported
        self.configurationImported = configurationImported
    }
}

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
    private static let completionSettingsKey = "legacy.import.completed"

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

    @discardableResult
    public func importLegacyState(
        into nativePool: DatabasePool,
        defaultPhotosRoot: String,
        defaultVideosRoot: String
    ) throws -> LegacyImportSummary {
        guard canImportLegacyState() else {
            return LegacyImportSummary(didImport: false)
        }

        if try hasCompletedImport(in: nativePool) {
            return LegacyImportSummary(didImport: false)
        }

        let legacyDatabaseRows = try readLegacyDatabaseRows()
        let legacyConfiguration = try readLegacyConfiguration()
        var summary = LegacyImportSummary(
            didImport: true,
            itemsImported: legacyDatabaseRows.items.count,
            jobsImported: legacyDatabaseRows.jobs.count,
            jobFilesImported: legacyDatabaseRows.jobFiles.count,
            nativeFingerprintsImported: legacyDatabaseRows.nativeFingerprints.count,
            configurationImported: legacyConfiguration != nil
        )

        try nativePool.write { db in
            for item in legacyDatabaseRows.items {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO items (
                        hash, size, first_seen_at, first_job_id, first_source_path
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        item.hash,
                        item.size,
                        item.firstSeenAt,
                        item.firstJobID,
                        item.firstSourcePath
                    ]
                )
            }

            for job in legacyDatabaseRows.jobs {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO jobs (
                        job_id, created_at, mount_path, volume_name, volume_uuid, location,
                        photos_root, videos_root, status, scanned_files, new_files,
                        known_files, unsupported_files, conflict_files, imported_files,
                        skipped_files, failed_files, summary_json_path, summary_markdown_path,
                        app_version
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        job.id,
                        job.createdAt,
                        job.mountPath,
                        job.volumeName,
                        job.volumeUUID,
                        job.location,
                        defaultPhotosRoot,
                        defaultVideosRoot,
                        job.status,
                        job.scannedFiles,
                        job.newFiles,
                        job.knownFiles,
                        job.unsupportedFiles,
                        job.conflictFiles,
                        job.importedFiles,
                        job.skippedFiles,
                        job.failedFiles,
                        job.summaryJSONPath,
                        job.summaryMarkdownPath,
                        "legacy-python"
                    ]
                )
            }

            for file in legacyDatabaseRows.jobFiles {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO job_files (
                        job_id, src_path, rel_path, filename, ext, size, mtime,
                        media_type, hash, capture_date, decision, dest_dir, dest_path,
                        final_dest_path, copy_status, error, completed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        file.jobID,
                        file.sourcePath,
                        file.relativePath,
                        file.filename,
                        file.ext,
                        file.size,
                        file.modificationDateString,
                        file.mediaType,
                        file.hash,
                        nil,
                        file.decision,
                        file.destinationDirectory,
                        file.destinationPath,
                        file.finalDestinationPath,
                        file.copyStatus,
                        file.error,
                        nil
                    ]
                )
            }

            for item in legacyDatabaseRows.nativeFingerprints {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO items (
                        hash, size, first_seen_at, first_job_id, first_source_path
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        item.hash,
                        item.size,
                        item.firstSeenAt,
                        item.firstJobID,
                        item.firstSourcePath
                    ]
                )
            }

            if let legacyConfiguration,
               try String.fetchOne(
                   db,
                   sql: "SELECT value_json FROM settings WHERE key = ?",
                   arguments: [AppConfiguration.storageKey]
               ) == nil {
                try insertConfiguration(legacyConfiguration, in: db)
            } else {
                summary = LegacyImportSummary(
                    didImport: summary.didImport,
                    itemsImported: summary.itemsImported,
                    jobsImported: summary.jobsImported,
                    jobFilesImported: summary.jobFilesImported,
                    nativeFingerprintsImported: summary.nativeFingerprintsImported,
                    configurationImported: false
                )
            }

            try db.execute(
                sql: """
                INSERT OR REPLACE INTO settings (key, value_json, updated_at)
                VALUES (?, ?, ?)
                """,
                arguments: [
                    Self.completionSettingsKey,
                    "true",
                    DateCoding.string(from: Date())
                ]
            )
        }

        return summary
    }

    private func hasCompletedImport(in nativePool: DatabasePool) throws -> Bool {
        try nativePool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value_json FROM settings WHERE key = ?",
                arguments: [Self.completionSettingsKey]
            ) == "true"
        }
    }

    private func readLegacyDatabaseRows() throws -> LegacyDatabaseRows {
        guard fileManager.fileExists(atPath: legacyLocation.databaseURL.path) else {
            return LegacyDatabaseRows()
        }

        var configuration = Configuration()
        configuration.readonly = true
        let legacyQueue = try DatabaseQueue(path: legacyLocation.databaseURL.path, configuration: configuration)

        return try legacyQueue.read { db in
            let items = try tableExists("items", in: db) ? readLegacyItems(in: db) : []
            let jobs = try tableExists("jobs", in: db) ? readLegacyJobs(in: db) : []
            let jobFiles = try tableExists("job_files", in: db) ? readLegacyJobFiles(in: db) : []
            let nativeFingerprints = jobFiles.compactMap(nativeItemFromCopiedLegacyFile)
            return LegacyDatabaseRows(
                items: items,
                jobs: jobs,
                jobFiles: jobFiles,
                nativeFingerprints: nativeFingerprints
            )
        }
    }

    private func readLegacyConfiguration() throws -> AppConfiguration? {
        guard fileManager.fileExists(atPath: legacyLocation.configURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: legacyLocation.configURL)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let defaultConfiguration = AppConfiguration.defaultConfiguration(homeDirectory: fileManager.homeDirectoryForCurrentUser)
        return AppConfiguration(
            sourcePath: defaultConfiguration.sourcePath,
            photosPath: defaultConfiguration.photosPath,
            videosPath: defaultConfiguration.videosPath,
            defaultLocation: (object["default_location"] as? String).nilIfEmpty ?? defaultConfiguration.defaultLocation,
            historyRetention: defaultConfiguration.historyRetention,
            autoPromptEnabled: false,
            hasCompletedOnboarding: false
        )
    }

    private func insertConfiguration(_ configuration: AppConfiguration, in db: Database) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(configuration)
        guard let valueJSON = String(data: data, encoding: .utf8) else {
            throw SDImportError.invalidDatabaseValue(column: "settings.value_json", value: "<non-utf8>")
        }

        try db.execute(
            sql: """
            INSERT OR REPLACE INTO settings (key, value_json, updated_at)
            VALUES (?, ?, ?)
            """,
            arguments: [
                AppConfiguration.storageKey,
                valueJSON,
                DateCoding.string(from: Date())
            ]
        )
    }

    private func tableExists(_ name: String, in db: Database) throws -> Bool {
        (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [name]
        ) ?? 0) > 0
    }

    private func readLegacyItems(in db: Database) throws -> [LegacyItem] {
        try Row.fetchAll(
            db,
            sql: "SELECT hash, size, first_seen_at, first_job_id, first_source_path FROM items"
        ).map { row in
            LegacyItem(
                hash: row["hash"],
                size: row["size"],
                firstSeenAt: row["first_seen_at"],
                firstJobID: row["first_job_id"],
                firstSourcePath: row["first_source_path"]
            )
        }
    }

    private func readLegacyJobs(in db: Database) throws -> [LegacyJob] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT job_id, created_at, mount_path, volume_name, volume_uuid, location, status,
                   scanned_files, new_files, known_files, unsupported_files, conflict_files,
                   imported_files, skipped_files, failed_files, report_path
            FROM jobs
            """
        ).map { row in
            let markdownPath: String? = row["report_path"]
            return LegacyJob(
                id: row["job_id"],
                createdAt: row["created_at"],
                mountPath: row["mount_path"],
                volumeName: row["volume_name"],
                volumeUUID: row["volume_uuid"],
                location: (row["location"] as String?).nilIfEmpty ?? "Untitled",
                status: row["status"],
                scannedFiles: row["scanned_files"],
                newFiles: row["new_files"],
                knownFiles: row["known_files"],
                unsupportedFiles: row["unsupported_files"],
                conflictFiles: row["conflict_files"],
                importedFiles: row["imported_files"],
                skippedFiles: row["skipped_files"],
                failedFiles: row["failed_files"],
                summaryMarkdownPath: markdownPath,
                summaryJSONPath: markdownPath.map { URL(fileURLWithPath: $0).deletingPathExtension().appendingPathExtension("json").path }
            )
        }
    }

    private func readLegacyJobFiles(in db: Database) throws -> [LegacyJobFile] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT job_id, src_path, rel_path, filename, ext, size, mtime, media_type, hash,
                   decision, dest_dir, dest_path, copy_status, error
            FROM job_files
            """
        ).map { row in
            let sourcePath: String = row["src_path"]
            let filename = (row["filename"] as String?).nilIfEmpty
                ?? URL(fileURLWithPath: sourcePath).lastPathComponent
            let ext = (row["ext"] as String?).nilIfEmpty
                ?? ("." + URL(fileURLWithPath: sourcePath).pathExtension).trimmingCharacters(in: CharacterSet(charactersIn: ".")).nilIfEmpty.map { ".\($0)" }
                ?? ""
            let copyStatus = normalizedCopyStatus(row["copy_status"] as String?)
            let destinationPath: String? = row["dest_path"]
            return LegacyJobFile(
                jobID: row["job_id"],
                sourcePath: sourcePath,
                relativePath: row["rel_path"],
                filename: filename,
                ext: ext,
                size: row["size"] ?? Int64(0),
                modificationDateString: (row["mtime"] as String?)?.nilIfEmpty ?? "1970-01-01T00:00:00",
                mediaType: normalizedMediaType(row["media_type"] as String?),
                hash: row["hash"],
                decision: normalizedDecision(row["decision"] as String?),
                destinationDirectory: row["dest_dir"],
                destinationPath: destinationPath,
                finalDestinationPath: copyStatus == CopyStatus.copied.databaseValue ? destinationPath : nil,
                copyStatus: copyStatus,
                error: row["error"]
            )
        }
    }

    private func nativeItemFromCopiedLegacyFile(_ file: LegacyJobFile) -> LegacyItem? {
        guard file.copyStatus == CopyStatus.copied.databaseValue else {
            return nil
        }

        let fingerprint = FileFingerprint.compute(
            size: file.size,
            modificationDateString: file.modificationDateString,
            identityHint: file.relativePath ?? file.filename
        )
        return LegacyItem(
            hash: fingerprint.value,
            size: fingerprint.size,
            firstSeenAt: DateCoding.string(from: Date()),
            firstJobID: file.jobID,
            firstSourcePath: file.sourcePath
        )
    }

    private func normalizedMediaType(_ value: String?) -> String {
        switch value?.lowercased() {
        case MediaKind.photo.rawValue:
            return MediaKind.photo.rawValue
        case MediaKind.video.rawValue:
            return MediaKind.video.rawValue
        default:
            return MediaKind.unsupported.rawValue
        }
    }

    private func normalizedDecision(_ value: String?) -> String {
        switch value?.uppercased() {
        case FileDecision.new.databaseValue:
            return FileDecision.new.databaseValue
        case FileDecision.known.databaseValue:
            return FileDecision.known.databaseValue
        case FileDecision.conflict.databaseValue:
            return FileDecision.conflict.databaseValue
        default:
            return FileDecision.unsupported.databaseValue
        }
    }

    private func normalizedCopyStatus(_ value: String?) -> String {
        switch value?.uppercased() {
        case CopyStatus.pending.databaseValue:
            return CopyStatus.pending.databaseValue
        case CopyStatus.copied.databaseValue:
            return CopyStatus.copied.databaseValue
        case CopyStatus.failed.databaseValue:
            return CopyStatus.failed.databaseValue
        default:
            return CopyStatus.skipped.databaseValue
        }
    }
}

private struct LegacyDatabaseRows {
    var items: [LegacyItem] = []
    var jobs: [LegacyJob] = []
    var jobFiles: [LegacyJobFile] = []
    var nativeFingerprints: [LegacyItem] = []
}

private struct LegacyItem {
    let hash: String
    let size: Int64
    let firstSeenAt: String
    let firstJobID: String?
    let firstSourcePath: String?
}

private struct LegacyJob {
    let id: String
    let createdAt: String
    let mountPath: String
    let volumeName: String?
    let volumeUUID: String?
    let location: String
    let status: String
    let scannedFiles: Int
    let newFiles: Int
    let knownFiles: Int
    let unsupportedFiles: Int
    let conflictFiles: Int
    let importedFiles: Int
    let skippedFiles: Int
    let failedFiles: Int
    let summaryMarkdownPath: String?
    let summaryJSONPath: String?
}

private struct LegacyJobFile {
    let jobID: String
    let sourcePath: String
    let relativePath: String?
    let filename: String
    let ext: String
    let size: Int64
    let modificationDateString: String
    let mediaType: String
    let hash: String?
    let decision: String
    let destinationDirectory: String?
    let destinationPath: String?
    let finalDestinationPath: String?
    let copyStatus: String
    let error: String?
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
