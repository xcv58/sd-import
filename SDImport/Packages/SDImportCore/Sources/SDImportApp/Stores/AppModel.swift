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

    static let empty = ImportPreviewTotals(copyFiles: 0, skippedFiles: 0, copyBytes: 0)
}

struct ImportPreviewDestination: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let title: String
    let fileCount: Int
    let byteCount: Int64
}

struct ImportPreviewSpaceRequirement: Identifiable, Hashable {
    var id: String { volumeID }
    let volumeID: String
    let displayPath: String
    let requiredBytes: Int64
    let availableBytes: Int64
    let totalBytes: Int64?

    var isSatisfied: Bool {
        requiredBytes <= availableBytes
    }
}

enum ImportPreviewMode: Hashable {
    case recommended
    case custom
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
    @Published var folderGrouping: ImportFolderGrouping
    @Published var importPreviewMode: ImportPreviewMode = .recommended
    @Published private(set) var customImportBaseWorkflowProfile: ImportWorkflowProfile?
    @Published var themePreference: AppThemePreference
    @Published var mediaContentProfile: MediaContentProfile?
    @Published var photoPairSummary: PhotoPairSummary?
    @Published var previewSessions: [ImportPreviewSession] = [] {
        didSet {
            rebuildPreviewPlanCache()
        }
    }
    @Published private(set) var previewRows: [ImportPreviewRow] = []
    @Published private(set) var previewTotals: ImportPreviewTotals = .empty
    @Published private(set) var previewDestinations: [ImportPreviewDestination] = []
    @Published private(set) var previewSpaceRequirements: [ImportPreviewSpaceRequirement] = []
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
    private var knownImportedPreviewFileIDs: Set<Int64> = []
    private var currentPreviewFiles: [JobFileRecord] = [] {
        didSet {
            rebuildPreviewPlanCache()
        }
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.cardPath = defaults.string(forKey: DefaultsKeys.cardPath) ?? "/Volumes"
        self.photosPath = defaults.string(forKey: DefaultsKeys.photosPath) ?? "\(home)/Pictures/Photos"
        self.videosPath = defaults.string(forKey: DefaultsKeys.videosPath) ?? "\(home)/Downloads"
        self.location = defaults.string(forKey: DefaultsKeys.location) ?? "Untitled"
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
        self.folderGrouping = ImportFolderGrouping(
            rawValue: defaults.string(forKey: DefaultsKeys.folderGrouping) ?? ""
        ) ?? .byDay
        self.themePreference = AppThemePreference(
            rawValue: defaults.string(forKey: DefaultsKeys.themePreference) ?? ""
        ) ?? .system
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
        defaults.set(folderGrouping.rawValue, forKey: DefaultsKeys.folderGrouping)
        defaults.set(themePreference.rawValue, forKey: DefaultsKeys.themePreference)

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
            destinationPathDidChange()
            savePreferences()
        }
    }

    func chooseVideosFolder() {
        if let path = FilePanelPresenter.chooseDirectory(title: "Choose Video Destination", initialPath: videosPath) {
            videosPath = path
            destinationPathDidChange()
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

    func selectPanel(_ item: SidebarItem) {
        selection = item
    }

    func selectNextPanel() {
        selection = selection.panel(offsetBy: 1)
    }

    func selectPreviousPanel() {
        selection = selection.panel(offsetBy: -1)
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
        clearPreviewPlanCache()
        selectedJobFiles = []
        currentPreviewFiles = []
        knownImportedPreviewFileIDs = []
        mediaContentProfile = nil
        photoPairSummary = nil
        importPreviewMode = .recommended
        customImportBaseWorkflowProfile = nil
        workflowProfileWasManuallyChosenForCurrentJob = false
        validatePaths()
    }

    func destinationPathDidChange() {
        validatePaths()
        rebuildPreviewPlanCache()
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
        return !isWorking
            && currentSummary != nil
            && previewTotals.copyFiles > 0
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
        currentPreviewFiles = []
        clearPreviewPlanCache()
        isWorking = true
        statusMessage = "Scanning..."

        let cardPath = expanded(cardPath)
        let photosPath = expanded(photosPath)
        let videosPath = expanded(videosPath)
        let location = Self.defaultSessionLabel(for: location)
        let reportsURL = reportsURL

        importTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
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
                let summary = try scanner.scan(request) {
                    Task.isCancelled
                }
                try Task.checkCancellation()
                let jobs = try repositories.jobRepository.listImportHistoryJobs(limit: 100)
                let files = try repositories.jobRepository.fetchJobFiles(jobID: summary.jobID)
                try Task.checkCancellation()

                await MainActor.run {
                    self.currentSummary = summary
                    self.selectedJobID = summary.jobID
                    self.jobs = jobs
                    self.selectedJobFiles = files
                    self.currentPreviewFiles = files
                    self.knownImportedPreviewFileIDs = Self.knownImportedFileIDs(
                        files: files,
                        dedupeRepository: repositories.dedupeRepository
                    )
                    self.applyRecommendationAfterScan(files: files, summary: summary)
                    self.rebuildPreviewSessions(files: files, defaultLabel: location)
                    self.rebuildPreviewPlanCache()
                    self.statusMessage = "Scan complete"
                    self.isWorking = false
                    self.importTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    self.statusMessage = "Scan cancelled"
                    self.isWorking = false
                    self.importTask = nil
                }
            } catch SDImportError.cancelled {
                await MainActor.run {
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    self.statusMessage = "Scan cancelled"
                    self.isWorking = false
                    self.importTask = nil
                }
            } catch {
                await MainActor.run {
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    self.statusMessage = "Scan failed: \(error)"
                    self.isWorking = false
                    self.importTask = nil
                }
            }
        }
    }

    var isCustomImportMode: Bool {
        importPreviewMode == .custom
    }

    func beginCustomImportMode() {
        guard importPreviewMode != .custom else {
            return
        }
        customImportBaseWorkflowProfile = workflowProfile
        importPreviewMode = .custom
    }

    func resetToRecommendedImportMode() {
        importPreviewMode = .recommended
        customImportBaseWorkflowProfile = nil
        let recommendedProfile = mediaContentProfile?.recommendedWorkflow ?? workflowProfile
        applyWorkflowProfile(recommendedProfile, userInitiated: false)
        workflowProfileWasManuallyChosenForCurrentJob = false
    }

    func useCustomMediaSelection(_ selection: ImportMediaSelection) {
        beginCustomImportMode()
        importMediaSelection = selection
        applyMediaSelectionToPreviewSessions(userInitiated: true)
    }

    func useCustomOrganizationPreset(_ preset: ImportOrganizationPreset) {
        beginCustomImportMode()
        organizationPreset = preset
        organizationPresetDidChange(userInitiated: true)
    }

    func useFolderGrouping(_ grouping: ImportFolderGrouping) {
        folderGrouping = grouping
        folderGroupingDidChange()
    }

    func setPreviewSessionInclusion(
        _ keyPath: WritableKeyPath<ImportPreviewSession, Bool>,
        to isIncluded: Bool
    ) {
        previewSessions = previewSessions.map { session in
            var session = session
            session[keyPath: keyPath] = isIncluded
            return session
        }
    }

    func applyMediaSelectionToPreviewSessions(userInitiated: Bool = true) {
        if userInitiated {
            beginCustomImportMode()
        }

        if organizationPreset == .footageBackup {
            importMediaSelection = .videosOnly
        }

        if let matchedProfile = ImportWorkflowProfile.matching(
            mediaSelection: importMediaSelection,
            organizationPreset: organizationPreset
        ) {
            workflowProfile = matchedProfile
        }

        previewSessions = previewSessions.map { session in
            var session = session
            session.includePhotos = importMediaSelection.includes(.photo)
            session.includeVideos = importMediaSelection.includes(.video)
            session.includeSidecars = workflowProfile.includesSidecarsByDefault
            return session
        }
        if userInitiated {
            workflowProfileWasManuallyChosenForCurrentJob = true
        }
        validatePaths()
        savePreferences()
    }

    func organizationPresetDidChange(userInitiated: Bool = true) {
        if userInitiated {
            beginCustomImportMode()
        }

        if organizationPreset == .footageBackup {
            importMediaSelection = .videosOnly
        } else if let matchedProfile = ImportWorkflowProfile.matching(
            mediaSelection: importMediaSelection,
            organizationPreset: organizationPreset
        ) {
            workflowProfile = matchedProfile
        }
        previewSessions = previewSessions.map { session in
            var session = session
            session.includePhotos = importMediaSelection.includes(.photo)
            session.includeVideos = importMediaSelection.includes(.video)
            session.includeSidecars = workflowProfile.includesSidecarsByDefault
            return session
        }
        if userInitiated {
            workflowProfileWasManuallyChosenForCurrentJob = true
        }
        validatePaths()
        savePreferences()
    }

    func folderGroupingDidChange() {
        rebuildPreviewPlanCache()
        savePreferences()
    }

    func themePreferenceDidChange() {
        savePreferences()
    }

    func applyWorkflowProfile(_ profile: ImportWorkflowProfile, userInitiated: Bool = true) {
        if userInitiated {
            importPreviewMode = .recommended
            customImportBaseWorkflowProfile = nil
        }

        workflowProfile = profile
        importMediaSelection = profile.mediaSelection
        organizationPreset = profile.organizationPreset
        previewSessions = previewSessions.map { session in
            var session = session
            session.includePhotos = profile.mediaSelection.includes(.photo)
            session.includeVideos = profile.mediaSelection.includes(.video)
            session.includeSidecars = profile.includesSidecarsByDefault
            return session
        }
        if userInitiated {
            workflowProfileWasManuallyChosenForCurrentJob = true
        }
        validatePaths()
        savePreferences()
    }

    private func rebuildPreviewPlanCache() {
        let rows = buildPreviewRows()
        previewRows = rows
        previewTotals = buildPreviewTotals(rows: rows)
        previewDestinations = buildPreviewDestinationDirectories(rows: rows)
        previewSpaceRequirements = buildPreviewSpaceRequirements(rows: rows)
    }

    private func clearPreviewPlanCache() {
        previewRows = []
        previewTotals = .empty
        previewDestinations = []
        previewSpaceRequirements = []
    }

    private func buildPreviewRows() -> [ImportPreviewRow] {
        guard let currentSummary else {
            return []
        }

        let builder = ImportPlanBuilder(
            sessions: previewSessions,
            organizationPreset: organizationPreset,
            folderGrouping: folderGrouping,
            roots: DestinationRoots(
                photosURL: URL(fileURLWithPath: expanded(photosPath), isDirectory: true),
                videosURL: URL(fileURLWithPath: expanded(videosPath), isDirectory: true)
            ),
            fallbackLocation: Self.defaultSessionLabel(for: location),
            volumeName: currentSummary.volumeName
        )
        let plans = builder.plans(files: currentPreviewFiles)

        return zip(currentPreviewFiles, plans).compactMap { file, plan in
            guard let id = file.id else {
                return nil
            }
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

    private func buildPreviewTotals(rows: [ImportPreviewRow]) -> ImportPreviewTotals {
        return ImportPreviewTotals(
            copyFiles: rows.filter(\.willCopy).count,
            skippedFiles: rows.filter { !$0.willCopy }.count,
            copyBytes: rows.reduce(Int64(0)) { total, row in
                row.willCopy ? total + row.size : total
            }
        )
    }

    private func buildPreviewDestinationDirectories(rows: [ImportPreviewRow]) -> [ImportPreviewDestination] {
        let grouped = Dictionary(grouping: rows.filter(\.willCopy)) { row in
            row.destinationPath.map {
                URL(fileURLWithPath: $0, isDirectory: false).deletingLastPathComponent().path
            } ?? "Unknown"
        }

        return grouped
            .map { path, rows in
                ImportPreviewDestination(
                    path: path,
                    title: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent,
                    fileCount: rows.count,
                    byteCount: rows.reduce(Int64(0)) { $0 + $1.size }
                )
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func buildPreviewSpaceRequirements(rows: [ImportPreviewRow]) -> [ImportPreviewSpaceRequirement] {
        var grouped: [String: (capacity: VolumeCapacity, requiredBytes: Int64)] = [:]
        let rowsNeedingSpace = rows.filter { row in
            row.willCopy
                && row.size > 0
                && !isKnownImportedFile(row)
        }
        let requiredByDirectory = Dictionary(grouping: rowsNeedingSpace) { row in
            row.destinationPath.map {
                URL(fileURLWithPath: $0, isDirectory: false).deletingLastPathComponent().path
            }
        }

        for (destinationDirectory, directoryRows) in requiredByDirectory {
            guard let destinationDirectory else {
                continue
            }
            guard let capacity = try? DestinationSpaceChecker.fileSystemCapacity(for: destinationDirectory) else {
                continue
            }
            let requiredBytes = directoryRows.reduce(Int64(0)) { $0 + $1.size }

            let existing = grouped[capacity.volumeID]
            grouped[capacity.volumeID] = (
                capacity: existing?.capacity ?? capacity,
                requiredBytes: (existing?.requiredBytes ?? 0) + requiredBytes
            )
        }

        return grouped.values
            .map { item in
                ImportPreviewSpaceRequirement(
                    volumeID: item.capacity.volumeID,
                    displayPath: item.capacity.displayPath,
                    requiredBytes: item.requiredBytes,
                    availableBytes: item.capacity.availableBytes,
                    totalBytes: item.capacity.totalBytes
                )
            }
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
    }

    private func isKnownImportedFile(_ row: ImportPreviewRow) -> Bool {
        knownImportedPreviewFileIDs.contains(row.id)
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
        if let dedupeRepository {
            knownImportedPreviewFileIDs = Self.knownImportedFileIDs(
                files: currentPreviewFiles,
                dedupeRepository: dedupeRepository
            )
            rebuildPreviewPlanCache()
        }
        if let failure = previewSpaceRequirements.first(where: { !$0.isSatisfied }) {
            statusMessage = "Not enough space in \(failure.displayPath)"
            return
        }

        let sessions = previewSessions
        let organizationPreset = organizationPreset
        let folderGrouping = folderGrouping
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: expanded(photosPath), isDirectory: true),
            videosURL: URL(fileURLWithPath: expanded(videosPath), isDirectory: true)
        )
        let fallbackLocation = Self.defaultSessionLabel(for: location)
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
                    folderGrouping: folderGrouping,
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
                let minimumUpdateInterval: TimeInterval = 0.75

                let result = try engine.importFiles(
                    jobID: jobID,
                    onProgress: { progress in
                        latestProgress = progress
                        if progress.status == "aborted" {
                            return
                        }

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
                let jobs = try repositories.jobRepository.listImportHistoryJobs(limit: 100)
                let files = try repositories.jobRepository.fetchJobFiles(jobID: jobID)

                await MainActor.run {
                    guard self.importTask != nil else {
                        return
                    }
                    self.currentResult = result
                    self.importProgress = latestProgress
                    self.jobs = jobs
                    self.selectedJobID = jobID
                    self.selectedJobFiles = files
                    if self.currentSummary?.jobID == jobID {
                        self.currentPreviewFiles = files
                    } else {
                        self.rebuildPreviewPlanCache()
                    }
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
                        if self.currentSummary?.jobID == jobID {
                            self.currentPreviewFiles = snapshot.files
                        } else {
                            self.rebuildPreviewPlanCache()
                        }
                    }
                    self.currentResult = nil
                    self.importProgress = nil
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
                let snapshot = try Self.historyListSnapshot(
                    databaseURL: databaseURL,
                    selectedJobID: selectedJobID
                )
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self.jobs = snapshot.jobs
                    self.selectedJobID = snapshot.selectedJobID
                    self.selectedJobFiles = []
                    self.isHistoryLoading = false
                    self.isHistoryDetailLoading = false
                    self.historyRefreshTask = nil
                    if let selectedJobID = snapshot.selectedJobID {
                        self.loadJobDetail(jobID: selectedJobID)
                    }
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
        guard !isWorking else {
            statusMessage = "Finish the current scan or import first"
            return
        }
        guard selectedJob()?.canRetryImport == true else {
            statusMessage = "Only failed, cancelled, or partial imports can be retried"
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
        importPreviewMode = .recommended
        customImportBaseWorkflowProfile = nil

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
        location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled"
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
            try repositories.jobRepository.listImportHistoryJobs(limit: 100),
            try repositories.jobRepository.fetchJobFiles(jobID: jobID)
        )
    }

    nonisolated private static func historyListSnapshot(
        databaseURL: URL,
        selectedJobID: String?
    ) throws -> (jobs: [ImportJob], selectedJobID: String?) {
        let repositories = try makeRepositories(databaseURL: databaseURL)
        let jobs = try repositories.jobRepository.listImportHistoryJobs(limit: 100)
        let selectedJobID = selectedJobID.flatMap { id in
            jobs.contains { $0.id == id } ? id : nil
        } ?? jobs.first?.id
        return (jobs, selectedJobID)
    }

    nonisolated private static func knownImportedFileIDs(
        files: [JobFileRecord],
        dedupeRepository: DedupeRepository
    ) -> Set<Int64> {
        Set(
            files.compactMap { file in
                guard let id = file.id else {
                    return nil
                }
                let fingerprint = FileFingerprint.compute(
                    size: file.size,
                    modificationDateString: file.modificationDateString,
                    identityHint: file.relativePath ?? file.filename
                )
                return ((try? dedupeRepository.contains(fingerprint)) == true) ? id : nil
            }
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
        workflowProfile = configuration.lastWorkflowProfile
        folderGrouping = configuration.lastFolderGrouping
        themePreference = configuration.themePreference
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
            defaultLocation: Self.defaultSessionLabel(for: location),
            historyRetention: historyRetention,
            autoPromptEnabled: autoPromptEnabled,
            hasCompletedOnboarding: hasCompletedOnboarding,
            lastWorkflowProfile: workflowProfile,
            lastFolderGrouping: folderGrouping,
            themePreference: themePreference,
            workflowProfilesByVolume: workflowProfilesByVolume
        )
    }

    private func resolvedPath(for purpose: BookmarkPurpose, fallback: String) throws -> String {
        bookmarkStore?.resolvedPath(purpose: purpose, fallback: fallback) ?? fallback
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
    static let folderGrouping = "SDImport.folderGrouping"
    static let themePreference = "SDImport.themePreference"
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
