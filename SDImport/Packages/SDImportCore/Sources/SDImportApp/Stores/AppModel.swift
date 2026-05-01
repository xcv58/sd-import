import AppKit
import Foundation
import SDImportCore

struct ImportPreviewSession: Identifiable, Hashable, Sendable {
    var id: String { date }
    let date: String
    var label: String
    let photoCount: Int
    let videoCount: Int
    let unsupportedCount: Int
    var includePhotos: Bool
    var includeVideos: Bool
    var includeSidecars: Bool
}

struct ImportPreviewRow: Identifiable, Hashable {
    let id: Int64
    let filename: String
    let date: String
    let mediaKind: MediaKind
    let sourcePath: String
    let destinationPath: String?
    let status: String
    let willCopy: Bool
    let size: Int64
}

struct ImportPreviewTotals: Hashable {
    let copyFiles: Int
    let skippedFiles: Int
    let copyBytes: Int64
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem = .import
    @Published var cardPath: String
    @Published var photosPath: String
    @Published var videosPath: String
    @Published var location: String
    @Published var historyRetention: RetentionPolicy
    @Published var autoPromptEnabled: Bool
    @Published var hasCompletedOnboarding: Bool
    @Published var importMediaSelection: ImportMediaSelection
    @Published var organizationPreset: ImportOrganizationPreset
    @Published var previewSessions: [ImportPreviewSession] = []
    @Published var currentSummary: ScanSummary?
    @Published var currentResult: ImportResult?
    @Published var importProgress: ImportProgress?
    @Published var jobs: [ImportJob] = []
    @Published var selectedJobID: String?
    @Published var selectedJobFiles: [JobFileRecord] = []
    @Published var pendingMountedVolume: MountedVolume?
    @Published var statusMessage = ""
    @Published var isWorking = false
    @Published var setupError: String?

