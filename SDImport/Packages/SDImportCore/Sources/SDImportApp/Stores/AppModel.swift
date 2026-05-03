import AppKit
import Foundation
import SDImportCore

typealias ImportPreviewSession = ImportPlanSession

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
    @Published var location: String {
        didSet {
            syncPreviewSessionLabels(from: oldValue, to: location)
        }
    }
    @Published var historyRetention: RetentionPolicy
    @Published var autoPromptEnabled: Bool
    @Published var hasCompletedOnboarding: Bool
    @Published var workflowProfile: ImportWorkflowProfile
    @Published var importMediaSelection: ImportMediaSelection
    @Published var organizationPreset: ImportOrganizationPreset
    @Published var mediaContentProfile: MediaContentProfile?
    @Published var photoPairSummary: PhotoPairSummary?
    @Published var previewSessions: [ImportPreviewSession] = []
    @Published var currentSummary: ScanSummary?
    @Published var currentResult: ImportResult?
    @Published var importProgress: ImportProgress?
    @Published var jobs: [ImportJob] = []
    @Published var selectedJobID: String?
    @Published var selectedJobFiles: [JobFileRecord] = []
    @Published var isHistoryLoading = false
    @Published var isHistoryDetailLoading = false
    @Published var availableSourceVolumes: [MountedVolume] = []
    @Published var sourceValidation: PathValidationResult = .empty(purpose: .source)
    @Published var photosValidation: PathValidationResult = .empty(purpose: .destination)
    @Published var videosValidation: PathValidationResult = .empty(purpose: .destination)
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
    private var historyRefreshTask: Task<Void, Never>?
    private var historyDetailTask: Task<Void, Never>?
    private var mountObserver: MountEventObserver?
    private var workflowProfilesByVolume: [String: ImportWorkflowProfile] = [:]
    private var workflowProfileWasManuallyChosenForCurrentJob = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.cardPath = defaults.string(forKey: DefaultsKeys.cardPath) ?? "/Volumes"
        self.photosPath = defaults.string(forKey: DefaultsKeys.photosPath) ?? "\(home)/Pictures/Photos"
        self.videosPath = defaults.string(forKey: DefaultsKeys.videosPath) ?? "\(home)/Downloads"
        self.location = defaults.string(forKey: DefaultsKeys.location) ?? "TODO"
        self.historyRetention = .defaultPolicy
        self.autoPromptEnabled = defaults.bool(forKey: DefaultsKeys.autoPromptEnabled)
        self.hasCompletedOnboarding = defaults.bool(forKey: DefaultsKeys.hasCompletedOnboarding)
        let storedWorkflowProfile = ImportWorkflowProfile(
            rawValue: defaults.string(forKey: DefaultsKeys.workflowProfile) ?? ""
        ) ?? .mixedShootSession
        self.workflowProfile = storedWorkflowProfile
        self.importMediaSelection = ImportMediaSelection(
            rawValue: defaults.string(forKey: DefaultsKeys.importMediaSelection) ?? ""
        ) ?? storedWorkflowProfile.mediaSelection
        self.organizationPreset = ImportOrganizationPreset(
            rawValue: defaults.string(forKey: DefaultsKeys.organizationPreset) ?? ""
        ) ?? storedWorkflowProfile.organizationPreset
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
            refreshAvailableSourceVolumes()
            validatePaths()
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
        defaults.set(workflowProfile.rawValue, forKey: DefaultsKeys.workflowProfile)
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
            sourcePathDidChange()
            savePreferences()
        }
    }

    func choosePhotosFolder() {
        if let path = FilePanelPresenter.chooseDirectory(title: "Choose Photo Destination", initialPath: photosPath) {
            photosPath = path
            validatePaths()
            savePreferences()
        }
    }

    func chooseVideosFolder() {
        if let path = FilePanelPresenter.chooseDirectory(title: "Choose Video Destination", initialPath: videosPath) {
            videosPath = path
            validatePaths()
            savePreferences()
        }
    }

    func refreshAvailableSourceVolumes() {
        availableSourceVolumes = VolumeDetector().mountedVolumes()
    }

    func selectSourceVolume(_ volume: MountedVolume) {
        cardPath = volume.mountURL.path
        sourcePathDidChange()
        savePreferences()
    }

    var selectedSourceVolume: MountedVolume? {
        let expandedPath = expanded(cardPath)
        return availableSourceVolumes.first { $0.mountURL.path == expandedPath }
    }

    func sourcePathDidChange() {
        currentSummary = nil
        currentResult = nil
        importProgress = nil
        previewSessions = []
        selectedJobFiles = []
        mediaContentProfile = nil
        photoPairSummary = nil
        workflowProfileWasManuallyChosenForCurrentJob = false
        validatePaths()
    }

    func validatePaths() {
        let validator = PathValidator()
        sourceValidation = validator.validate(path: cardPath, purpose: .source)
        photosValidation = validator.validate(path: photosPath, purpose: .destination)
        videosValidation = validator.validate(path: videosPath, purpose: .destination)
    }

    var canScan: Bool {
        !isWorking && sourceValidation.isUsable && requiredDestinationPathsAreUsable()
    }

    var canImportPlannedFiles: Bool {
        !isWorking
            && currentSummary != nil
            && previewTotals().copyFiles > 0
            && sourceValidation.isUsable
            && requiredDestinationPathsAreUsable()
    }

    func scan() {
        guard !isWorking else {
            statusMessage = "Finish the current scan or import first"
            return
        }
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }
        validatePaths()
        guard sourceValidation.isUsable else {
            statusMessage = sourceValidation.message
            return
        }
        guard requiredDestinationPathsAreUsable() else {
            statusMessage = "Check destination folders"
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
                    self.applyRecommendationAfterScan(files: files, summary: summary)
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

        if let matchedProfile = ImportWorkflowProfile.matching(
            mediaSelection: importMediaSelection,
            organizationPreset: organizationPreset
        ) {
            workflowProfile = matchedProfile
        }

        for index in previewSessions.indices {
            previewSessions[index].includePhotos = importMediaSelection.includes(.photo)
            previewSessions[index].includeVideos = importMediaSelection.includes(.video)
            previewSessions[index].includeSidecars = workflowProfile.includesSidecarsByDefault
        }
        workflowProfileWasManuallyChosenForCurrentJob = true
        savePreferences()
    }

    func organizationPresetDidChange() {
        if organizationPreset == .footageBackup {
            importMediaSelection = .videosOnly
            applyMediaSelectionToPreviewSessions()
        } else if let matchedProfile = ImportWorkflowProfile.matching(
            mediaSelection: importMediaSelection,
            organizationPreset: organizationPreset
        ) {
            workflowProfile = matchedProfile
        }
        validatePaths()
        savePreferences()
    }

    func applyWorkflowProfile(_ profile: ImportWorkflowProfile, userInitiated: Bool = true) {
        workflowProfile = profile
        importMediaSelection = profile.mediaSelection
        organizationPreset = profile.organizationPreset
        for index in previewSessions.indices {
            previewSessions[index].includePhotos = profile.mediaSelection.includes(.photo)
            previewSessions[index].includeVideos = profile.mediaSelection.includes(.video)
            previewSessions[index].includeSidecars = profile.includesSidecarsByDefault
        }
        if userInitiated {
            workflowProfileWasManuallyChosenForCurrentJob = true
        }
        validatePaths()
        savePreferences()
    }

    func previewRows() -> [ImportPreviewRow] {
        guard let currentSummary else {
            return []
        }

        let builder = ImportPlanBuilder(
            sessions: previewSessions,
            organizationPreset: organizationPreset,
            roots: DestinationRoots(
                photosURL: URL(fileURLWithPath: expanded(photosPath), isDirectory: true),
                videosURL: URL(fileURLWithPath: expanded(videosPath), isDirectory: true)
            ),
            fallbackLocation: location,
            volumeName: currentSummary.volumeName
        )

        return selectedJobFiles.compactMap { file in
            guard let id = file.id else {
                return nil
            }
            let plan = builder.plan(file: file)
            return ImportPreviewRow(
                id: id,
                filename: file.filename,
                date: ImportPlanBuilder.sessionDate(for: file),
                mediaKind: file.mediaKind,
                sourcePath: file.relativePath ?? file.sourcePath,
                destinationPath: plan.destinationPath,
                status: plan.status,
                willCopy: plan.willCopy,
                size: file.size
            )
        }
    }

    private func syncPreviewSessionLabels(from previousLocation: String, to nextLocation: String) {
        guard !previewSessions.isEmpty else {
            return
        }

        let previousLabel = Self.defaultSessionLabel(for: previousLocation)
        let nextLabel = Self.defaultSessionLabel(for: nextLocation)
        guard previousLabel != nextLabel else {
            return
        }

        var sessions = previewSessions
        var didUpdate = false
        for index in sessions.indices where Self.defaultSessionLabel(for: sessions[index].label) == previousLabel {
            sessions[index].label = nextLabel
            didUpdate = true
        }

        if didUpdate {
            previewSessions = sessions
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
        guard !isWorking else {
            statusMessage = "Finish the current scan or import first"
            return
        }
        guard let currentSummary else {
            statusMessage = "No scanned job selected"
            return
        }
        let jobID = currentSummary.jobID
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }
        validatePaths()
        guard sourceValidation.isUsable else {
            statusMessage = sourceValidation.message
            return
        }
        guard requiredDestinationPathsAreUsable() else {
            statusMessage = "Check destination folders"
            return
        }

        let sessions = previewSessions
        let organizationPreset = organizationPreset
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: expanded(photosPath), isDirectory: true),
            videosURL: URL(fileURLWithPath: expanded(videosPath), isDirectory: true)
        )
        let fallbackLocation = location
        let volumeName = currentSummary.volumeName

        rememberWorkflowPreferenceForCurrentVolume()
        savePreferences()

        startImport(
            jobID: jobID,
            databaseURL: databaseURL,
            planMode: .rebuild(
                ImportPlanBuilder(
                    sessions: sessions,
                    organizationPreset: organizationPreset,
                    roots: roots,
                    fallbackLocation: fallbackLocation,
                    volumeName: volumeName
                )
            )
        )
    }

    private func startImport(
        jobID: String,
        databaseURL: URL,
        planMode: ImportPlanMode
    ) {
        isWorking = true
        currentResult = nil
        importProgress = nil
        statusMessage = "Preparing import..."

        importTask = Task.detached(priority: .userInitiated) {
            do {
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                let filesForPlan = try repositories.jobRepository.fetchJobFiles(jobID: jobID)
                let updates = planMode.updates(files: filesForPlan)
                if !updates.isEmpty {
                    try repositories.jobRepository.updateJobFileImportPlan(jobID: jobID, updates: updates)
                }

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
                    self.statusMessage = "Import failed: \(Self.errorMessage(for: error))"
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
        guard !isWorking else {
            pendingMountedVolume = nil
            statusMessage = "Finish the current import before scanning another card"
            return
        }
        guard let volume = pendingMountedVolume else {
            return
        }
        pendingMountedVolume = nil
        selection = .import
        cardPath = volume.mountURL.path
        sourcePathDidChange()
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
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }

        historyRefreshTask?.cancel()
        historyDetailTask?.cancel()
        let selectedJobID = selectedJobID
        isHistoryLoading = true
        isHistoryDetailLoading = false

        historyRefreshTask = Task.detached(priority: .userInitiated) {
            do {
                let snapshot = try Self.historySnapshot(
                    databaseURL: databaseURL,
                    selectedJobID: selectedJobID
                )
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self.jobs = snapshot.jobs
                    self.selectedJobID = snapshot.selectedJobID
                    self.selectedJobFiles = snapshot.files
                    self.isHistoryLoading = false
                    self.isHistoryDetailLoading = false
                    self.historyRefreshTask = nil
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self.isHistoryLoading = false
                    self.isHistoryDetailLoading = false
                    self.historyRefreshTask = nil
                    self.statusMessage = "Could not load history: \(error)"
                }
            }
        }
    }

    func loadJobDetail(jobID: String) {
        guard selectedJobID != jobID || selectedJobFiles.isEmpty else {
            return
        }
        selectedJobID = jobID
        selectedJobFiles = []
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }

        historyDetailTask?.cancel()
        isHistoryDetailLoading = true

        historyDetailTask = Task.detached(priority: .userInitiated) {
            do {
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                let files = try repositories.jobRepository.fetchJobFiles(jobID: jobID)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard self.selectedJobID == jobID else {
                        return
                    }
                    self.selectedJobFiles = files
                    self.isHistoryDetailLoading = false
                    self.historyDetailTask = nil
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard self.selectedJobID == jobID else {
                        return
                    }
                    self.selectedJobFiles = []
                    self.isHistoryDetailLoading = false
                    self.historyDetailTask = nil
                    self.statusMessage = "Could not load job: \(error)"
                }
            }
        }
    }

    func retrySelectedJob() {
        guard let selectedJobID else {
            return
        }
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }
        currentSummary = nil
        startImport(
            jobID: selectedJobID,
            databaseURL: databaseURL,
            planMode: .existing
        )
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

    func forgetImportedFiles(for job: ImportJob) {
        guard let dedupeRepository else {
            statusMessage = "Import history is not ready"
            return
        }

        do {
            let deleted = try dedupeRepository.forgetImportedFiles(jobID: job.id)
            refreshHistory()
            if selectedJobID == job.id {
                loadJobDetail(jobID: job.id)
            }
            statusMessage = deleted == 1
                ? "Forgot 1 imported file"
                : "Forgot \(deleted) imported files"
        } catch {
            statusMessage = "Could not forget imported files: \(error)"
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

    private func requiredDestinationPathsAreUsable() -> Bool {
        requiredDestinationValidations().allSatisfy(\.isUsable)
    }

    private func requiredDestinationValidations() -> [PathValidationResult] {
        switch organizationPreset {
        case .classicDatedFolders:
            var validations: [PathValidationResult] = []
            if importMediaSelection.includes(.photo) {
                validations.append(photosValidation)
            }
            if importMediaSelection.includes(.video) {
                validations.append(videosValidation)
            }
            return validations
        case .shootSessionsByDate:
            return [photosValidation]
        case .footageBackup:
            return [videosValidation]
        }
    }

    private func applyRecommendationAfterScan(files: [JobFileRecord], summary: ScanSummary) {
        let rememberedProfile = workflowPreference(for: summary)
        let contentProfile = ImportWorkflowRecommender().recommend(
            files: files,
            rememberedProfile: rememberedProfile,
            fallbackProfile: workflowProfile
        )
        mediaContentProfile = contentProfile
        photoPairSummary = PhotoPairDetector().summarize(files: files)

        guard !workflowProfileWasManuallyChosenForCurrentJob else {
            return
        }

        applyWorkflowProfile(contentProfile.recommendedWorkflow, userInitiated: false)
    }

    private func workflowPreference(for summary: ScanSummary) -> ImportWorkflowProfile? {
        guard let key = volumePreferenceKey(uuid: summary.volumeUUID, name: summary.volumeName) else {
            return nil
        }
        return workflowProfilesByVolume[key]
    }

    private func rememberWorkflowPreferenceForCurrentVolume() {
        guard let currentSummary else {
            return
        }
        if let key = volumePreferenceKey(uuid: currentSummary.volumeUUID, name: currentSummary.volumeName) {
            workflowProfilesByVolume[key] = workflowProfile
        }
    }

    private func volumePreferenceKey(uuid: String?, name: String?) -> String? {
        if let uuid = uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty {
            return "uuid:\(uuid)"
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "name:\(name.lowercased(with: Locale(identifier: "en_US_POSIX")))"
        }
        return nil
    }

    private func rebuildPreviewSessions(files: [JobFileRecord], defaultLabel: String) {
        let existing = Dictionary(uniqueKeysWithValues: previewSessions.map { ($0.date, $0) })
        let grouped = Dictionary(grouping: files) { ImportPlanBuilder.sessionDate(for: $0) }
        let includePhotos = organizationPreset == .footageBackup ? false : importMediaSelection.includes(.photo)
        let includeVideos = importMediaSelection.includes(.video)
        let includeSidecars = workflowProfile.includesSidecarsByDefault
        let normalizedDefaultLabel = Self.defaultSessionLabel(for: defaultLabel)

        previewSessions = grouped.keys.sorted().map { date in
            let files = grouped[date] ?? []
            let prior = existing[date]
            return ImportPreviewSession(
                date: date,
                label: prior?.label ?? normalizedDefaultLabel,
                photoCount: files.filter { $0.mediaKind == .photo }.count,
                videoCount: files.filter { $0.mediaKind == .video }.count,
                unsupportedCount: files.filter { $0.mediaKind == .unsupported }.count,
                includePhotos: prior?.includePhotos ?? includePhotos,
                includeVideos: prior?.includeVideos ?? includeVideos,
                includeSidecars: prior?.includeSidecars ?? includeSidecars
            )
        }
    }

    private static func defaultSessionLabel(for location: String) -> String {
        location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "TODO"
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

    nonisolated private static func historySnapshot(
        databaseURL: URL,
        selectedJobID: String?
    ) throws -> (jobs: [ImportJob], selectedJobID: String?, files: [JobFileRecord]) {
        let repositories = try makeRepositories(databaseURL: databaseURL)
        let jobs = try repositories.jobRepository.listJobs(limit: 100)
        let selectedJobID = selectedJobID.flatMap { id in
            jobs.contains { $0.id == id } ? id : nil
        } ?? jobs.first?.id
        let files = try selectedJobID.map { try repositories.jobRepository.fetchJobFiles(jobID: $0) } ?? []
        return (jobs, selectedJobID, files)
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
        workflowProfile = configuration.lastWorkflowProfile
        workflowProfilesByVolume = configuration.workflowProfilesByVolume
        importMediaSelection = workflowProfile.mediaSelection
        organizationPreset = workflowProfile.organizationPreset

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
            hasCompletedOnboarding: hasCompletedOnboarding,
            lastWorkflowProfile: workflowProfile,
            workflowProfilesByVolume: workflowProfilesByVolume
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
                !self.isWorking,
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

    nonisolated private static func errorMessage(for error: Error) -> String {
        if case let SDImportError.insufficientDestinationSpace(path, requiredBytes, availableBytes) = error {
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Not enough space in \(path). Need \(required), available \(available)."
        }

        return String(describing: error)
    }
}

private enum ImportPlanMode: Sendable {
    case rebuild(ImportPlanBuilder)
    case existing

    func updates(files: [JobFileRecord]) -> [JobFilePlanUpdate] {
        switch self {
        case .rebuild(let builder):
            return builder.updates(files: files)
        case .existing:
            return []
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
    static let workflowProfile = "SDImport.workflowProfile"
    static let importMediaSelection = "SDImport.importMediaSelection"
    static let organizationPreset = "SDImport.organizationPreset"
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