    private let defaults = UserDefaults.standard
    private var applicationSupportURL: URL?
    private var reportsURL: URL?
    private var databaseURL: URL?
    private var jobRepository: JobRepository?
    private var dedupeRepository: DedupeRepository?
    private var settingsRepository: SettingsRepository?
    private var bookmarkStore: BookmarkStore?
    private var importTask: Task<Void, Never>?
    private var mountObserver: MountEventObserver?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.cardPath = defaults.string(forKey: DefaultsKeys.cardPath) ?? "/Volumes"
        self.photosPath = defaults.string(forKey: DefaultsKeys.photosPath) ?? "\(home)/Pictures/Photos"
        self.videosPath = defaults.string(forKey: DefaultsKeys.videosPath) ?? "\(home)/Downloads"
        self.location = defaults.string(forKey: DefaultsKeys.location) ?? "TODO"
        self.historyRetention = .defaultPolicy
        self.autoPromptEnabled = defaults.bool(forKey: DefaultsKeys.autoPromptEnabled)
        self.hasCompletedOnboarding = defaults.bool(forKey: DefaultsKeys.hasCompletedOnboarding)
        self.importMediaSelection = ImportMediaSelection(
            rawValue: defaults.string(forKey: DefaultsKeys.importMediaSelection) ?? ""
        ) ?? .photosAndVideos
        self.organizationPreset = ImportOrganizationPreset(
            rawValue: defaults.string(forKey: DefaultsKeys.organizationPreset) ?? ""
        ) ?? .shootSessionsByDate
        bootstrap()
    }

    func bootstrap() {
        do {
            let stateURL = try DatabasePoolFactory.defaultApplicationSupportDirectory()
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
            let databaseURL = stateURL.appendingPathComponent("state.sqlite", isDirectory: false)
            let pool = try DatabasePoolFactory(databaseURL: databaseURL).makeMigratedPool()
            applicationSupportURL = stateURL
            reportsURL = stateURL.appendingPathComponent("Reports", isDirectory: true)
            self.databaseURL = databaseURL
            jobRepository = JobRepository(pool: pool)
            dedupeRepository = DedupeRepository(pool: pool)
            settingsRepository = SettingsRepository(pool: pool)
            bookmarkStore = BookmarkStore(pool: pool)
            let legacyImportMessage: String?
            do {
                let summary = try LegacyStateImporter(
                    legacyLocation: LegacyStateImporter.defaultLegacyLocation(),
                    nativeStateDirectory: stateURL
                ).importLegacyState(
                    into: pool,
                    defaultPhotosRoot: expanded(photosPath),
                    defaultVideosRoot: expanded(videosPath)
                )

                if summary.didImport {
                    let importedRecords = summary.jobsImported
                        + summary.jobFilesImported
                        + summary.nativeFingerprintsImported
                    legacyImportMessage = importedRecords > 0
                        ? "Imported legacy SD Import history"
                        : "Imported legacy SD Import settings"
                } else {
                    legacyImportMessage = nil
                }
            } catch {
                legacyImportMessage = "Legacy import skipped: \(error)"
            }
            try loadStoredConfiguration()
            let recovery = try RecoveryService(jobRepository: JobRepository(pool: pool))
                .recoverInterruptedImports()
            refreshHistory()
            startMountObserver()
            statusMessage = legacyImportMessage
                ?? (recovery.recoveredJobs > 0 ? "Recovered interrupted import" : "Ready")
        } catch {
            setupError = String(describing: error)
            statusMessage = "Setup failed"
        }
    }

    func savePreferences() {
        defaults.set(cardPath, forKey: DefaultsKeys.cardPath)
        defaults.set(photosPath, forKey: DefaultsKeys.photosPath)
        defaults.set(videosPath, forKey: DefaultsKeys.videosPath)
        defaults.set(location, forKey: DefaultsKeys.location)
        defaults.set(autoPromptEnabled, forKey: DefaultsKeys.autoPromptEnabled)
        defaults.set(hasCompletedOnboarding, forKey: DefaultsKeys.hasCompletedOnboarding)
        defaults.set(importMediaSelection.rawValue, forKey: DefaultsKeys.importMediaSelection)
        defaults.set(organizationPreset.rawValue, forKey: DefaultsKeys.organizationPreset)

        do {
            try settingsRepository?.saveConfiguration(currentConfiguration())
            try saveFolderBookmark(.source, path: cardPath)
            try saveFolderBookmark(.photos, path: photosPath)
            try saveFolderBookmark(.videos, path: videosPath)
        } catch {
            statusMessage = "Could not save settings: \(error)"
        }
    }

    func chooseCardFolder() {
        if let path = FilePanelPresenter.chooseDirectory(title: "Choose SD Card or Source Folder", initialPath: cardPath) {
            cardPath = path
            savePreferences()
        }
    }

    func choosePhotosFolder() {
        if let path = FilePanelPresenter.chooseDirectory(title: "Choose Photo Destination", initialPath: photosPath) {
            photosPath = path
            savePreferences()
        }
    }

    func chooseVideosFolder() {
        if let path = FilePanelPresenter.chooseDirectory(title: "Choose Video Destination", initialPath: videosPath) {
            videosPath = path
            savePreferences()
        }
    }

    func scan() {
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }

        savePreferences()
        currentResult = nil
        importProgress = nil
        previewSessions = []
        isWorking = true
        statusMessage = "Scanning..."

        let cardPath = expanded(cardPath)
        let photosPath = expanded(photosPath)
        let videosPath = expanded(videosPath)
        let location = location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "TODO" : location
        let reportsURL = reportsURL

        Task.detached(priority: .userInitiated) {
            do {
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                let scanner = MediaScanner(
                    jobRepository: repositories.jobRepository,
                    dedupeRepository: repositories.dedupeRepository
                )
                let request = ScanRequest(
                    mountURL: URL(fileURLWithPath: cardPath, isDirectory: true),
                    volumeName: URL(fileURLWithPath: cardPath).lastPathComponent,
                    location: location,
                    roots: DestinationRoots(
                        photosURL: URL(fileURLWithPath: photosPath, isDirectory: true),
                        videosURL: URL(fileURLWithPath: videosPath, isDirectory: true)
                    ),
                    reportsDirectoryURL: reportsURL
                )
                let summary = try scanner.scan(request)
                let jobs = try repositories.jobRepository.listJobs(limit: 100)
                let files = try repositories.jobRepository.fetchJobFiles(jobID: summary.jobID)

                await MainActor.run {
                    self.currentSummary = summary
                    self.selectedJobID = summary.jobID
                    self.jobs = jobs
                    self.selectedJobFiles = files
                    self.rebuildPreviewSessions(files: files, defaultLabel: location)
                    self.statusMessage = "Scan complete"
                    self.isWorking = false
                }
            } catch {
                await MainActor.run {
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.statusMessage = "Scan failed: \(error)"
                    self.isWorking = false
                }
            }
        }
    }

    func applyMediaSelectionToPreviewSessions() {
        if organizationPreset == .footageBackup {
            importMediaSelection = .videosOnly
        }

        for index in previewSessions.indices {
            previewSessions[index].includePhotos = importMediaSelection.includes(.photo)
            previewSessions[index].includeVideos = importMediaSelection.includes(.video)
            previewSessions[index].includeSidecars = organizationPreset == .footageBackup
        }
        savePreferences()
    }

    func organizationPresetDidChange() {
        if organizationPreset == .footageBackup {
            importMediaSelection = .videosOnly
            applyMediaSelectionToPreviewSessions()
        }
        savePreferences()
    }

    func previewRows() -> [ImportPreviewRow] {
        guard let currentSummary else {
            return []
        }

        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: expanded(photosPath), isDirectory: true),
            videosURL: URL(fileURLWithPath: expanded(videosPath), isDirectory: true)
        )

        return selectedJobFiles.compactMap { file in
            guard let id = file.id else {
                return nil
            }
            let plan = Self.planFile(
                file,
                sessions: previewSessions,
                organizationPreset: organizationPreset,
                roots: roots,
                fallbackLocation: location,
                volumeName: currentSummary.volumeName
            )
            return ImportPreviewRow(
                id: id,
                filename: file.filename,
                date: Self.sessionDate(for: file),
                mediaKind: file.mediaKind,
                sourcePath: file.relativePath ?? file.sourcePath,
                destinationPath: plan.update?.plannedDestinationPath,
                status: plan.status,
                willCopy: plan.willCopy,
                size: file.size
            )
        }
    }

    func previewTotals() -> ImportPreviewTotals {
        let rows = previewRows()
        return ImportPreviewTotals(
            copyFiles: rows.filter(\.willCopy).count,
            skippedFiles: rows.filter { !$0.willCopy }.count,
            copyBytes: rows.reduce(Int64(0)) { total, row in
                row.willCopy ? total + row.size : total
            }
        )
    }

    func importCurrentJob() {
        guard let jobID = currentSummary?.jobID ?? selectedJobID else {
            statusMessage = "No scanned job selected"
            return
        }
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }

        let sessions = previewSessions
        let organizationPreset = organizationPreset
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: expanded(photosPath), isDirectory: true),
            videosURL: URL(fileURLWithPath: expanded(videosPath), isDirectory: true)
        )
        let fallbackLocation = location
        let volumeName = currentSummary?.volumeName

        isWorking = true
        currentResult = nil
        importProgress = nil
        statusMessage = "Preparing import..."

        importTask = Task.detached(priority: .userInitiated) {
            do {
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                let filesForPlan = try repositories.jobRepository.fetchJobFiles(jobID: jobID)
                let updates = Self.planUpdates(
                    files: filesForPlan,
                    sessions: sessions,
                    organizationPreset: organizationPreset,
                    roots: roots,
                    fallbackLocation: fallbackLocation,
                    volumeName: volumeName
                )
                try repositories.jobRepository.updateJobFileImportPlan(jobID: jobID, updates: updates)

                let engine = ImportEngine(
                    jobRepository: repositories.jobRepository,
                    dedupeRepository: repositories.dedupeRepository
                )
                var latestProgress: ImportProgress?
                var lastPublishedAt = Date(timeIntervalSince1970: 0)
                let minimumUpdateInterval: TimeInterval = 0.25

                let result = try engine.importFiles(
                    jobID: jobID,
                    onProgress: { progress in
                        latestProgress = progress

                        let now = Date()
                        let shouldPublish = progress.status != "copying"
                            || now.timeIntervalSince(lastPublishedAt) >= minimumUpdateInterval
                        guard shouldPublish else {
                            return
                        }

                        lastPublishedAt = now
                        Task { @MainActor in
                            self.importProgress = progress
                            self.statusMessage = Self.importStatusMessage(for: progress)
                        }
                    },
                    shouldCancel: {
                        Task.isCancelled
                    }
                )
                let jobs = try repositories.jobRepository.listJobs(limit: 100)
                let files = try repositories.jobRepository.fetchJobFiles(jobID: jobID)

                await MainActor.run {
                    self.currentResult = result
                    self.importProgress = latestProgress
                    self.jobs = jobs
                    self.selectedJobID = jobID
                    self.selectedJobFiles = files
                    self.statusMessage = "Import finished"
                    self.isWorking = false
                    self.importTask = nil
                }
            } catch SDImportError.cancelled {
                let snapshot = try? Self.historySnapshot(databaseURL: databaseURL, jobID: jobID)
                await MainActor.run {
                    if let snapshot {
                        self.jobs = snapshot.jobs
                        self.selectedJobID = jobID
                        self.selectedJobFiles = snapshot.files
                    }
                    self.currentResult = nil
                    self.statusMessage = "Import cancelled"
                    self.isWorking = false
                    self.importTask = nil
                }
            } catch {
                await MainActor.run {
                    self.currentResult = nil
                    self.importProgress = nil
                    self.statusMessage = "Import failed: \(error)"
                    self.isWorking = false
                    self.importTask = nil
                }
            }
        }
    }

    func cancelImport() {
        guard importTask != nil else {
            return
        }
        statusMessage = "Cancelling..."
        importTask?.cancel()
    }

    func acceptMountedVolumePrompt() {
        guard let volume = pendingMountedVolume else {
            return
        }
        pendingMountedVolume = nil
        selection = .import
        cardPath = volume.mountURL.path
        savePreferences()
        scan()
    }

    func skipMountedVolumePrompt() {
        pendingMountedVolume = nil
        statusMessage = "Ready"
    }

    func updateLoginItemRegistration() {
        do {
            try LoginItemController.setEnabled(autoPromptEnabled)
            statusMessage = autoPromptEnabled ? "Background prompt enabled" : "Background prompt disabled"
        } catch {
            statusMessage = "Could not update background prompt: \(error)"
        }
    }

    func refreshHistory() {
        guard let jobRepository else {
            return
        }

        do {
            jobs = try jobRepository.listJobs(limit: 100)
            if selectedJobID == nil {
                selectedJobID = jobs.first?.id
            }
            if let selectedJobID {
                loadJobDetail(jobID: selectedJobID)
            }
        } catch {
            statusMessage = "Could not load history: \(error)"
        }
    }

    func loadJobDetail(jobID: String) {
        selectedJobID = jobID
        guard let jobRepository else {
            return
        }

        do {
            selectedJobFiles = try jobRepository.fetchJobFiles(jobID: jobID)
        } catch {
            selectedJobFiles = []
            statusMessage = "Could not load job: \(error)"
        }
    }

    func retrySelectedJob() {
        guard selectedJobID != nil else {
            return
        }
        currentSummary = nil
        importCurrentJob()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        savePreferences()
        updateLoginItemRegistration()
        statusMessage = "Ready"
    }

    func revealPhotosFolder() {
        reveal(path: photosPath)
    }

    func revealVideosFolder() {
        reveal(path: videosPath)
    }

    func revealReport(for job: ImportJob) {
        if let path = job.summaryMarkdownPath ?? job.summaryJSONPath {
            reveal(path: path)
        }
    }

    func reveal(path: String) {
        let url = URL(fileURLWithPath: expanded(path))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copySummary(for job: ImportJob) {
        let text = summaryText(for: job)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Summary copied"
    }

    func exportSummary(for job: ImportJob) {
        guard let url = FilePanelPresenter.chooseSaveURL(
            title: "Export Summary",
            suggestedName: "\(job.id)-summary.txt"
        ) else {
            return
        }

        do {
            try summaryText(for: job).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Summary exported"
        } catch {
            statusMessage = "Could not export summary: \(error)"
        }
    }

    func pruneHistory(dryRun: Bool) {
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }

        do {
            let pool = try DatabasePoolFactory(databaseURL: databaseURL).makeMigratedPool()
            let summary = try HistoryRetentionService(pool: pool).prune(
                policy: historyRetention,
                dryRun: dryRun
            )
            refreshHistory()
            if dryRun {
                statusMessage = "\(summary.matchedJobs) old jobs would be pruned"
            } else {
                statusMessage = "Pruned \(summary.deletedJobs) jobs"
            }
        } catch {
            statusMessage = "Could not prune history: \(error)"
        }
    }

    func selectedJob() -> ImportJob? {
        guard let selectedJobID else {
            return nil
        }
        return jobs.first { $0.id == selectedJobID }
    }

    private func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func summaryText(for job: ImportJob) -> String {
        """
        Job: \(job.id)
        Status: \(job.status.databaseValue)
        Volume: \(job.volumeName ?? "")
        Scanned: \(job.scannedFiles)
        New: \(job.newFiles)
        Known: \(job.knownFiles)
        Conflicts: \(job.conflictFiles)
        Imported: \(job.importedFiles)
        Failed: \(job.failedFiles)
        """
    }

    private func rebuildPreviewSessions(files: [JobFileRecord], defaultLabel: String) {
        let existing = Dictionary(uniqueKeysWithValues: previewSessions.map { ($0.date, $0) })
        let grouped = Dictionary(grouping: files) { Self.sessionDate(for: $0) }
        let includePhotos = organizationPreset == .footageBackup ? false : importMediaSelection.includes(.photo)
        let includeVideos = importMediaSelection.includes(.video)
        let includeSidecars = organizationPreset == .footageBackup

        previewSessions = grouped.keys.sorted().map { date in
            let files = grouped[date] ?? []
            let prior = existing[date]
            return ImportPreviewSession(
                date: date,
                label: prior?.label ?? defaultLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "TODO",
                photoCount: files.filter { $0.mediaKind == .photo }.count,
                videoCount: files.filter { $0.mediaKind == .video }.count,
                unsupportedCount: files.filter { $0.mediaKind == .unsupported }.count,
                includePhotos: prior?.includePhotos ?? includePhotos,
                includeVideos: prior?.includeVideos ?? includeVideos,
                includeSidecars: prior?.includeSidecars ?? includeSidecars
            )
        }
    }

    private nonisolated static func planUpdates(
        files: [JobFileRecord],
        sessions: [ImportPreviewSession],
        organizationPreset: ImportOrganizationPreset,
        roots: DestinationRoots,
        fallbackLocation: String,
        volumeName: String?
    ) -> [JobFilePlanUpdate] {
        files.compactMap { file in
            planFile(
                file,
                sessions: sessions,
                organizationPreset: organizationPreset,
                roots: roots,
                fallbackLocation: fallbackLocation,
                volumeName: volumeName
            ).update
        }
    }

    private nonisolated static func planFile(
        _ file: JobFileRecord,
        sessions: [ImportPreviewSession],
        organizationPreset: ImportOrganizationPreset,
        roots: DestinationRoots,
        fallbackLocation: String,
        volumeName: String?
    ) -> (update: JobFilePlanUpdate?, willCopy: Bool, status: String) {
        guard let id = file.id else {
            return (nil, false, "Not ready")
        }

        let date = sessionDate(for: file)
        let session = sessions.first { $0.date == date }
        let label = session?.label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallbackLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "TODO"

        let isFootageSidecar = organizationPreset == .footageBackup
            && file.mediaKind == .unsupported
            && (session?.includeSidecars ?? true)

        if (file.mediaKind == .unsupported || file.decision == .unsupported) && !isFootageSidecar {
            return (
                JobFilePlanUpdate(
                    id: id,
                    decision: .unsupported,
                    destinationDirectory: nil,
                    plannedDestinationPath: nil,
                    copyStatus: .skipped,
                    error: "unsupported"
                ),
                false,
                "Unsupported"
            )
        }

        let included: Bool
        switch file.mediaKind {
        case .photo:
            included = session?.includePhotos ?? true
        case .video:
            included = session?.includeVideos ?? true
        case .unsupported:
            included = isFootageSidecar
        }

        guard included else {
            return (
                JobFilePlanUpdate(
                    id: id,
                    decision: file.decision,
                    destinationDirectory: nil,
                    plannedDestinationPath: nil,
                    copyStatus: .skipped,
                    error: "excluded_by_import_selection"
                ),
                false,
                "Excluded"
            )
        }

        if file.decision == .known || file.copyStatus == .copied {
            return (
                JobFilePlanUpdate(
                    id: id,
                    decision: .known,
                    destinationDirectory: file.destinationDirectory,
                    plannedDestinationPath: file.plannedDestinationPath,
                    copyStatus: .skipped,
                    error: nil
                ),
                false,
                "Known"
            )
        }

        let planner = DestinationPlanner()
        guard let destinationURL = planner.destinationURL(
            filename: file.filename,
            mediaKind: file.mediaKind,
            captureDate: date,
            sessionLabel: label,
            roots: roots,
            organizationPreset: organizationPreset,
            relativePath: file.relativePath,
            volumeName: volumeName
        ) else {
            return (
                JobFilePlanUpdate(
                    id: id,
                    decision: file.decision,
                    destinationDirectory: nil,
                    plannedDestinationPath: nil,
                    copyStatus: .skipped,
                    error: "no_destination"
                ),
                false,
                "No destination"
            )
        }

        let fingerprint = FileFingerprint.compute(
            size: file.size,
            modificationDateString: file.modificationDateString,
            identityHint: file.relativePath ?? file.filename
        )
        let resolver = ConflictResolver()
        switch resolver.resolveDestination(candidate: destinationURL, expectedFingerprint: fingerprint) {
        case .skip(let reason):
            return (
                JobFilePlanUpdate(
                    id: id,
                    decision: .known,
                    destinationDirectory: destinationURL.deletingLastPathComponent().path,
                    plannedDestinationPath: destinationURL.path,
                    copyStatus: .skipped,
                    error: reason
                ),
                false,
                "Already exists"
            )
        case .copy(let resolvedURL):
            let isConflict = resolvedURL != destinationURL
            let copyStatus = file.mediaKind == .unsupported ? "Sidecar" : "Will copy"
            return (
                JobFilePlanUpdate(
                    id: id,
                    decision: isConflict ? .conflict : .new,
                    destinationDirectory: resolvedURL.deletingLastPathComponent().path,
                    plannedDestinationPath: resolvedURL.path,
                    copyStatus: .pending,
                    error: isConflict ? "destination file exists with different content" : nil
                ),
                true,
                isConflict ? "Rename" : copyStatus
            )
        }
    }

    private nonisolated static func sessionDate(for file: JobFileRecord) -> String {
        if let captureDate = file.captureDate, !captureDate.isEmpty {
            return captureDate
        }
        return String(file.modificationDateString.prefix(10))
    }

    nonisolated private static func makeRepositories(databaseURL: URL) throws -> (
        jobRepository: JobRepository,
        dedupeRepository: DedupeRepository
    ) {
        let pool = try DatabasePoolFactory(databaseURL: databaseURL).makeMigratedPool()
        return (
            JobRepository(pool: pool),
            DedupeRepository(pool: pool)
        )
    }

    nonisolated private static func historySnapshot(
        databaseURL: URL,
        jobID: String
    ) throws -> (jobs: [ImportJob], files: [JobFileRecord]) {
        let repositories = try makeRepositories(databaseURL: databaseURL)
        return (
            try repositories.jobRepository.listJobs(limit: 100),
            try repositories.jobRepository.fetchJobFiles(jobID: jobID)
        )
    }

    private func loadStoredConfiguration() throws {
        guard let settingsRepository else {
            return
        }

        let fallback = currentConfiguration()
        let configuration = try settingsRepository.fetchConfiguration() ?? fallback
        cardPath = try resolvedPath(for: .source, fallback: configuration.sourcePath)
        photosPath = try resolvedPath(for: .photos, fallback: configuration.photosPath)
        videosPath = try resolvedPath(for: .videos, fallback: configuration.videosPath)
        location = configuration.defaultLocation
        historyRetention = configuration.historyRetention
        autoPromptEnabled = configuration.autoPromptEnabled
        hasCompletedOnboarding = configuration.hasCompletedOnboarding

        if try settingsRepository.fetchConfiguration() == nil {
            try settingsRepository.saveConfiguration(currentConfiguration())
        }
    }

    private func currentConfiguration() -> AppConfiguration {
        AppConfiguration(
            sourcePath: expanded(cardPath),
            photosPath: expanded(photosPath),
            videosPath: expanded(videosPath),
            defaultLocation: location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "TODO" : location,
            historyRetention: historyRetention,
            autoPromptEnabled: autoPromptEnabled,
            hasCompletedOnboarding: hasCompletedOnboarding
        )
    }

    private func resolvedPath(for purpose: BookmarkPurpose, fallback: String) throws -> String {
        guard let resolved = try bookmarkStore?.resolveBookmark(purpose: purpose) else {
            return fallback
        }
        return resolved.url.path
    }

    private func saveFolderBookmark(_ purpose: BookmarkPurpose, path: String) throws {
        let url = URL(fileURLWithPath: expanded(path), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        try bookmarkStore?.saveBookmark(purpose: purpose, url: url)
    }

    private func startMountObserver() {
        guard mountObserver == nil else {
            return
        }

        let observer = MountEventObserver { [weak self] volume in
            guard
                let self,
                self.autoPromptEnabled,
                self.hasCompletedOnboarding,
                self.pendingMountedVolume == nil
            else {
                return
            }

            self.pendingMountedVolume = volume
            self.statusMessage = "Card detected"
        }
        mountObserver = observer
        observer.start()
    }

    nonisolated private static func importStatusMessage(for progress: ImportProgress) -> String {
        switch progress.status {
        case "completed":
            return "Import finished"
        case "completed_with_errors":
            return "Import finished with errors"
        case "idle":
            return "Nothing to import"
        default:
            let percent = Int(progress.percent.rounded())
            if progress.throughputBytesPerSecond > 1 {
                let speed = ByteCountFormatter.string(
                    fromByteCount: Int64(progress.throughputBytesPerSecond),
                    countStyle: .file
                )
                return "Importing \(percent)% at \(speed)/s"
            }
            return "Importing \(progress.doneFiles) of \(progress.totalFiles) files"
        }
    }
}

private enum DefaultsKeys {
    static let cardPath = "SDImport.cardPath"
    static let photosPath = "SDImport.photosPath"
    static let videosPath = "SDImport.videosPath"
    static let location = "SDImport.location"
    static let autoPromptEnabled = "SDImport.autoPromptEnabled"
    static let hasCompletedOnboarding = "SDImport.hasCompletedOnboarding"
    static let importMediaSelection = "SDImport.importMediaSelection"
    static let organizationPreset = "SDImport.organizationPreset"
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
