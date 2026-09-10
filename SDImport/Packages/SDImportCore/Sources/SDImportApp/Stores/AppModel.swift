import AppKit
import Foundation
import OSLog
import SDImportCommerce
import SDImportCore

private let appLogSubsystem = Bundle.main.bundleIdentifier ?? "com.xcv58.SDImport"
private let importLogger = Logger(subsystem: appLogSubsystem, category: "Import")
private let diagnosticsLogger = Logger(subsystem: appLogSubsystem, category: "Diagnostics")

typealias ImportPreviewSession = ImportPlanSession

enum ImportPreviewGroupKind: Hashable {
    case rawJPEG
    case videoSidecars
}

struct ImportPreviewRow: Identifiable, Hashable {
    let id: Int64
    let filename: String
    let date: String
    let modificationDateString: String
    let mediaKind: MediaKind
    let sourcePath: String
    let destinationPath: String?
    let disposition: ImportPlanDisposition
    let visualGroupID: String?
    let visualGroupKind: ImportPreviewGroupKind?
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
    enum Root: Hashable {
        case library
        case photos
        case videos
        case other
    }

    var id: String { path }
    let path: String
    let root: Root
    let relativePath: String
    let fileCount: Int
    let byteCount: Int64
}

struct ImportPreviewSpaceRequirement: Identifiable, Hashable {
    var id: String { volumeID }
    let volumeID: String
    let displayPath: String
    let requiredBytes: Int64
    let availableBytes: Int64?
    let totalBytes: Int64?

    var isKnown: Bool {
        availableBytes != nil
    }

    var isSatisfied: Bool {
        guard let availableBytes else {
            return false
        }
        return requiredBytes <= availableBytes
    }
}

private struct SourceEjectionTarget: Sendable {
    let displayName: String
    let volumes: [MountedVolume]
    let ejectionVolumes: [MountedVolume]

    var volumeCount: Int {
        volumes.count
    }
}

private enum ImportRetryContext {
    case currentReview
    case existingJob(jobID: String)
    case portableReceiptOverride
    case eject(jobID: String, target: SourceEjectionTarget)
}

private struct SourceDeviceEjectionError: LocalizedError {
    let failedVolumeName: String
    let ejectedVolumeNames: [String]
    let message: String

    var errorDescription: String? {
        if ejectedVolumeNames.isEmpty {
            return "\(failedVolumeName) remains mounted: \(message)"
        }
        return "\(ejectedVolumeNames.joined(separator: ", ")) ejected, but \(failedVolumeName) remains mounted: \(message)"
    }
}

struct RecentPathSuggestion: Identifiable {
    var id: String { choice.path }
    let choice: RecentPathChoice
    let validation: PathValidationResult

    var path: String { choice.path }
    var displayName: String { choice.displayName }
    var isAvailable: Bool { validation.isUsable }

    var menuTitle: String {
        let usage = choice.useCount == 1 ? "used once" : "used \(choice.useCount) times"
        return "\(displayName) · \(parentDisplayPath) · \(validation.message) · \(usage)"
    }

    private var parentDisplayPath: String {
        let parentPath = URL(fileURLWithPath: choice.path, isDirectory: true)
            .deletingLastPathComponent()
            .path
        guard !parentPath.isEmpty, parentPath != "/" else {
            return choice.path
        }

        return Self.shortPath(parentPath)
    }

    private static func shortPath(_ path: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            let relativePath = String(path.dropFirst(homePath.count + 1))
            let components = relativePath.split(separator: "/")
            let suffix = components.suffix(2).joined(separator: "/")
            return suffix.isEmpty ? "~" : "~/\(suffix)"
        }

        let components = path.split(separator: "/")
        guard components.count > 2 else {
            return path
        }

        return ".../" + components.suffix(2).joined(separator: "/")
    }
}

struct ImportReportPresentation: Identifiable, Hashable {
    var id: String { job.id }
    let job: ImportJob
    let report: ImportReport?
    let files: [JobFileRecord]
    let loadError: String?
}

struct SettingsFeedback: Equatable {
    enum Role {
        case information
        case error
    }

    let message: String
    let role: Role
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem = .import
    @Published private(set) var importUIPhase: ImportUIPhase = .source
    @Published private(set) var activeImportOperation: ImportOperationKind?
    @Published private(set) var importFailure: ImportFailureState?
    @Published var cardPath: String
    @Published var photosPath: String
    @Published var videosPath: String
    @Published var location: String {
        didSet {
            syncPreviewSessionLabels(from: oldValue, to: location)
            rebuildRecentShootNameSuggestions()
        }
    }
    @Published var historyRetention: RetentionPolicy
    @Published var autoPromptEnabled: Bool
    @Published private(set) var backgroundPromptServiceStatus: BackgroundPromptServiceStatus = .notRegistered
    @Published private(set) var backgroundPromptAgentState: BackgroundPromptAgentState?
    @Published private(set) var backgroundPromptLastError: String?
    private var backgroundPromptLastErrorSequence: UInt64?
    @Published private(set) var backgroundPromptApplicationOwnership = LoginItemController.applicationOwnership
    @Published var ejectAfterSuccessfulImport: Bool
    @Published var portableImportReceiptsEnabled: Bool
    @Published var hasCompletedOnboarding: Bool
    @Published var workflowProfile: ImportWorkflowProfile
    @Published var importMediaSelection: ImportMediaSelection
    @Published var organizationPreset: ImportOrganizationPreset
    @Published var destinationLayout: ImportDestinationLayout
    @Published var folderGrouping: ImportFolderGrouping
    @Published var importDefaults: ImportDefaults
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
    @Published var currentResult: ImportResult? {
        didSet {
            rebuildSourceEjectionTargetCache()
        }
    }
    @Published var importProgress: ImportProgress?
    @Published var jobs: [ImportJob] = [] {
        didSet {
            rebuildRecentImportSuggestions()
            rebuildSourceEjectionTargetCache()
        }
    }
    @Published var selectedJobID: String?
    @Published var selectedJobFiles: [JobFileRecord] = []
    @Published var isHistoryLoading = false
    @Published var isHistoryDetailLoading = false
    @Published var availableSourceVolumes: [MountedVolume] = []
    @Published private(set) var recentShootNameSuggestions: [RecentShootNameChoice] = []
    @Published private(set) var recentSourcePathSuggestions: [RecentPathSuggestion] = []
    @Published private(set) var recentPhotosPathSuggestions: [RecentPathSuggestion] = []
    @Published private(set) var recentVideosPathSuggestions: [RecentPathSuggestion] = []
    @Published var sourceValidation: PathValidationResult = .empty(purpose: .source)
    @Published var photosValidation: PathValidationResult = .empty(purpose: .destination)
    @Published var videosValidation: PathValidationResult = .empty(purpose: .destination)
    @Published var defaultPhotosValidation: PathValidationResult = .empty(purpose: .destination)
    @Published var defaultVideosValidation: PathValidationResult = .empty(purpose: .destination)
    @Published var pendingMountedVolume: MountedVolume? {
        didSet {
            if oldValue != nil, pendingMountedVolume == nil {
                schedulePendingMountHandoffRetry()
            }
        }
    }
    @Published var reportPresentation: ImportReportPresentation?
    @Published var statusMessage = ""
    @Published private(set) var settingsFeedback: SettingsFeedback?
    @Published var isWorking = false {
        didSet {
            if oldValue, !isWorking {
                schedulePendingMountHandoffRetry()
            }
        }
    }
    @Published private(set) var isEjectingSource = false {
        didSet {
            if oldValue, !isEjectingSource {
                schedulePendingMountHandoffRetry()
            }
        }
    }
    @Published private(set) var ejectedSourceJobID: String?
    @Published private(set) var ejectedSourceName: String?
    @Published private(set) var ejectedSourceVolumeCount = 0
    @Published var setupError: String?

    private let defaults = UserDefaults.standard
    private let purchaseManager: PurchaseManager
    private var initialOnboardingSourcePath: String
    private var applicationSupportURL: URL?
    private var reportsURL: URL?
    private var databaseURL: URL?
    private var jobRepository: JobRepository?
    private var dedupeRepository: DedupeRepository?
    private var settingsRepository: SettingsRepository?
    private var bookmarkStore: BookmarkStore?
    private var folderAccesses: [BookmarkPurpose: SecurityScopedResourceAccess] = [:]
    private var importTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var historyDetailTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var sourceEjectionTask: Task<Void, Never>?
    private var backgroundPromptOperationTask: Task<Void, Never>?
    private var backgroundPromptHealthRefreshTask: Task<Void, Never>?
    private var backgroundPromptHealthRefreshGeneration = BackgroundPromptHealthRefreshGeneration()
    private let backgroundPromptRetryScheduler = BackgroundPromptRetryScheduler()
    private var mountedVolumesSnapshot: [MountedVolume] = []
    private var cachedSelectedSourceEjectionTarget: SourceEjectionTarget?
    private var cachedResultSourceEjectionTargets: [String: SourceEjectionTarget] = [:]
    private var mountObserver: MountEventObserver?
    private var pendingMountHandoffRetryTask: Task<Void, Never>?
    private var activeImportRetryContext: ImportRetryContext?
    private var failedImportRetryContext: ImportRetryContext?
    private var workflowProfilesByVolume: [String: ImportWorkflowProfile] = [:]
    private var preferredMixedDestinationLayout: ImportDestinationLayout = .singleLibrary
    private var hiddenRecentPaths: Set<String> = []
    private var workflowProfileWasManuallyChosenForCurrentJob = false
    private var knownImportedPreviewFileIDs: Set<Int64> = []
    private var currentPreviewFiles: [JobFileRecord] = [] {
        didSet {
            rebuildPreviewPlanCache()
        }
    }

    init(purchaseManager: PurchaseManager) {
        self.purchaseManager = purchaseManager
        let initialConfiguration = AppConfiguration.defaultConfiguration(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            distribution: AppDistribution.current
        )
        let storedSourcePath = defaults.string(forKey: DefaultsKeys.cardPath)
            ?? initialConfiguration.sourcePath
        let storedPhotosPath = defaults.string(forKey: DefaultsKeys.photosPath)
            ?? initialConfiguration.photosPath
        let storedVideosPath = defaults.string(forKey: DefaultsKeys.videosPath)
            ?? initialConfiguration.videosPath
        let storedShootName = defaults.string(forKey: DefaultsKeys.location)
            ?? initialConfiguration.defaultLocation
        let storedWorkflowProfile = ImportWorkflowProfile(
            rawValue: defaults.string(forKey: DefaultsKeys.workflowProfile) ?? ""
        ) ?? .mixedShootSession
        let storedMediaSelection = ImportMediaSelection(
            rawValue: defaults.string(forKey: DefaultsKeys.importMediaSelection) ?? ""
        ) ?? storedWorkflowProfile.mediaSelection
        let storedOrganizationPreset = ImportOrganizationPreset(
            rawValue: defaults.string(forKey: DefaultsKeys.organizationPreset) ?? ""
        ) ?? storedWorkflowProfile.organizationPreset
        let storedDestinationLayout = ImportDestinationLayout(
            rawValue: defaults.string(forKey: DefaultsKeys.destinationLayout) ?? ""
        ) ?? ImportDestinationLayout(organizationPreset: storedOrganizationPreset)
        let storedPreferredMixedDestinationLayout = ImportDestinationLayout(
            rawValue: defaults.string(forKey: DefaultsKeys.preferredMixedDestinationLayout) ?? ""
        ) ?? (storedDestinationLayout == .footageBackup ? .singleLibrary : storedDestinationLayout)
        let storedFolderGrouping = ImportFolderGrouping(
            rawValue: defaults.string(forKey: DefaultsKeys.folderGrouping) ?? ""
        ) ?? .byDay

        self.initialOnboardingSourcePath = storedSourcePath
        self.cardPath = storedSourcePath
        self.photosPath = storedPhotosPath
        self.videosPath = storedVideosPath
        self.location = storedShootName
        self.historyRetention = .defaultPolicy
        self.autoPromptEnabled = defaults.bool(forKey: DefaultsKeys.autoPromptEnabled)
        self.ejectAfterSuccessfulImport = AppDistribution.current.supportsSourceEjection
            && defaults.bool(forKey: DefaultsKeys.ejectAfterSuccessfulImport)
        self.portableImportReceiptsEnabled = defaults.bool(forKey: DefaultsKeys.portableImportReceiptsEnabled)
        self.hasCompletedOnboarding = defaults.bool(forKey: DefaultsKeys.hasCompletedOnboarding)
        self.workflowProfile = storedWorkflowProfile
        self.importMediaSelection = storedMediaSelection
        self.destinationLayout = storedDestinationLayout
        self.organizationPreset = storedDestinationLayout.organizationPreset
        self.preferredMixedDestinationLayout = storedPreferredMixedDestinationLayout == .footageBackup
            ? .singleLibrary
            : storedPreferredMixedDestinationLayout
        self.folderGrouping = storedFolderGrouping
        self.importDefaults = ImportDefaults(
            photosPath: storedPhotosPath,
            videosPath: storedVideosPath,
            shootName: storedShootName,
            workflowProfile: storedWorkflowProfile,
            mediaSelection: storedMediaSelection,
            destinationLayout: storedDestinationLayout,
            preferredMixedDestinationLayout: storedPreferredMixedDestinationLayout,
            folderGrouping: storedFolderGrouping
        )
        self.themePreference = AppThemePreference(
            rawValue: defaults.string(forKey: DefaultsKeys.themePreference) ?? ""
        ) ?? .system
        normalizeDestinationForCurrentImportType()
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
            if AppDistribution.current.importsUnsandboxedLegacyState {
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
            } else {
                legacyImportMessage = nil
            }
            try loadStoredConfiguration()
#if DEBUG
            if let preparedConfiguration = BackgroundPromptRuntimeQA
                .preparedApplicationConfiguration(currentConfiguration())
            {
                autoPromptEnabled = preparedConfiguration.autoPromptEnabled
                hasCompletedOnboarding = preparedConfiguration.hasCompletedOnboarding
                guard savePreferences(persistAutoPromptPreference: true) else {
                    throw SDImportError.invalidArgument(
                        "Could not persist the background helper QA preparation state"
                    )
                }
            } else if BackgroundPromptRuntimeQA.consumesInjectedHandoff()
                || BackgroundPromptRuntimeQA.helperLifecycleIsActive()
            {
                autoPromptEnabled = true
                hasCompletedOnboarding = true
            }
#endif
            refreshFolderAccesses()
            if clearUnauthorizedAppStoreDestinationDefaults() {
                _ = savePreferences()
            }
            let recovery = try RecoveryService(jobRepository: JobRepository(pool: pool))
                .recoverInterruptedImports()
            refreshAvailableSourceVolumes()
            validatePaths()
            validateDefaultPaths()
            refreshHistory()
            LoginItemController.invalidateApplicationOwnershipCache()
            refreshBackgroundPromptHealth()
            do {
                try authorizeCurrentBackgroundPromptHelperIfNeeded()
            } catch {
                recordBackgroundPromptError(
                    "Could not authorize the background helper: \(Self.errorMessage(for: error))"
                )
            }
            startMountObserver()
            reconcileBackgroundPromptRegistration()
            statusMessage = legacyImportMessage
                ?? (recovery.recoveredJobs > 0 ? "Recovered interrupted import" : "Ready")
        } catch {
            setupError = String(describing: error)
            statusMessage = "Setup failed"
        }
    }

    @discardableResult
    func savePreferences(
        refreshFolderBookmarks: Bool = false,
        folderBookmarkPurposes: Set<BookmarkPurpose>? = nil,
        persistAutoPromptPreference: Bool = false
    ) -> Bool {
        settingsFeedback = nil
        let bookmarkPurposes = refreshFolderBookmarks
            ? folderBookmarkPurposes ?? Set(BookmarkPurpose.allCases)
            : []
        if AppDistribution.current == .macAppStore {
            for purpose in bookmarkPurposes where !hasActiveFolderAccess(covering: folderPath(for: purpose)) {
                let error = FolderAccessAuthorizationError(purpose: purpose)
                statusMessage = Self.errorMessage(for: error)
                settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
                return false
            }
        }
        do {
            if persistAutoPromptPreference {
                try settingsRepository?.saveConfiguration(currentConfiguration())
            } else {
                try settingsRepository?.saveConfigurationPreservingAutoPromptPreference(
                    currentConfiguration()
                )
            }
        } catch {
            statusMessage = "Could not save settings: \(error)"
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
            return false
        }

        defaults.set(cardPath, forKey: DefaultsKeys.cardPath)
        defaults.set(importDefaults.photosPath, forKey: DefaultsKeys.photosPath)
        defaults.set(importDefaults.videosPath, forKey: DefaultsKeys.videosPath)
        defaults.set(importDefaults.shootName, forKey: DefaultsKeys.location)
        if persistAutoPromptPreference {
            defaults.set(autoPromptEnabled, forKey: DefaultsKeys.autoPromptEnabled)
        }
        defaults.set(ejectAfterSuccessfulImport, forKey: DefaultsKeys.ejectAfterSuccessfulImport)
        defaults.set(portableImportReceiptsEnabled, forKey: DefaultsKeys.portableImportReceiptsEnabled)
        defaults.set(hasCompletedOnboarding, forKey: DefaultsKeys.hasCompletedOnboarding)
        defaults.set(importDefaults.workflowProfile.rawValue, forKey: DefaultsKeys.workflowProfile)
        defaults.set(importDefaults.mediaSelection.rawValue, forKey: DefaultsKeys.importMediaSelection)
        defaults.set(importDefaults.destinationLayout.organizationPreset.rawValue, forKey: DefaultsKeys.organizationPreset)
        defaults.set(importDefaults.destinationLayout.rawValue, forKey: DefaultsKeys.destinationLayout)
        defaults.set(importDefaults.preferredMixedDestinationLayout.rawValue, forKey: DefaultsKeys.preferredMixedDestinationLayout)
        defaults.set(importDefaults.folderGrouping.rawValue, forKey: DefaultsKeys.folderGrouping)
        defaults.set(themePreference.rawValue, forKey: DefaultsKeys.themePreference)

        guard !bookmarkPurposes.isEmpty else {
            return true
        }

        do {
            for purpose in bookmarkPurposes {
                try saveFolderBookmark(purpose, path: folderPath(for: purpose))
            }
        } catch {
            statusMessage = "Settings saved, but folder access could not be refreshed: \(error)"
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
            return AppDistribution.current != .macAppStore
        }
        return true
    }

    func chooseCardFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: "Choose SD Card or Source Folder",
            initialPath: cardPath
        ), retainSelectedFolderAccess(.source, url: url, persistBookmark: true) else {
            return
        }
        unhideRecentPath(url.path)
        cardPath = url.path
        sourcePathDidChange()
        savePreferences()
    }

    func chooseOnboardingCardFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: "Choose SD Card or Source Folder",
            initialPath: cardPath
        ), retainSelectedFolderAccess(.source, url: url, persistBookmark: true) else {
            return
        }
        cardPath = url.path
        sourcePathDidChange()
    }

    func chooseOnboardingPhotosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: "Choose Photo Destination",
            initialPath: photosPath
        ), retainSelectedFolderAccess(.photos, url: url, persistBookmark: true) else {
            return
        }
        photosPath = url.path
        destinationPathDidChange()
    }

    func chooseOnboardingVideosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: "Choose Video Destination",
            initialPath: videosPath
        ), retainSelectedFolderAccess(.videos, url: url, persistBookmark: true) else {
            return
        }
        videosPath = url.path
        destinationPathDidChange()
    }

    func choosePhotosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: "Choose Photo Destination",
            initialPath: photosPath
        ), retainSelectedFolderAccess(.photos, url: url, persistBookmark: false) else {
            return
        }
        unhideRecentPath(url.path)
        photosPath = url.path
        destinationPathDidChange()
    }

    func chooseVideosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: "Choose Video Destination",
            initialPath: videosPath
        ), retainSelectedFolderAccess(.videos, url: url, persistBookmark: false) else {
            return
        }
        unhideRecentPath(url.path)
        videosPath = url.path
        destinationPathDidChange()
    }

    func chooseDefaultPhotosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: "Choose Default Photo Destination",
            initialPath: importDefaults.photosPath
        ), retainSelectedFolderAccess(.photos, url: url, persistBookmark: true) else {
            return
        }
        importDefaults.photosPath = url.path
        defaultDestinationPathDidChange()
        savePreferences()
    }

    func chooseDefaultVideosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: "Choose Default Video Destination",
            initialPath: importDefaults.videosPath
        ), retainSelectedFolderAccess(.videos, url: url, persistBookmark: true) else {
            return
        }
        importDefaults.videosPath = url.path
        defaultDestinationPathDidChange()
        savePreferences()
    }

    func refreshAvailableSourceVolumes() {
        let detector = VolumeDetector()
        mountedVolumesSnapshot = detector.allMountedVolumes(
            includeCapacity: AppDistribution.current.mountPrivacyPolicy.includesCapacityBeforeConsent
        )
        availableSourceVolumes = detector.likelyImportVolumes(from: mountedVolumesSnapshot)
        rebuildSourceEjectionTargetCache()
        rebuildRecentImportSuggestions()
    }

    var availableSourceDeviceGroups: [MountedDeviceGroup] {
        MountedDeviceGrouper().groups(from: availableSourceVolumes)
    }

    func sourceDeviceGroup(containing volume: MountedVolume) -> MountedDeviceGroup {
        MountedDeviceGrouper().group(containing: volume, among: availableSourceVolumes)
    }

    var shouldOfferSelectedSourceEjection: Bool {
        AppDistribution.current.supportsSourceEjection
            && cachedSelectedSourceEjectionTarget != nil
    }

    var canEjectSelectedSource: Bool {
        AppDistribution.current.supportsSourceEjection
            && !isWorking
            && !isEjectingSource
            && cachedSelectedSourceEjectionTarget != nil
    }

    var selectedSourceEjectionButtonTitle: String {
        guard !isEjectingSource else {
            return "Ejecting Source…"
        }
        guard let target = cachedSelectedSourceEjectionTarget else {
            return "Eject Source"
        }
        if target.volumeCount > 1 {
            return "Eject \(target.displayName) — \(target.volumeCount) Volumes"
        }
        return "Eject \(target.displayName)"
    }

    func ejectSelectedSource() {
        guard
            AppDistribution.current.supportsSourceEjection,
            !isWorking,
            !isEjectingSource,
            let target = cachedSelectedSourceEjectionTarget
        else {
            statusMessage = "Source cannot be ejected safely"
            return
        }

        let sourceJobID: String
        if
            let summary = currentSummary,
            URL(fileURLWithPath: summary.mountPath, isDirectory: true).standardizedFileURL
                == URL(fileURLWithPath: cardPath, isDirectory: true).standardizedFileURL
        {
            sourceJobID = summary.jobID
        } else {
            sourceJobID = "manual-\(target.volumes.map(\.id).sorted().joined(separator: "-"))"
        }
        ejectSource(jobID: sourceJobID, target: target)
    }

    func selectSourceVolume(_ volume: MountedVolume) {
        selectSourcePath(volume.mountURL.path)
    }

    func selectSourcePath(_ path: String) {
        unhideRecentPath(path)
        cardPath = path
        sourcePathDidChange()
        savePreferences()
    }

    func selectPhotosPath(_ path: String) {
        unhideRecentPath(path)
        photosPath = path
        destinationPathDidChange()
    }

    func selectVideosPath(_ path: String) {
        unhideRecentPath(path)
        videosPath = path
        destinationPathDidChange()
    }

    var hasForgottenRecentPaths: Bool {
        !hiddenRecentPaths.isEmpty
    }

    func forgetRecentPath(_ path: String) {
        let normalizedPath = normalizedRecentPath(path)
        guard !normalizedPath.isEmpty else {
            return
        }

        hiddenRecentPaths.insert(normalizedPath)
        rebuildRecentPathSuggestions()
        savePreferences()
        statusMessage = "Recent folder forgotten"
    }

    func restoreForgottenRecentPaths() {
        guard !hiddenRecentPaths.isEmpty else {
            return
        }

        hiddenRecentPaths.removeAll()
        rebuildRecentPathSuggestions()
        savePreferences()
        statusMessage = "Recent folders restored"
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
        guard !isWorking, !isEjectingSource else {
            return
        }
        currentSummary = nil
        currentResult = nil
        importProgress = nil
        ejectedSourceJobID = nil
        ejectedSourceName = nil
        ejectedSourceVolumeCount = 0
        previewSessions = []
        clearPreviewPlanCache()
        selectedJobFiles = []
        currentPreviewFiles = []
        knownImportedPreviewFileIDs = []
        mediaContentProfile = nil
        photoPairSummary = nil
        workflowProfileWasManuallyChosenForCurrentJob = false
        transitionImportWorkspace(.recover(hasScannedJob: false))
        validatePaths()
        rebuildSourceEjectionTargetCache()
    }

    func destinationPathDidChange() {
        validatePaths()
        rebuildPreviewPlanCache()
    }

    func defaultDestinationPathDidChange() {
        validateDefaultPaths()
    }

    var currentImportDraft: ImportDraft {
        ImportDraft(
            sourcePath: cardPath,
            photosPath: photosPath,
            videosPath: videosPath,
            shootName: location,
            workflowProfile: workflowProfile,
            mediaSelection: importMediaSelection,
            destinationLayout: destinationLayout,
            folderGrouping: folderGrouping,
            sessions: previewSessions
        )
    }

    var importDraftUsesDefaults: Bool {
        photosPath == importDefaults.photosPath
            && videosPath == importDefaults.videosPath
            && Self.defaultSessionLabel(for: location) == Self.defaultSessionLabel(for: importDefaults.shootName)
            && workflowProfile == importDefaults.workflowProfile
            && importMediaSelection == importDefaults.mediaSelection
            && destinationLayout == importDefaults.destinationLayout
            && folderGrouping == importDefaults.folderGrouping
    }

    func saveImportDraftAsDefaults() {
        let previousDefaults = importDefaults
        importDefaults = ImportDefaults(
            photosPath: photosPath,
            videosPath: videosPath,
            shootName: Self.defaultSessionLabel(for: location),
            workflowProfile: workflowProfile,
            mediaSelection: importMediaSelection,
            destinationLayout: destinationLayout,
            preferredMixedDestinationLayout: preferredMixedDestinationLayout,
            folderGrouping: folderGrouping
        )
        validateDefaultPaths()
        if savePreferences(
            refreshFolderBookmarks: true,
            folderBookmarkPurposes: Set([.source] + requiredDestinationPurposes())
        ) {
            if settingsFeedback == nil {
                statusMessage = "Import settings saved as defaults"
            }
        } else {
            importDefaults = previousDefaults
            validateDefaultPaths()
        }
    }

    func resetImportDraftFromDefaults() {
        photosPath = importDefaults.photosPath
        videosPath = importDefaults.videosPath
        location = importDefaults.shootName
        workflowProfile = importDefaults.workflowProfile
        importMediaSelection = importDefaults.mediaSelection
        destinationLayout = importDefaults.destinationLayout
        preferredMixedDestinationLayout = importDefaults.preferredMixedDestinationLayout
        folderGrouping = importDefaults.folderGrouping
        organizationPreset = destinationLayout.organizationPreset
        refreshFolderAccess(.photos)
        refreshFolderAccess(.videos)
        validatePaths()
    }

    func validatePaths() {
        let validator = PathValidator()
        sourceValidation = validator.validate(path: cardPath, purpose: .source)
        photosValidation = validator.validate(path: photosPath, purpose: .destination)
        videosValidation = validator.validate(path: videosPath, purpose: .destination)
        rebuildRecentImportSuggestions()
    }

    func validateDefaultPaths() {
        let validator = PathValidator()
        defaultPhotosValidation = validator.validate(path: importDefaults.photosPath, purpose: .destination)
        defaultVideosValidation = validator.validate(path: importDefaults.videosPath, purpose: .destination)
    }

    func validateAndSaveDestinationSettings() async {
        let photosPath = importDefaults.photosPath
        let videosPath = importDefaults.videosPath
        let results = await Task.detached(priority: .userInitiated) {
            let validator = PathValidator()
            return (
                validator.validate(path: photosPath, purpose: .destination),
                validator.validate(path: videosPath, purpose: .destination)
            )
        }.value

        guard
            !Task.isCancelled,
            photosPath == importDefaults.photosPath,
            videosPath == importDefaults.videosPath
        else {
            return
        }

        defaultPhotosValidation = results.0
        defaultVideosValidation = results.1
        savePreferences(
            refreshFolderBookmarks: true,
            folderBookmarkPurposes: [.photos, .videos]
        )
    }

    var canScan: Bool {
        !isWorking && !isEjectingSource && sourceValidation.isUsable
    }

    var canImportPlannedFiles: Bool {
        return !isWorking
            && !isEjectingSource
            && currentSummary != nil
            && previewTotals.copyFiles > 0
            && sourceValidation.isUsable
            && requiredDestinationPathsAreUsable()
            && previewSpaceRequirements.allSatisfy(\.isSatisfied)
    }

    var importReadinessMessage: String? {
        if previewTotals.copyFiles == 0 {
            return "No files are selected for copying"
        }
        if !sourceValidation.isUsable {
            return sourceValidation.message
        }
        if !requiredDestinationPathsAreUsable() {
            return "Choose usable destination folders"
        }
        if let requirement = previewSpaceRequirements.first(where: { !$0.isKnown }) {
            return "Available space couldn’t be checked for \(requirement.displayPath)"
        }
        if let requirement = previewSpaceRequirements.first(where: { !$0.isSatisfied }) {
            let required = ByteCountFormatter.string(fromByteCount: requirement.requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(
                fromByteCount: requirement.availableBytes ?? 0,
                countStyle: .file
            )
            return "\(required) required; \(available) available"
        }
        return nil
    }

    var previewAttentionCount: Int {
        previewRows.filter { $0.disposition.attention >= .attention }.count
    }

    var previewDestinationIssueCount: Int {
        previewSpaceRequirements.filter { !$0.isSatisfied }.count
    }

    func scan() {
        guard !isWorking, !isEjectingSource else {
            statusMessage = "Finish the current scan or import first"
            return
        }
        guard ensureSourceAccessForScan() else {
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

        savePreferences()
        currentResult = nil
        importProgress = nil
        ejectedSourceJobID = nil
        ejectedSourceName = nil
        ejectedSourceVolumeCount = 0
        previewSessions = []
        currentPreviewFiles = []
        clearPreviewPlanCache()
        isWorking = true
        transitionImportWorkspace(.beginScan)
        statusMessage = "Scanning..."
        importLogger.info("Scan started")

        let cardPath = resolvedPath(cardPath, validation: sourceValidation)
        let sourceVolume = Self.mountedSourceVolume(containing: cardPath)
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let photosPath = planningPath(
            photosPath,
            validation: photosValidation,
            fallback: homeURL.appendingPathComponent("Pictures/Photos", isDirectory: true).path
        )
        let videosPath = planningPath(
            videosPath,
            validation: videosValidation,
            fallback: homeURL.appendingPathComponent("Downloads", isDirectory: true).path
        )
        let location = Self.defaultSessionLabel(for: location)
        let reportsURL = reportsURL
        let portableImportReceiptsEnabled = portableImportReceiptsEnabled

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
                    volumeName: sourceVolume?.name ?? URL(fileURLWithPath: cardPath).lastPathComponent,
                    volumeUUID: sourceVolume?.volumeUUID,
                    location: location,
                    roots: DestinationRoots(
                        photosURL: URL(fileURLWithPath: photosPath, isDirectory: true),
                        videosURL: URL(fileURLWithPath: videosPath, isDirectory: true)
                    ),
                    reportsDirectoryURL: reportsURL,
                    portableReceiptsEnabled: portableImportReceiptsEnabled
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
                    if let warning = summary.portableReceiptWarning {
                        self.statusMessage = "Scan complete. \(warning)"
                    } else if let portableKnownFiles = summary.portableKnownFiles, portableKnownFiles > 0 {
                        self.statusMessage = "Scan complete. \(portableKnownFiles) files were imported on another Mac"
                    } else {
                        self.statusMessage = "Scan complete"
                    }
                    self.isWorking = false
                    self.transitionImportWorkspace(.scanSucceeded)
                    self.importTask = nil
                }
                importLogger.info(
                    "Scan complete scanned=\(summary.scannedFiles, privacy: .public) new=\(summary.newFiles, privacy: .public) known=\(summary.knownFiles, privacy: .public) sidecars=\(summary.unsupportedFiles, privacy: .public) conflicts=\(summary.conflictFiles, privacy: .public)"
                )
            } catch is CancellationError {
                await MainActor.run {
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    self.statusMessage = "Scan cancelled"
                    self.isWorking = false
                    self.transitionImportWorkspace(.cancelled)
                    self.importTask = nil
                }
                importLogger.notice("Scan cancelled")
            } catch SDImportError.cancelled {
                await MainActor.run {
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    self.statusMessage = "Scan cancelled"
                    self.isWorking = false
                    self.transitionImportWorkspace(.cancelled)
                    self.importTask = nil
                }
                importLogger.notice("Scan cancelled")
            } catch {
                await MainActor.run {
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    let message = "Scan failed: \(Self.errorMessage(for: error))"
                    self.statusMessage = message
                    self.isWorking = false
                    self.transitionImportWorkspace(.failed(operation: .scan, message: message))
                    self.importTask = nil
                }
                importLogger.error("Scan failed errorType=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func useImportMediaSelection(_ selection: ImportMediaSelection) {
        rememberCurrentMixedDestinationLayout()
        importMediaSelection = selection
        switch selection {
        case .photosAndVideos:
            destinationLayout = preferredMixedDestinationLayout
        case .photosOnly:
            destinationLayout = .separateMediaFolders
        case .videosOnly:
            destinationLayout = .footageBackup
        }
        applyCurrentImportOptions(userInitiated: true)
    }

    func useDestinationLayout(_ layout: ImportDestinationLayout) {
        guard importMediaSelection == .photosAndVideos else {
            return
        }
        destinationLayout = layout == .footageBackup ? .singleLibrary : layout
        preferredMixedDestinationLayout = destinationLayout
        applyCurrentImportOptions(userInitiated: true)
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

    func folderGroupingDidChange() {
        rebuildPreviewPlanCache()
    }

    func themePreferenceDidChange() {
        savePreferences()
    }

    func applyWorkflowProfile(_ profile: ImportWorkflowProfile, userInitiated: Bool = true) {
        workflowProfile = profile
        importMediaSelection = profile.mediaSelection
        destinationLayout = profile.mediaSelection == .photosAndVideos
            ? preferredMixedDestinationLayout
            : ImportDestinationLayout(organizationPreset: profile.organizationPreset)
        organizationPreset = destinationLayout.organizationPreset
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
    }

    private func applyCurrentImportOptions(userInitiated: Bool) {
        normalizeDestinationForCurrentImportType()
        updateWorkflowProfileForCurrentOptions()

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
    }

    private func normalizeDestinationForCurrentImportType() {
        switch importMediaSelection {
        case .photosAndVideos:
            if destinationLayout == .footageBackup {
                destinationLayout = preferredMixedDestinationLayout
            }
            rememberCurrentMixedDestinationLayout()
            organizationPreset = destinationLayout.organizationPreset
        case .photosOnly:
            destinationLayout = .separateMediaFolders
            organizationPreset = .classicDatedFolders
        case .videosOnly:
            destinationLayout = .footageBackup
            organizationPreset = .footageBackup
        }
    }

    private func rememberCurrentMixedDestinationLayout() {
        guard importMediaSelection == .photosAndVideos, destinationLayout != .footageBackup else {
            return
        }
        preferredMixedDestinationLayout = destinationLayout
    }

    private func updateWorkflowProfileForCurrentOptions() {
        if let matchedProfile = ImportWorkflowProfile.matching(
            mediaSelection: importMediaSelection,
            organizationPreset: organizationPreset
        ) {
            workflowProfile = matchedProfile
            return
        }

        switch importMediaSelection {
        case .photosAndVideos:
            workflowProfile = .mixedShootSession
        case .photosOnly:
            workflowProfile = .photoImport
        case .videosOnly:
            workflowProfile = .footageBackup
        }
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
        buildPreviewRows(files: currentPreviewFiles, sessions: previewSessions)
    }

    private func buildPreviewRows(
        files: [JobFileRecord],
        sessions: [ImportPreviewSession]
    ) -> [ImportPreviewRow] {
        let plans = buildImportPlans(files: files, sessions: sessions)
        return makePreviewRows(files: files, plans: plans)
    }

    private func buildImportPlans(
        files: [JobFileRecord],
        sessions: [ImportPreviewSession]
    ) -> [ImportFilePlan] {
        guard let currentSummary else {
            return []
        }

        let builder = ImportPlanBuilder(
            sessions: sessions,
            mediaSelection: importMediaSelection,
            organizationPreset: organizationPreset,
            folderGrouping: folderGrouping,
            roots: DestinationRoots(
                photosURL: URL(
                    fileURLWithPath: resolvedPath(photosPath, validation: photosValidation),
                    isDirectory: true
                ),
                videosURL: URL(
                    fileURLWithPath: resolvedPath(videosPath, validation: videosValidation),
                    isDirectory: true
                )
            ),
            fallbackLocation: Self.defaultSessionLabel(for: location),
            volumeName: currentSummary.volumeName
        )
        return builder.plans(files: files)
    }

    private func makePreviewRows(
        files: [JobFileRecord],
        plans: [ImportFilePlan]
    ) -> [ImportPreviewRow] {
        var visualGroups: [Int64: (id: String, kind: ImportPreviewGroupKind)] = [:]
        for group in PhotoPairDetector().groups(files: files) where group.isPair {
            for file in group.rawFiles + group.jpegFiles {
                if let id = file.id {
                    visualGroups[id] = (group.id, .rawJPEG)
                }
            }
        }
        for group in SidecarAssociator().associate(files: files).groups {
            for file in [group.video] + group.sidecars {
                if let id = file.id {
                    visualGroups[id] = (group.id, .videoSidecars)
                }
            }
        }

        return zip(files, plans).compactMap { pair -> ImportPreviewRow? in
            let (file, plan) = pair
            guard let id = file.id else {
                return nil
            }
            return ImportPreviewRow(
                id: id,
                filename: file.filename,
                date: ImportPlanBuilder.sessionDate(for: file),
                modificationDateString: file.modificationDateString,
                mediaKind: file.mediaKind,
                sourcePath: file.sourcePath,
                destinationPath: plan.destinationPath,
                disposition: plan.disposition,
                visualGroupID: visualGroups[id]?.id,
                visualGroupKind: visualGroups[id]?.kind,
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
                let rootAndRelativePath = previewDestinationRoot(for: path, rows: rows)
                return ImportPreviewDestination(
                    path: path,
                    root: rootAndRelativePath.root,
                    relativePath: rootAndRelativePath.relativePath,
                    fileCount: rows.count,
                    byteCount: rows.reduce(Int64(0)) { $0 + $1.size }
                )
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func previewDestinationRoot(
        for destinationPath: String,
        rows: [ImportPreviewRow]
    ) -> (root: ImportPreviewDestination.Root, relativePath: String) {
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
        let photosRoot = URL(
            fileURLWithPath: resolvedPath(photosPath, validation: photosValidation),
            isDirectory: true
        ).standardizedFileURL
        let videosRoot = URL(
            fileURLWithPath: resolvedPath(videosPath, validation: videosValidation),
            isDirectory: true
        ).standardizedFileURL

        if destinationLayout == .singleLibrary, isDescendant(destination, of: photosRoot) {
            return (.library, relativePath(from: photosRoot, to: destination))
        }
        if photosRoot == videosRoot, isDescendant(destination, of: photosRoot) {
            let containsFootage = rows.contains {
                $0.mediaKind == .video || $0.visualGroupKind == .videoSidecars
            }
            return (
                containsFootage ? .videos : .photos,
                relativePath(from: photosRoot, to: destination)
            )
        }
        if isDescendant(destination, of: photosRoot) {
            return (.photos, relativePath(from: photosRoot, to: destination))
        }
        if isDescendant(destination, of: videosRoot) {
            return (.videos, relativePath(from: videosRoot, to: destination))
        }
        return (.other, destination.path)
    }

    private func isDescendant(_ destination: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let destinationComponents = destination.pathComponents
        return destinationComponents.count >= rootComponents.count
            && Array(destinationComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func relativePath(from root: URL, to destination: URL) -> String {
        let components = destination.pathComponents.dropFirst(root.pathComponents.count)
        return components.joined(separator: "/")
    }

    private func buildPreviewSpaceRequirements(rows: [ImportPreviewRow]) -> [ImportPreviewSpaceRequirement] {
        var grouped: [String: (capacity: VolumeCapacity, requiredBytes: Int64)] = [:]
        var unknownRequirements: [ImportPreviewSpaceRequirement] = []
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
            let requiredBytes = directoryRows.reduce(Int64(0)) { $0 + $1.size }
            do {
                guard let capacity = try DestinationSpaceChecker.fileSystemCapacity(for: destinationDirectory) else {
                    unknownRequirements.append(
                        ImportPreviewSpaceRequirement(
                            volumeID: "unknown:\(destinationDirectory)",
                            displayPath: destinationDirectory,
                            requiredBytes: requiredBytes,
                            availableBytes: nil,
                            totalBytes: nil
                        )
                    )
                    continue
                }

                let existing = grouped[capacity.volumeID]
                grouped[capacity.volumeID] = (
                    capacity: existing?.capacity ?? capacity,
                    requiredBytes: (existing?.requiredBytes ?? 0) + requiredBytes
                )
            } catch {
                unknownRequirements.append(
                    ImportPreviewSpaceRequirement(
                        volumeID: "unknown:\(destinationDirectory)",
                        displayPath: destinationDirectory,
                        requiredBytes: requiredBytes,
                        availableBytes: nil,
                        totalBytes: nil
                    )
                )
            }
        }

        let knownRequirements = grouped.values
            .map { item in
                ImportPreviewSpaceRequirement(
                    volumeID: item.capacity.volumeID,
                    displayPath: item.capacity.displayPath,
                    requiredBytes: item.requiredBytes,
                    availableBytes: item.capacity.availableBytes,
                    totalBytes: item.capacity.totalBytes
                )
            }
        return (knownRequirements + unknownRequirements)
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
    }

    private func isKnownImportedFile(_ row: ImportPreviewRow) -> Bool {
        knownImportedPreviewFileIDs.contains(row.id)
    }

    func importCurrentJob() {
        guard !isWorking, !isEjectingSource else {
            statusMessage = "Finish the current scan or import first"
            return
        }
        guard purchaseManager.canStartImport else {
            purchaseManager.isShowingPurchase = true
            statusMessage = "Unlock unlimited imports to continue"
            return
        }
        guard let currentSummary else {
            statusMessage = "No scanned job selected"
            return
        }
        guard ensureRequiredDestinationAccessForImport() else {
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
            statusMessage = failure.isKnown
                ? "Not enough space in \(failure.displayPath)"
                : "Could not check available space in \(failure.displayPath)"
            return
        }

        let sessions = previewSessions
        let organizationPreset = organizationPreset
        let folderGrouping = folderGrouping
        let roots = DestinationRoots(
            photosURL: URL(
                fileURLWithPath: resolvedPath(photosPath, validation: photosValidation),
                isDirectory: true
            ),
            videosURL: URL(
                fileURLWithPath: resolvedPath(videosPath, validation: videosValidation),
                isDirectory: true
            )
        )
        let fallbackLocation = Self.defaultSessionLabel(for: location)
        let volumeName = currentSummary.volumeName
        let mediaSelection = importMediaSelection
        let portableImportReceiptsEnabled = portableImportReceiptsEnabled

        savePreferences()

        startImport(
            jobID: jobID,
            databaseURL: databaseURL,
            portableImportReceiptsEnabled: portableImportReceiptsEnabled,
            retryContext: .currentReview,
            planMode: .rebuild(
                ImportPlanBuilder(
                    sessions: sessions,
                    mediaSelection: mediaSelection,
                    organizationPreset: organizationPreset,
                    folderGrouping: folderGrouping,
                    roots: roots,
                    fallbackLocation: fallbackLocation,
                    volumeName: volumeName
                )
            )
        )
    }

    func importPortableKnownFilesAnyway() {
        guard !isWorking, !isEjectingSource else {
            statusMessage = "Finish the current scan or import first"
            return
        }
        guard let jobID = currentSummary?.jobID, let databaseURL else {
            statusMessage = "No scanned job selected"
            return
        }

        let portableOverrideIDs = Set(
            previewRows.compactMap { row in
                if case .known(.portableLedger) = row.disposition {
                    return row.id
                }
                return nil
            }
        )
        let updates = currentPreviewFiles.compactMap { file -> JobFilePlanUpdate? in
            guard
                file.knownSource == .portableLedger,
                let id = file.id,
                portableOverrideIDs.contains(id)
            else {
                return nil
            }
            return JobFilePlanUpdate(
                id: id,
                decision: .new,
                destinationDirectory: nil,
                plannedDestinationPath: nil,
                copyStatus: .pending,
                error: nil,
                portableReceiptOverride: true
            )
        }
        guard !updates.isEmpty else {
            return
        }

        isWorking = true
        activeImportRetryContext = .portableReceiptOverride
        failedImportRetryContext = nil
        transitionImportWorkspace(.beginPreparation(.portableReceiptOverride))
        statusMessage = "Preparing files imported on another Mac..."
        importTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                try Task.checkCancellation()
                try repositories.jobRepository.updateJobFileImportPlan(jobID: jobID, updates: updates)
                try Task.checkCancellation()
                let files = try repositories.jobRepository.fetchJobFiles(jobID: jobID)
                let jobs = try repositories.jobRepository.listImportHistoryJobs(limit: 100)
                try Task.checkCancellation()

                await MainActor.run {
                    guard !Task.isCancelled else {
                        self.isWorking = false
                        self.activeImportRetryContext = nil
                        self.transitionImportWorkspace(.cancelled)
                        self.importTask = nil
                        return
                    }
                    self.currentPreviewFiles = files
                    self.selectedJobFiles = files
                    self.jobs = jobs
                    self.rebuildPreviewPlanCache()
                    self.statusMessage = "Portable receipt overridden for \(updates.count) files"
                    self.isWorking = false
                    self.activeImportRetryContext = nil
                    self.transitionImportWorkspace(.scanSucceeded)
                    self.importTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isWorking = false
                    self.activeImportRetryContext = nil
                    self.transitionImportWorkspace(.cancelled)
                    self.importTask = nil
                }
            } catch {
                await MainActor.run {
                    let message = "Could not override portable history: \(Self.errorMessage(for: error))"
                    self.statusMessage = message
                    self.isWorking = false
                    self.failedImportRetryContext = self.activeImportRetryContext
                    self.activeImportRetryContext = nil
                    self.transitionImportWorkspace(
                        .failed(operation: .portableReceiptOverride, message: message)
                    )
                    self.importTask = nil
                }
            }
        }
    }

    private func startImport(
        jobID: String,
        databaseURL: URL,
        portableImportReceiptsEnabled: Bool? = nil,
        retryContext: ImportRetryContext,
        planMode: ImportPlanMode
    ) {
        isWorking = true
        activeImportRetryContext = retryContext
        failedImportRetryContext = nil
        transitionImportWorkspace(.beginPreparation(.prepareImport))
        currentResult = nil
        importProgress = nil
        ejectedSourceJobID = nil
        ejectedSourceName = nil
        ejectedSourceVolumeCount = 0
        statusMessage = "Preparing import..."
        importLogger.info("Import started jobID=\(jobID, privacy: .private)")
        let portableImportReceiptsEnabled = portableImportReceiptsEnabled
            ?? self.portableImportReceiptsEnabled

        importTask = Task.detached(priority: .userInitiated) {
            do {
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                let filesForPlan = try repositories.jobRepository.fetchJobFiles(jobID: jobID)
                let updates = planMode.updates(files: filesForPlan)
                if let destinationRoots = planMode.destinationRoots {
                    try repositories.jobRepository.updateJobImportPlan(
                        jobID: jobID,
                        destinationRoots: destinationRoots,
                        updates: updates
                    )
                } else if !updates.isEmpty {
                    try repositories.jobRepository.updateJobFileImportPlan(jobID: jobID, updates: updates)
                }

                let engine = ImportEngine(
                    jobRepository: repositories.jobRepository,
                    dedupeRepository: repositories.dedupeRepository,
                    portableReceiptsEnabled: portableImportReceiptsEnabled
                )
                var lastPublishedAt = Date(timeIntervalSince1970: 0)
                let minimumUpdateInterval: TimeInterval = 0.75

                let result = try engine.importFiles(
                    jobID: jobID,
                    onProgress: { progress in
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
                            self.transitionImportWorkspace(.beginCopy)
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
                    self.purchaseManager.recordSuccessfulImport(result)
                    self.importProgress = nil
                    self.jobs = jobs
                    self.selectedJobID = jobID
                    self.selectedJobFiles = files
                    if self.currentSummary?.jobID == jobID {
                        self.currentPreviewFiles = files
                    } else {
                        self.rebuildPreviewPlanCache()
                    }
                    self.statusMessage = result.portableReceiptWarning.map {
                        "Import finished. \($0)"
                    } ?? "Import finished"
                    self.isWorking = false
                    self.activeImportRetryContext = nil
                    self.transitionImportWorkspace(.completed)
                    self.importTask = nil
                    if self.ejectAfterSuccessfulImport, self.canEjectSource(for: result) {
                        self.ejectSource(for: result)
                    }
                }
                importLogger.info(
                    "Import finished imported=\(result.importedFiles, privacy: .public) skipped=\(result.skippedFiles, privacy: .public) failed=\(result.failedFiles, privacy: .public)"
                )
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
                    self.activeImportRetryContext = nil
                    self.transitionImportWorkspace(.cancelled)
                    self.importTask = nil
                }
                importLogger.notice("Import cancelled jobID=\(jobID, privacy: .private)")
            } catch {
                await MainActor.run {
                    self.currentResult = nil
                    self.importProgress = nil
                    let message = "Import failed: \(Self.errorMessage(for: error))"
                    let failedOperation = self.activeImportOperation ?? .copy
                    self.statusMessage = message
                    self.isWorking = false
                    self.failedImportRetryContext = self.activeImportRetryContext
                    self.activeImportRetryContext = nil
                    self.transitionImportWorkspace(
                        .failed(operation: failedOperation, message: message)
                    )
                    self.importTask = nil
                }
                importLogger.error("Import failed errorType=\(String(describing: type(of: error)), privacy: .public)")
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

    private func transitionImportWorkspace(_ event: ImportWorkspaceEvent) {
        let next = ImportWorkspaceTransition.applying(
            event,
            to: ImportWorkspaceSnapshot(
                phase: importUIPhase,
                activeOperation: activeImportOperation,
                failure: importFailure
            )
        )
        importUIPhase = next.phase
        activeImportOperation = next.activeOperation
        importFailure = next.failure
    }

    func recoverImportWorkspace() {
        failedImportRetryContext = nil
        transitionImportWorkspace(.recover(hasScannedJob: currentSummary != nil))
        statusMessage = currentSummary == nil ? "Ready" : "Review import"
    }

    func recoverImportReceipt() {
        guard currentResult != nil else {
            recoverImportWorkspace()
            return
        }
        failedImportRetryContext = nil
        transitionImportWorkspace(.recoverCompleted)
        statusMessage = "Import finished"
    }

    func retryFailedImportOperation() {
        let operation = importFailure?.operation
        let retryContext = failedImportRetryContext
        failedImportRetryContext = nil
        switch retryContext {
        case .currentReview:
            transitionImportWorkspace(.recover(hasScannedJob: true))
            importCurrentJob()
            return
        case .existingJob(let jobID):
            guard let databaseURL else {
                statusMessage = "Database is not ready"
                return
            }
            selectedJobID = jobID
            transitionImportWorkspace(.recover(hasScannedJob: false))
            startImport(
                jobID: jobID,
                databaseURL: databaseURL,
                retryContext: .existingJob(jobID: jobID),
                planMode: .existing
            )
            return
        case .portableReceiptOverride:
            transitionImportWorkspace(.recover(hasScannedJob: true))
            importPortableKnownFilesAnyway()
            return
        case .eject(let jobID, let target):
            transitionImportWorkspace(
                currentResult == nil
                    ? .recover(hasScannedJob: currentSummary != nil)
                    : .recoverCompleted
            )
            ejectSource(jobID: jobID, target: target)
            return
        case nil:
            break
        }

        switch operation {
        case .scan:
            transitionImportWorkspace(.recover(hasScannedJob: false))
            scan()
        case .prepareImport, .copy:
            recoverImportWorkspace()
        case .portableReceiptOverride:
            transitionImportWorkspace(.recover(hasScannedJob: true))
            importPortableKnownFilesAnyway()
        case .eject:
            recoverImportWorkspace()
        case nil:
            recoverImportWorkspace()
        }
    }

    func importAnotherCard() {
        guard !isWorking, !isEjectingSource else {
            return
        }
        currentSummary = nil
        currentResult = nil
        importProgress = nil
        previewSessions = []
        currentPreviewFiles = []
        knownImportedPreviewFileIDs = []
        clearPreviewPlanCache()
        mediaContentProfile = nil
        photoPairSummary = nil
        activeImportRetryContext = nil
        failedImportRetryContext = nil
        resetImportDraftFromDefaults()
        transitionImportWorkspace(.recover(hasScannedJob: false))
        statusMessage = "Ready for another card"
    }

    func acceptMountedVolumePrompt() {
        guard !isWorking, !isEjectingSource else {
            statusMessage = "Finish the current operation before scanning another card"
            return
        }
        guard let volume = pendingMountedVolume else {
            return
        }
        let sourceURL: URL
        if AppDistribution.current == .macAppStore {
            if let authorizedURL = authorizedSourceURL(for: volume) {
                sourceURL = authorizedURL
            } else {
                guard let selectedURL = FilePanelPresenter.chooseDirectoryURL(
                    title: "Allow Access to \(volume.name)",
                    initialPath: volume.mountURL.path,
                    prompt: "Allow Access",
                    message: "\(AppDistribution.current.displayName) will scan this folder only after you allow access."
                ) else {
                    pendingMountedVolume = nil
                    statusMessage = "Card scan cancelled"
                    return
                }
                guard Self.isSameOrDescendant(selectedURL, of: volume.mountURL) else {
                    statusMessage = "Choose \(volume.name) or a folder on that card"
                    return
                }
                guard retainSelectedFolderAccess(
                    .source,
                    url: selectedURL,
                    persistBookmark: true
                ) else {
                    pendingMountedVolume = nil
                    return
                }
                sourceURL = selectedURL
            }
        } else {
            sourceURL = volume.mountURL
        }

        pendingMountedVolume = nil
        selection = .import
        cardPath = sourceURL.path
        // The helper can deliver a mount before /Volumes enumeration catches up.
        // Refresh after authorization so source ejection is available on the
        // first source and review screens without requiring a manual refresh.
        refreshAvailableSourceVolumes()
        sourcePathDidChange()
        savePreferences()
        scan()
    }

    func skipMountedVolumePrompt() {
        pendingMountedVolume = nil
        statusMessage = "Ready"
    }

    @discardableResult
    func setAutoPromptEnabled(_ enabled: Bool) -> Bool {
        refreshBackgroundPromptHealth()
        guard backgroundPromptCanConfigure else {
            statusMessage = backgroundPromptStatusDetail
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
            return false
        }
        let previousValue = autoPromptEnabled
        autoPromptEnabled = enabled
        let saved = savePreferences(persistAutoPromptPreference: true)
        guard saved else {
            autoPromptEnabled = previousValue
            defaults.set(previousValue, forKey: DefaultsKeys.autoPromptEnabled)
            return false
        }

        enqueueBackgroundPromptOperation { model in
            await model.performAutoPromptPreferenceChange(enabled)
        }
        return true
    }

    private func performAutoPromptPreferenceChange(_ enabled: Bool) async {
        invalidateBackgroundPromptHealthRefresh()
        LoginItemController.invalidateApplicationOwnershipCache()
        backgroundPromptLastError = nil
        backgroundPromptLastErrorSequence = nil
        do {
            try authorizeCurrentBackgroundPromptHelperIfNeeded()
            if enabled {
                let statusBeforeEnable = LoginItemController.status
                if statusBeforeEnable == .notFound || statusBeforeEnable == .notRegistered {
                    recordNotFoundRepairAttempt()
                }
                recordBackgroundPromptRegistrationAttempt()
            }
            try await LoginItemController.setEnabled(enabled)
            refreshBackgroundPromptHealth()
            if enabled, backgroundPromptServiceStatus == .enabled {
                recordCurrentRepairIdentity()
                clearNotFoundRepairAttempt()
            } else if !enabled {
                cancelBackgroundPromptRetry(resetAttempts: true)
            }
            if enabled, backgroundPromptServiceStatus == .enabled {
                scheduleBackgroundPromptHealthRefresh()
            } else if enabled,
                      backgroundPromptServiceStatus == .notFound
                        || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            }
            if enabled, backgroundPromptNeedsAttention {
                statusMessage = backgroundPromptStatusDetail
                settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
            } else {
                statusMessage = enabled ? "Background prompt enabled" : "Background prompt disabled"
                settingsFeedback = SettingsFeedback(message: statusMessage, role: .information)
            }
        } catch {
            refreshBackgroundPromptHealth()
            recordBackgroundPromptError(Self.errorMessage(for: error))
            if enabled,
               backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            }
            statusMessage = "Could not update background prompt: \(error)"
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
        }
    }

    func updateLoginItemRegistration() {
        reconcileBackgroundPromptRegistration(showFeedback: true)
    }

    func applicationDidBecomeActive() {
        LoginItemController.invalidateApplicationOwnershipCache()
        refreshAutoPromptPreferenceFromSharedStore()
        mountObserver?.consumePendingHandoffs()
        reconcileBackgroundPromptRegistration()
    }

    func mainWindowWillPresent() {
        refreshAutoPromptPreferenceFromSharedStore()
        mountObserver?.consumePendingHandoffs()
        reconcileBackgroundPromptRegistration()
    }

    func mainWindowDidAppear() {
        mountObserver?.consumePendingHandoffs()
    }

    func repairBackgroundPrompt() {
        enqueueBackgroundPromptOperation { model in
            await model.performBackgroundPromptRepair()
        }
    }

    func openBackgroundPromptSystemSettings() {
        LoginItemController.openSystemSettings()
    }

    func openBackgroundPromptOwner() {
        LoginItemController.openAuthoritativeApplication()
    }

    var backgroundPromptCanConfigure: Bool {
        backgroundPromptApplicationOwnership.isCurrentApplicationAuthoritative
    }

    var backgroundPromptStatusTitle: String {
        guard backgroundPromptCanConfigure else {
            return backgroundPromptApplicationOwnership.authoritativeApplicationPath == nil
                ? "Install required"
                : "Managed by installed copy"
        }
        guard autoPromptEnabled else {
            return "Off"
        }
        if backgroundPromptEffectiveError != nil {
            return "Needs attention"
        }
        switch backgroundPromptServiceStatus {
        case .enabled:
            return backgroundPromptAgentMismatch ? "Helper update needed" : "Running"
        case .notRegistered:
            return "Not registered"
        case .requiresApproval:
            return "Needs approval"
        case .notFound:
            return "Helper missing"
        case .unknown:
            return "Unavailable"
        }
    }

    var backgroundPromptStatusDetail: String {
        guard backgroundPromptCanConfigure else {
            if let path = backgroundPromptApplicationOwnership.authoritativeApplicationPath {
                return "Background prompts are managed by the installed copy at \(path). Open that copy to change this setting."
            }
            return "Move \(AppDistribution.current.displayName) to /Applications or ~/Applications before enabling background prompts."
        }
        if let backgroundPromptEffectiveError {
            return backgroundPromptEffectiveError
        }
        guard autoPromptEnabled else {
            return "The background helper is disabled."
        }
        switch backgroundPromptServiceStatus {
        case .enabled:
            if backgroundPromptAgentMismatch {
                return "The running helper does not match this app build. Repair it before relying on automatic prompts."
            }
            return "The background helper is registered with macOS."
        case .notRegistered:
            return "The saved setting is on, but the background helper is not registered."
        case .requiresApproval:
            return "Allow \(AppDistribution.current.displayName) in System Settings → General → Login Items & Extensions."
        case .notFound:
            return "The bundled background helper could not be found. Reinstall \(AppDistribution.current.displayName) in Applications."
        case .unknown:
            return "macOS returned an unrecognized background helper status."
        }
    }

    var backgroundPromptNeedsAttention: Bool {
        !backgroundPromptCanConfigure
            || (autoPromptEnabled
            && (backgroundPromptServiceStatus != .enabled
                || backgroundPromptAgentMismatch
                || backgroundPromptEffectiveError != nil))
    }

    var backgroundPromptCanRepair: Bool {
        backgroundPromptCanConfigure
            && autoPromptEnabled
            && backgroundPromptServiceStatus != .requiresApproval
    }

    private var backgroundPromptAgentMismatch: Bool {
        BackgroundPromptRegistrationPolicy.agentMismatch(
            state: backgroundPromptAgentState,
            expectedIdentity: currentRepairIdentity,
            lastRepairIdentity: lastRepairIdentity
        )
    }

    private var backgroundPromptEffectiveError: String? {
        BackgroundPromptHealth.effectiveError(
            appError: backgroundPromptLastError,
            agentState: backgroundPromptAgentState
        )
    }

    private var currentAppBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    private var expectedEmbeddedAgentPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent("SDImportAgent.app", isDirectory: true)
            .standardizedFileURL.path
    }

    private var currentRepairIdentity: BackgroundPromptRepairIdentity {
        BackgroundPromptRepairIdentity(
            appBuild: currentAppBuild,
            applicationPath: Bundle.main.bundleURL.path,
            agentBundlePath: expectedEmbeddedAgentPath
        )
    }

    private var lastRepairIdentity: BackgroundPromptRepairIdentity? {
        guard let data = defaults.data(forKey: DefaultsKeys.lastLoginItemRepairIdentity) else {
            return nil
        }
        return try? JSONDecoder().decode(BackgroundPromptRepairIdentity.self, from: data)
    }

    private var lastNotFoundRepairAttemptAt: Date? {
        let interval = defaults.double(forKey: DefaultsKeys.lastNotFoundRepairAttemptAt)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    private var lastHealthRepairAttemptAt: Date? {
        let interval = defaults.double(forKey: DefaultsKeys.lastHealthRepairAttemptAt)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    private var minimumBackgroundPromptAgentLaunchAt: Date? {
        let interval = defaults.double(forKey: DefaultsKeys.minimumBackgroundPromptAgentLaunchAt)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    private func recordNotFoundRepairAttempt() {
        defaults.set(Date().timeIntervalSince1970, forKey: DefaultsKeys.lastNotFoundRepairAttemptAt)
    }

    private func clearNotFoundRepairAttempt() {
        defaults.removeObject(forKey: DefaultsKeys.lastNotFoundRepairAttemptAt)
    }

    private func recordHealthRepairAttempt() {
        defaults.set(Date().timeIntervalSince1970, forKey: DefaultsKeys.lastHealthRepairAttemptAt)
    }

    private func clearHealthRepairAttempt() {
        defaults.removeObject(forKey: DefaultsKeys.lastHealthRepairAttemptAt)
    }

    private func recordBackgroundPromptRegistrationAttempt() {
        defaults.set(
            Date().timeIntervalSince1970,
            forKey: DefaultsKeys.minimumBackgroundPromptAgentLaunchAt
        )
    }

    private func recordCurrentRepairIdentity() {
        guard let data = try? JSONEncoder().encode(currentRepairIdentity) else {
            return
        }
        defaults.set(data, forKey: DefaultsKeys.lastLoginItemRepairIdentity)
        LoginItemController.invalidateApplicationOwnershipCache()
    }

    private func reconcileBackgroundPromptRegistration(showFeedback: Bool = false) {
#if DEBUG
        guard BackgroundPromptRuntimeQA.permitsRegistrationReconciliation(
            helperLifecycleIsActive: BackgroundPromptRuntimeQA.helperLifecycleIsActive()
        ) else {
            return
        }
#endif
        enqueueBackgroundPromptOperation { model in
            await model.performBackgroundPromptReconciliation(showFeedback: showFeedback)
        }
    }

    private func scheduleRegistrationRetry() {
        guard
            autoPromptEnabled,
            hasCompletedOnboarding,
            backgroundPromptCanConfigure,
            backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered
        else {
            return
        }
        let delay = BackgroundPromptRetryPolicy.remainingDelay(
            lastAttemptAt: lastNotFoundRepairAttemptAt
        )
        backgroundPromptRetryScheduler.schedule(after: delay) { [weak self] in
            self?.reconcileBackgroundPromptRegistration()
        }
    }

    private func scheduleMissingHelperHealthRepair() {
        guard
            autoPromptEnabled,
            hasCompletedOnboarding,
            backgroundPromptCanConfigure,
            backgroundPromptServiceStatus == .enabled,
            !currentlyOwnsBackgroundPromptRegistration()
        else {
            return
        }
        let delay = BackgroundPromptRetryPolicy.remainingDelay(
            lastAttemptAt: lastHealthRepairAttemptAt
        )
        backgroundPromptRetryScheduler.schedule(after: delay) { [weak self] in
            guard let self else {
                return
            }
            self.enqueueBackgroundPromptOperation { model in
                await model.performScheduledMissingHelperHealthRepair()
            }
        }
    }

    private func cancelBackgroundPromptRetry(resetAttempts: Bool) {
        backgroundPromptRetryScheduler.cancel()
        if resetAttempts {
            clearNotFoundRepairAttempt()
            clearHealthRepairAttempt()
        }
    }

    private func performScheduledMissingHelperHealthRepair() async {
        refreshBackgroundPromptHealth()
        let ownsRegistration = currentlyOwnsBackgroundPromptRegistration()
        guard BackgroundPromptScheduledRepairPolicy.shouldRunMissingHelperRepair(
            desiredEnabled: autoPromptEnabled,
            hasCompletedOnboarding: hasCompletedOnboarding,
            canConfigure: backgroundPromptCanConfigure,
            serviceStatus: backgroundPromptServiceStatus,
            ownsRegistration: ownsRegistration
        ) else {
            if autoPromptEnabled,
               backgroundPromptCanConfigure,
               (backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered) {
                scheduleRegistrationRetry()
            } else {
                cancelBackgroundPromptRetry(
                    resetAttempts: !autoPromptEnabled || !backgroundPromptCanConfigure || ownsRegistration
                )
            }
            return
        }
        recordHealthRepairAttempt()
        await performBackgroundPromptRepair(requireDesiredEnabled: true)
    }

    private func performBackgroundPromptRepair(requireDesiredEnabled: Bool = false) async {
        invalidateBackgroundPromptHealthRefresh()
        LoginItemController.invalidateApplicationOwnershipCache()
        refreshBackgroundPromptHealth()
        guard backgroundPromptCanConfigure else {
            cancelBackgroundPromptRetry(resetAttempts: true)
            statusMessage = backgroundPromptStatusDetail
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
            return
        }
        backgroundPromptLastError = nil
        backgroundPromptLastErrorSequence = nil
        do {
            try authorizeCurrentBackgroundPromptHelperIfNeeded()
            recordNotFoundRepairAttempt()
            recordBackgroundPromptRegistrationAttempt()
            backgroundPromptServiceStatus = try await LoginItemController.repair { [weak self] in
                guard requireDesiredEnabled else {
                    return true
                }
                guard let self else {
                    return false
                }
                return BackgroundPromptScheduledRepairPolicy.canContinueRegistration(
                    desiredEnabled: self.autoPromptEnabled,
                    hasCompletedOnboarding: self.hasCompletedOnboarding,
                    currentApplicationIsAuthoritative: LoginItemController
                        .applicationOwnership
                        .isCurrentApplicationAuthoritative
                )
            }
            if backgroundPromptServiceStatus == .enabled {
                recordCurrentRepairIdentity()
                clearNotFoundRepairAttempt()
            }
            refreshBackgroundPromptHealth()
            if backgroundPromptServiceStatus == .enabled {
                scheduleBackgroundPromptHealthRefresh()
            } else if backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            }
            statusMessage = backgroundPromptServiceStatus == .enabled
                ? "Background prompt repaired"
                : backgroundPromptStatusDetail
            settingsFeedback = SettingsFeedback(
                message: statusMessage,
                role: backgroundPromptServiceStatus == .enabled ? .information : .error
            )
        } catch {
            recordBackgroundPromptError(Self.errorMessage(for: error))
            refreshBackgroundPromptHealth()
            if backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            }
            statusMessage = "Could not repair background prompt: \(Self.errorMessage(for: error))"
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
        }
    }

    private func performBackgroundPromptReconciliation(showFeedback: Bool) async {
        invalidateBackgroundPromptHealthRefresh()
        refreshBackgroundPromptHealth()
        guard hasCompletedOnboarding else {
            cancelBackgroundPromptRetry(resetAttempts: false)
            return
        }
        guard backgroundPromptCanConfigure else {
            cancelBackgroundPromptRetry(resetAttempts: true)
            if showFeedback {
                statusMessage = backgroundPromptStatusDetail
                settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
            }
            return
        }

        do {
            try authorizeCurrentBackgroundPromptHelperIfNeeded()
            if shouldRefreshMismatchedBackgroundHelper {
                if backgroundPromptServiceStatus == .notFound
                    || backgroundPromptServiceStatus == .notRegistered {
                    recordNotFoundRepairAttempt()
                }
                recordBackgroundPromptRegistrationAttempt()
                backgroundPromptServiceStatus = try await LoginItemController.repair()
                if backgroundPromptServiceStatus == .enabled {
                    recordCurrentRepairIdentity()
                    clearNotFoundRepairAttempt()
                }
            } else {
                let statusBeforeReconciliation = backgroundPromptServiceStatus
                let allowRegistrationAttempt = BackgroundPromptRegistrationPolicy
                    .allowsNotFoundRegistration(lastAttemptAt: lastNotFoundRepairAttemptAt)
                let willAttemptRegistration = BackgroundPromptRegistrationPolicy
                    .shouldAttemptMissingRegistration(
                        desiredEnabled: autoPromptEnabled,
                        serviceStatus: statusBeforeReconciliation,
                        lastAttemptAt: lastNotFoundRepairAttemptAt
                    )
                let registrationIsMissing = statusBeforeReconciliation == .notRegistered
                    || statusBeforeReconciliation == .notFound
                if willAttemptRegistration {
                    recordNotFoundRepairAttempt()
                    recordBackgroundPromptRegistrationAttempt()
                }
                backgroundPromptServiceStatus = try await LoginItemController.reconcile(
                    desiredEnabled: autoPromptEnabled
                        && (!registrationIsMissing || willAttemptRegistration),
                    allowNotFoundRegistration: allowRegistrationAttempt
                )
                if
                    autoPromptEnabled,
                    statusBeforeReconciliation == .notRegistered,
                    backgroundPromptServiceStatus == .enabled
                {
                    recordCurrentRepairIdentity()
                    clearNotFoundRepairAttempt()
                }
            }
            refreshBackgroundPromptHealth()
            if autoPromptEnabled, backgroundPromptServiceStatus == .enabled {
                scheduleBackgroundPromptHealthRefresh()
            } else if autoPromptEnabled,
                      backgroundPromptServiceStatus == .notFound
                        || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            } else if !autoPromptEnabled {
                cancelBackgroundPromptRetry(resetAttempts: true)
            } else {
                cancelBackgroundPromptRetry(resetAttempts: false)
            }

            if showFeedback {
                statusMessage = backgroundPromptStatusDetail
                settingsFeedback = SettingsFeedback(
                    message: statusMessage,
                    role: backgroundPromptNeedsAttention ? .error : .information
                )
            }
        } catch {
            backgroundPromptServiceStatus = LoginItemController.status
            recordBackgroundPromptError(Self.errorMessage(for: error))
            if backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            } else {
                cancelBackgroundPromptRetry(resetAttempts: false)
            }
            statusMessage = "Could not update background prompt: \(Self.errorMessage(for: error))"
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
        }
    }

    private var shouldRefreshMismatchedBackgroundHelper: Bool {
        BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
            desiredEnabled: autoPromptEnabled,
            serviceStatus: backgroundPromptServiceStatus,
            embeddedHelperExists: LoginItemController.embeddedAgentExists,
            state: backgroundPromptAgentState,
            expectedIdentity: currentRepairIdentity,
            lastRepairIdentity: lastRepairIdentity,
            lastNotFoundRepairAttemptAt: lastNotFoundRepairAttemptAt
        )
    }

    private func enqueueBackgroundPromptOperation(
        _ operation: @escaping @MainActor (AppModel) async -> Void
    ) {
        let precedingOperation = backgroundPromptOperationTask
        backgroundPromptOperationTask = Task { [weak self] in
            _ = await precedingOperation?.result
            guard let self else {
                return
            }
            await operation(self)
        }
    }

    private func recordBackgroundPromptError(
        _ message: String,
        eventSequence: UInt64? = nil
    ) {
        invalidateBackgroundPromptHealthRefresh()
        let sequence: UInt64
        if let eventSequence {
            sequence = eventSequence
        } else {
            do {
                sequence = try BackgroundPromptAgentStateStore.defaultStore()
                    .reserveDiagnosticSequence(
                        agentBuild: currentAppBuild,
                        agentBundlePath: expectedEmbeddedAgentPath
                    )
            } catch {
                let issuedSequence = (try? BackgroundPromptAgentStateStore.defaultStore()
                    .load()?.lastIssuedSequence) ?? 0
                let existingSequence = backgroundPromptLastErrorSequence ?? 0
                let floor = max(issuedSequence, existingSequence)
                sequence = floor < UInt64.max ? floor + 1 : UInt64.max
            }
        }
        guard BackgroundPromptHealth.shouldRecordRuntimeAppError(
            existingSequence: backgroundPromptLastErrorSequence,
            candidateSequence: sequence
        ) else {
            return
        }
        backgroundPromptLastError = message
        backgroundPromptLastErrorSequence = sequence
    }

    private func refreshBackgroundPromptHealth() {
        backgroundPromptApplicationOwnership = LoginItemController.applicationOwnership
        backgroundPromptServiceStatus = LoginItemController.status
        do {
            backgroundPromptAgentState = try BackgroundPromptAgentStateStore.defaultStore().load()
            if BackgroundPromptHealth.shouldPreferAgentError(
                appErrorSequence: backgroundPromptLastErrorSequence,
                agentErrorSequence: backgroundPromptAgentState?.lastErrorSequence
            ) {
                backgroundPromptLastError = nil
                backgroundPromptLastErrorSequence = nil
            }
            backgroundPromptLastError = BackgroundPromptHealth.appErrorAfterRefresh(
                existingError: backgroundPromptLastError,
                agentState: backgroundPromptAgentState
            )
            if backgroundPromptLastError == nil {
                backgroundPromptLastErrorSequence = nil
            }
        } catch {
            backgroundPromptAgentState = nil
            if backgroundPromptLastError == nil {
                recordBackgroundPromptError("Could not read background helper diagnostics")
            }
        }
        if currentlyOwnsBackgroundPromptRegistration() {
            cancelBackgroundPromptRetry(resetAttempts: true)
            mountObserver?.consumePendingHandoffs()
        } else if !backgroundPromptCanConfigure || !autoPromptEnabled {
            cancelBackgroundPromptRetry(resetAttempts: true)
        }
    }

    private func authorizeCurrentBackgroundPromptHelperIfNeeded() throws {
        guard backgroundPromptCanConfigure else {
            return
        }
        try BackgroundPromptAgentStateStore.defaultStore().authorize(
            agentBuild: currentAppBuild,
            agentBundlePath: expectedEmbeddedAgentPath
        )
    }

    private func scheduleBackgroundPromptHealthRefresh() {
        invalidateBackgroundPromptHealthRefresh()
        let generation = backgroundPromptHealthRefreshGeneration.begin()
        backgroundPromptHealthRefreshTask = Task { [weak self] in
            for milliseconds in BackgroundPromptHealth.refreshDelayMilliseconds {
                do {
                    try await Task.sleep(for: .milliseconds(milliseconds))
                } catch {
                    return
                }
                guard
                    let self,
                    self.backgroundPromptHealthRefreshGeneration.isCurrent(generation)
                else {
                    return
                }
                self.refreshBackgroundPromptHealth()
                if self.currentlyOwnsBackgroundPromptRegistration() {
                    return
                }
            }
            guard
                let self,
                self.autoPromptEnabled,
                self.backgroundPromptServiceStatus == .enabled,
                !self.currentlyOwnsBackgroundPromptRegistration(),
                self.backgroundPromptEffectiveError == nil
            else {
                return
            }
            self.recordBackgroundPromptError(
                BackgroundPromptHealth.ownershipTimeoutError(
                    state: self.backgroundPromptAgentState,
                    expectedIdentity: self.currentRepairIdentity
                )
            )
            self.scheduleMissingHelperHealthRepair()
        }
    }

    private func invalidateBackgroundPromptHealthRefresh() {
        backgroundPromptHealthRefreshTask?.cancel()
        backgroundPromptHealthRefreshTask = nil
        backgroundPromptHealthRefreshGeneration.invalidate()
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
        guard !isWorking, !isEjectingSource else {
            statusMessage = "Finish the current scan or import first"
            return
        }
        guard purchaseManager.canStartImport else {
            purchaseManager.isShowingPurchase = true
            statusMessage = "Unlock unlimited imports to continue"
            return
        }
        guard let job = selectedJob(), job.canRetryImport else {
            statusMessage = "Only failed, cancelled, or partial imports can be retried"
            return
        }
        guard ensureAccessForRetryingJob(job) else {
            return
        }
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            return
        }
        selection = .import
        currentSummary = nil
        startImport(
            jobID: selectedJobID,
            databaseURL: databaseURL,
            retryContext: .existingJob(jobID: selectedJobID),
            planMode: .existing
        )
    }

    func saveOnboardingSetup() {
        let previousDefaults = importDefaults
        hasCompletedOnboarding = true
        importDefaults = ImportDefaults(
            photosPath: photosPath,
            videosPath: videosPath,
            shootName: Self.defaultSessionLabel(for: location),
            workflowProfile: workflowProfile,
            mediaSelection: importMediaSelection,
            destinationLayout: destinationLayout,
            preferredMixedDestinationLayout: preferredMixedDestinationLayout,
            folderGrouping: folderGrouping
        )
        guard savePreferences(
            refreshFolderBookmarks: true,
            folderBookmarkPurposes: activeFolderAccessPurposes(),
            persistAutoPromptPreference: true
        ) else {
            hasCompletedOnboarding = false
            importDefaults = previousDefaults
            validateDefaultPaths()
            return
        }
        updateLoginItemRegistration()
        if settingsFeedback == nil {
            statusMessage = "Ready"
        }
        schedulePendingMountHandoffRetry()
    }

    func skipOnboardingSetup() {
        hasCompletedOnboarding = true
        cardPath = initialOnboardingSourcePath
        resetImportDraftFromDefaults()
        autoPromptEnabled = defaults.bool(forKey: DefaultsKeys.autoPromptEnabled)
        guard savePreferences() else {
            hasCompletedOnboarding = false
            return
        }
        updateLoginItemRegistration()
        statusMessage = "Setup skipped. Defaults can be changed in Settings."
        schedulePendingMountHandoffRetry()
    }

    func completeOnboarding() {
        saveOnboardingSetup()
    }

    func revealPhotosFolder() {
        reveal(path: importDefaults.photosPath)
    }

    func revealVideosFolder() {
        reveal(path: importDefaults.videosPath)
    }

    func revealReport(for job: ImportJob) {
        if let path = existingReportPath(for: job) {
            reveal(path: path)
        } else {
            statusMessage = "No report file found"
        }
    }

    func viewReport(for job: ImportJob) {
        guard let databaseURL else {
            reportPresentation = ImportReportPresentation(
                job: job,
                report: nil,
                files: selectedJobID == job.id ? selectedJobFiles : [],
                loadError: "Database is not ready"
            )
            return
        }

        reportTask?.cancel()
        let cachedFiles = selectedJobID == job.id ? selectedJobFiles : []
        let jsonPath = job.summaryJSONPath
        statusMessage = "Loading report..."

        reportTask = Task.detached(priority: .userInitiated) {
            let reportLoader = ImportReportLoader()
            var report: ImportReport?
            var files: [JobFileRecord] = []
            var loadErrors: [String] = []

            if let jsonPath {
                do {
                    report = try reportLoader.loadJSON(from: URL(fileURLWithPath: jsonPath))
                } catch {
                    loadErrors.append("JSON report: \(error)")
                }
            }

            do {
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                files = try repositories.jobRepository.fetchJobFiles(jobID: job.id)
            } catch {
                loadErrors.append("Job files: \(error)")
                files = cachedFiles.isEmpty ? (report?.files ?? []) : cachedFiles
            }

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self.reportPresentation = ImportReportPresentation(
                    job: job,
                    report: report,
                    files: files,
                    loadError: loadErrors.isEmpty ? nil : loadErrors.joined(separator: "\n")
                )
                self.statusMessage = loadErrors.isEmpty ? "Report ready" : "Report opened with warnings"
                self.reportTask = nil
            }
        }
    }

    func openReportFile(for job: ImportJob) {
        guard let path = existingReportPath(for: job) else {
            statusMessage = "No report file found"
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: expanded(path)))
    }

    func reportFileExists(for job: ImportJob) -> Bool {
        existingReportPath(for: job) != nil
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

    func copyDiagnostics() {
        let text = diagnosticsText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        diagnosticsLogger.notice("Diagnostics copied")
        statusMessage = "Diagnostics copied"
    }

    func exportDiagnostics() {
        guard let url = FilePanelPresenter.chooseSaveURL(
            title: "Export Diagnostics",
            suggestedName: "sd-import-diagnostics.md"
        ) else {
            return
        }

        do {
            try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
            diagnosticsLogger.notice("Diagnostics exported")
            statusMessage = "Diagnostics exported"
        } catch {
            diagnosticsLogger.error("Diagnostics export failed errorType=\(String(describing: type(of: error)), privacy: .public)")
            statusMessage = "Could not export diagnostics: \(error)"
        }
    }

    func revealCrashReportsFolder() {
        guard AppDistribution.current.canBrowseSystemCrashReports else {
            statusMessage = "Crash reports remain available in macOS Console"
            return
        }
        let directory = CrashReportLocator.defaultDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            statusMessage = "No crash report folder found"
            return
        }

        NSWorkspace.shared.open(directory)
        diagnosticsLogger.notice("Crash reports folder revealed")
        statusMessage = "Crash reports folder opened"
    }

    func exportLatestCrashReport() {
        guard AppDistribution.current.canBrowseSystemCrashReports else {
            statusMessage = "Crash reports remain available in macOS Console"
            return
        }
        guard let report = CrashReportLocator.findReports(limit: 1).first else {
            statusMessage = "No \(AppDistribution.current.displayName) crash reports found"
            return
        }

        let suggestedName = "sd-import-crash-report.\(report.url.pathExtension.lowercased())"
        guard let url = FilePanelPresenter.chooseSaveURL(
            title: "Export Latest Crash Report",
            suggestedName: suggestedName
        ) else {
            return
        }

        do {
            let data = try Data(contentsOf: report.url)
            try data.write(to: url, options: .atomic)
            diagnosticsLogger.notice("Crash report exported")
            statusMessage = "Crash report exported"
        } catch {
            diagnosticsLogger.error("Crash report export failed errorType=\(String(describing: type(of: error)), privacy: .public)")
            statusMessage = "Could not export crash report: \(error)"
        }
    }

    func pruneHistory(dryRun: Bool) {
        guard let databaseURL else {
            statusMessage = "Database is not ready"
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
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
                statusMessage = "\(summary.matchedJobs) old jobs would be deleted"
            } else {
                statusMessage = "Deleted \(summary.deletedJobs) old jobs"
            }
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .information)
        } catch {
            statusMessage = "Could not prune history: \(error)"
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
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

    func shouldOfferSourceEjection(for result: ImportResult) -> Bool {
        guard AppDistribution.current.supportsSourceEjection else {
            return false
        }
        guard ejectedSourceJobID != result.jobID else {
            return true
        }
        return cachedResultSourceEjectionTargets[result.jobID] != nil
    }

    func canEjectSource(for result: ImportResult) -> Bool {
        AppDistribution.current.supportsSourceEjection
            && !isEjectingSource
            && ejectedSourceJobID != result.jobID
            && cachedResultSourceEjectionTargets[result.jobID] != nil
    }

    func sourceEjectionDisplayName(for result: ImportResult) -> String? {
        if ejectedSourceJobID == result.jobID {
            return ejectedSourceName
        }
        return cachedResultSourceEjectionTargets[result.jobID]?.displayName
    }

    func sourceEjectionVolumeCount(for result: ImportResult) -> Int {
        if ejectedSourceJobID == result.jobID {
            return ejectedSourceVolumeCount
        }
        return cachedResultSourceEjectionTargets[result.jobID]?.volumeCount ?? 1
    }

    func ejectSource(for result: ImportResult) {
        guard
            AppDistribution.current.supportsSourceEjection,
            !isEjectingSource,
            let target = cachedResultSourceEjectionTargets[result.jobID]
        else {
            statusMessage = "Source cannot be ejected safely"
            return
        }

        ejectSource(jobID: result.jobID, target: target)
    }

    private func ejectSource(jobID: String, target: SourceEjectionTarget) {
        guard AppDistribution.current.supportsSourceEjection else {
            statusMessage = "Eject the source in Finder"
            return
        }
        guard !isWorking, !isEjectingSource else {
            statusMessage = "Finish the current operation before ejecting"
            return
        }
        isEjectingSource = true
        activeImportRetryContext = .eject(jobID: jobID, target: target)
        failedImportRetryContext = nil
        transitionImportWorkspace(.beginAuxiliaryOperation(.eject))
        statusMessage = target.volumeCount > 1
            ? "Ejecting \(target.displayName) storage..."
            : "Ejecting source..."
        sourceEjectionTask?.cancel()
        sourceEjectionTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await Self.ejectDevice(target)
                guard !Task.isCancelled else {
                    self.isEjectingSource = false
                    self.activeImportRetryContext = nil
                    self.transitionImportWorkspace(.endAuxiliaryOperation)
                    self.sourceEjectionTask = nil
                    return
                }
                self.ejectedSourceName = target.displayName
                self.ejectedSourceVolumeCount = target.volumeCount
                self.ejectedSourceJobID = jobID
                self.isEjectingSource = false
                self.activeImportRetryContext = nil
                self.transitionImportWorkspace(.endAuxiliaryOperation)
                self.sourceEjectionTask = nil
                self.refreshAvailableSourceVolumes()
                self.validatePaths()
                self.statusMessage = target.volumeCount > 1
                    ? "\(target.displayName) ejected safely"
                    : "Source ejected safely"
            } catch is CancellationError {
                self.isEjectingSource = false
                self.activeImportRetryContext = nil
                self.transitionImportWorkspace(.endAuxiliaryOperation)
                self.sourceEjectionTask = nil
            } catch {
                self.isEjectingSource = false
                self.sourceEjectionTask = nil
                let message = "Could not eject source: \(error.localizedDescription)"
                self.statusMessage = message
                self.failedImportRetryContext = self.activeImportRetryContext
                self.activeImportRetryContext = nil
                self.transitionImportWorkspace(.failed(operation: .eject, message: message))
            }
        }
    }

    private func expanded(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func existingReportPath(for job: ImportJob) -> String? {
        [job.summaryMarkdownPath, job.summaryJSONPath]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: expanded($0)) }
    }

    private func recentPathSuggestions(
        choices: [RecentPathChoice],
        currentPath: String,
        purpose: PathValidationPurpose,
        visibleLimit: Int = 8
    ) -> [RecentPathSuggestion] {
        let currentExpandedPath = expanded(currentPath)
        let validator = PathValidator()
        return choices.compactMap { choice in
            guard choice.path != currentExpandedPath else {
                return nil
            }
            guard !hiddenRecentPaths.contains(normalizedRecentPath(choice.path)) else {
                return nil
            }
            return RecentPathSuggestion(
                choice: choice,
                validation: validator.validate(path: choice.path, purpose: purpose)
            )
        }
        .prefix(visibleLimit)
        .map { $0 }
    }

    private func normalizedRecentPath(_ path: String) -> String {
        expanded(path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func unhideRecentPath(_ path: String) {
        let normalizedPath = normalizedRecentPath(path)
        guard hiddenRecentPaths.remove(normalizedPath) != nil else {
            return
        }
        rebuildRecentPathSuggestions()
    }

    private func rebuildRecentImportSuggestions() {
        rebuildRecentShootNameSuggestions()
        rebuildRecentPathSuggestions()
    }

    private func rebuildRecentShootNameSuggestions() {
        let currentName = Self.defaultSessionLabel(for: location)
        recentShootNameSuggestions = RecentImportChoices.shootNames(from: jobs, limit: 8)
            .filter {
                $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    != currentName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }
    }

    private func rebuildRecentPathSuggestions() {
        recentSourcePathSuggestions = recentPathSuggestions(
            choices: RecentImportChoices.sourcePaths(from: jobs, limit: 32),
            currentPath: cardPath,
            purpose: .source
        )
        recentPhotosPathSuggestions = recentPathSuggestions(
            choices: RecentImportChoices.photoRoots(from: jobs, limit: 32),
            currentPath: photosPath,
            purpose: .destination
        )
        recentVideosPathSuggestions = recentPathSuggestions(
            choices: RecentImportChoices.videoRoots(from: jobs, limit: 32),
            currentPath: videosPath,
            purpose: .destination
        )
    }

    private func diagnosticsText() -> String {
        DiagnosticsReportBuilder.markdown(snapshot: diagnosticsSnapshot())
    }

    private func diagnosticsSnapshot() -> DiagnosticsReportSnapshot {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "dev"
        let appBuild = info["CFBundleVersion"] as? String ?? "dev"
#if SDIMPORT_DIRECT
        let updateFeedConfigured = (info["SUFeedURL"] as? String)?.isEmpty == false
            && (info["SUPublicEDKey"] as? String)?.isEmpty == false
#else
        let updateFeedConfigured = false
#endif
        let crashReportDirectory = CrashReportLocator.defaultDirectory()
        let recentCrashReports = AppDistribution.current.canBrowseSystemCrashReports
            ? CrashReportLocator.findReports(in: crashReportDirectory, limit: 5)
            : []

        return DiagnosticsReportSnapshot(
            generatedAt: Date(),
            appVersion: appVersion,
            appBuild: appBuild,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.currentArchitecture,
            updateFeedConfigured: updateFeedConfigured,
            sourcePath: cardPath,
            photosPath: photosPath,
            videosPath: videosPath,
            sourceStatus: sourceValidation.message,
            photosStatus: photosValidation.message,
            videosStatus: videosValidation.message,
            autoPromptEnabled: autoPromptEnabled,
            backgroundPromptServiceStatus: backgroundPromptServiceStatus.rawValue,
            backgroundPromptApplicationOwnership: backgroundPromptOwnershipDiagnosticValue,
            backgroundPromptAgentBuild: backgroundPromptAgentState?.agentBuild,
            backgroundPromptAgentLaunchedAt: backgroundPromptAgentState?.launchedAt,
            backgroundPromptLastHandoffAt: backgroundPromptAgentState?.lastHandoffAt,
            backgroundPromptLastError: backgroundPromptEffectiveError,
            historyRetention: historyRetention.diagnosticsTitle,
            statusMessage: statusMessage,
            setupError: setupError,
            crashReportDirectory: crashReportDirectory.path,
            recentCrashReports: recentCrashReports.map(DiagnosticsCrashReportSummary.init(candidate:)),
            recentJobs: jobs.prefix(10).map(DiagnosticsJobSummary.init(job:)),
            selectedFiles: selectedJobFiles.prefix(75).map(DiagnosticsFileSummary.init(file:))
        )
    }

    private var backgroundPromptOwnershipDiagnosticValue: String {
        if backgroundPromptApplicationOwnership.isCurrentApplicationAuthoritative {
            return "current installed copy"
        }
        return backgroundPromptApplicationOwnership.authoritativeApplicationPath == nil
            ? "installation required"
            : "another installed copy"
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func resolvedPath(_ path: String, validation: PathValidationResult) -> String {
        validation.isUsable ? validation.expandedPath : expanded(path)
    }

    private func planningPath(
        _ path: String,
        validation: PathValidationResult,
        fallback: String
    ) -> String {
        let resolvedPath = resolvedPath(path, validation: validation)
        return resolvedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallback
            : resolvedPath
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

    private func requiredDestinationPurposes() -> [BookmarkPurpose] {
        switch organizationPreset {
        case .classicDatedFolders:
            var purposes: [BookmarkPurpose] = []
            if importMediaSelection.includes(.photo) {
                purposes.append(.photos)
            }
            if importMediaSelection.includes(.video) {
                purposes.append(.videos)
            }
            return purposes
        case .shootSessionsByDate:
            return [.photos]
        case .footageBackup:
            return [.videos]
        }
    }

    private func requiredDestinationValidations() -> [PathValidationResult] {
        requiredDestinationPurposes().map { purpose in
            purpose == .photos ? photosValidation : videosValidation
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

        applyRecommendedWorkflowAfterScan(contentProfile)
    }

    private func applyRecommendedWorkflowAfterScan(_ contentProfile: MediaContentProfile) {
        guard contentProfile.recommendedWorkflow == .mixedShootSession else {
            applyWorkflowProfile(contentProfile.recommendedWorkflow, userInitiated: false)
            return
        }

        importMediaSelection = .photosAndVideos
        normalizeDestinationForCurrentImportType()
        updateWorkflowProfileForCurrentOptions()
        validatePaths()
    }

    private func workflowPreference(for summary: ScanSummary) -> ImportWorkflowProfile? {
        guard let key = volumePreferenceKey(uuid: summary.volumeUUID, name: summary.volumeName) else {
            return nil
        }
        return workflowProfilesByVolume[key]
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
        let sessions = makePreviewSessions(files: files, defaultLabel: defaultLabel, existing: existing)
        let plans = buildImportPlans(files: files, sessions: sessions)
        previewSessions = ImportPreviewSessionFilter().visibleSessions(
            files: files,
            plans: plans,
            sessions: sessions,
            importMediaSelection: importMediaSelection,
            organizationPreset: organizationPreset
        )
    }

    private func makePreviewSessions(
        files: [JobFileRecord],
        defaultLabel: String,
        existing: [String: ImportPreviewSession]
    ) -> [ImportPreviewSession] {
        let grouped = Dictionary(grouping: files) { ImportPlanBuilder.sessionDate(for: $0) }
        let includePhotos = organizationPreset == .footageBackup ? false : importMediaSelection.includes(.photo)
        let includeVideos = importMediaSelection.includes(.video)
        let includeSidecars = workflowProfile.includesSidecarsByDefault
        let normalizedDefaultLabel = Self.defaultSessionLabel(for: defaultLabel)
        let cardHasVideos = files.contains { $0.mediaKind == .video }

        return grouped.keys.sorted().map { date in
            let files = grouped[date] ?? []
            let prior = existing[date]
            let likelyVideoPreviewJPEGCount = cardHasVideos
                ? files.filter(MediaFileHeuristics.isLikelyVideoPreviewJPEG).count
                : 0
            return ImportPreviewSession(
                date: date,
                label: prior?.label ?? normalizedDefaultLabel,
                photoCount: files.filter { $0.mediaKind == .photo }.count - likelyVideoPreviewJPEGCount,
                videoCount: files.filter { $0.mediaKind == .video }.count,
                unsupportedCount: files.filter { $0.mediaKind == .unsupported }.count + likelyVideoPreviewJPEGCount,
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
        defaults.set(autoPromptEnabled, forKey: DefaultsKeys.autoPromptEnabled)
        ejectAfterSuccessfulImport = configuration.ejectAfterSuccessfulImport
        portableImportReceiptsEnabled = configuration.portableImportReceiptsEnabled
        hasCompletedOnboarding = configuration.hasCompletedOnboarding
        workflowProfile = configuration.lastWorkflowProfile
        importMediaSelection = configuration.lastMediaSelection
        destinationLayout = configuration.lastDestinationLayout
        preferredMixedDestinationLayout = configuration.preferredMixedDestinationLayout
        normalizeDestinationForCurrentImportType()
        updateWorkflowProfileForCurrentOptions()
        folderGrouping = configuration.lastFolderGrouping
        themePreference = configuration.themePreference
        workflowProfilesByVolume = configuration.workflowProfilesByVolume
        hiddenRecentPaths = Set(configuration.hiddenRecentPaths.map(normalizedRecentPath).filter { !$0.isEmpty })
        importDefaults = ImportDefaults(
            photosPath: photosPath,
            videosPath: videosPath,
            shootName: Self.defaultSessionLabel(for: location),
            workflowProfile: workflowProfile,
            mediaSelection: importMediaSelection,
            destinationLayout: destinationLayout,
            preferredMixedDestinationLayout: preferredMixedDestinationLayout,
            folderGrouping: folderGrouping
        )
        initialOnboardingSourcePath = cardPath

        if try settingsRepository.fetchConfiguration() == nil {
            try settingsRepository.saveConfiguration(currentConfiguration())
        }
    }

    private func refreshAutoPromptPreferenceFromSharedStore() {
        do {
            guard let configuration = try settingsRepository?.fetchConfiguration() else {
                return
            }
            if autoPromptEnabled != configuration.autoPromptEnabled {
                autoPromptEnabled = configuration.autoPromptEnabled
            }
            defaults.set(configuration.autoPromptEnabled, forKey: DefaultsKeys.autoPromptEnabled)
        } catch {
            statusMessage = "Could not refresh background prompt settings: \(Self.errorMessage(for: error))"
        }
    }

    private func currentConfiguration() -> AppConfiguration {
        let validator = PathValidator()
        let defaultPhotosValidation = validator.validate(
            path: importDefaults.photosPath,
            purpose: .destination
        )
        let defaultVideosValidation = validator.validate(
            path: importDefaults.videosPath,
            purpose: .destination
        )
        return AppConfiguration(
            sourcePath: resolvedPath(cardPath, validation: sourceValidation),
            photosPath: resolvedPath(importDefaults.photosPath, validation: defaultPhotosValidation),
            videosPath: resolvedPath(importDefaults.videosPath, validation: defaultVideosValidation),
            defaultLocation: Self.defaultSessionLabel(for: importDefaults.shootName),
            historyRetention: historyRetention,
            autoPromptEnabled: autoPromptEnabled,
            ejectAfterSuccessfulImport: ejectAfterSuccessfulImport,
            portableImportReceiptsEnabled: portableImportReceiptsEnabled,
            hasCompletedOnboarding: hasCompletedOnboarding,
            lastWorkflowProfile: importDefaults.workflowProfile,
            lastMediaSelection: importDefaults.mediaSelection,
            lastDestinationLayout: importDefaults.destinationLayout,
            preferredMixedDestinationLayout: importDefaults.preferredMixedDestinationLayout,
            lastFolderGrouping: importDefaults.folderGrouping,
            themePreference: themePreference,
            workflowProfilesByVolume: workflowProfilesByVolume,
            hiddenRecentPaths: hiddenRecentPaths.sorted()
        )
    }

    private func resolvedPath(for purpose: BookmarkPurpose, fallback: String) throws -> String {
        folderAccesses[purpose]?.url.path
            ?? bookmarkStore?.resolvedPath(purpose: purpose, fallback: fallback)
            ?? fallback
    }

    private func saveFolderBookmark(_ purpose: BookmarkPurpose, path: String) throws {
        let validationPurpose: PathValidationPurpose = purpose == .source ? .source : .destination
        let validation = PathValidator().validate(path: path, purpose: validationPurpose)
        guard validation.isUsable else {
            return
        }
        let url = URL(fileURLWithPath: validation.expandedPath, isDirectory: true)
        guard let bookmarkStore else {
            throw FolderAccessAuthorizationError(purpose: purpose)
        }
        try bookmarkStore.saveBookmark(purpose: purpose, url: url)
        refreshFolderAccess(purpose)
        if
            AppDistribution.current == .macAppStore,
            folderAccesses[purpose]?.isActive != true
        {
            throw FolderAccessAuthorizationError(purpose: purpose)
        }
    }

    private func folderPath(for purpose: BookmarkPurpose) -> String {
        switch purpose {
        case .source:
            cardPath
        case .photos:
            importDefaults.photosPath
        case .videos:
            importDefaults.videosPath
        }
    }

    @discardableResult
    private func retainSelectedFolderAccess(
        _ purpose: BookmarkPurpose,
        url: URL,
        persistBookmark: Bool
    ) -> Bool {
        let priorAccess = folderAccesses[purpose]
        do {
            if persistBookmark {
                guard let bookmarkStore else {
                    throw FolderAccessAuthorizationError(purpose: purpose)
                }
                try bookmarkStore.saveBookmark(purpose: purpose, url: url)
                refreshFolderAccess(purpose)
            } else {
                folderAccesses[purpose] = SecurityScopedResourceAccess(url: url)
            }
            if
                AppDistribution.current == .macAppStore,
                folderAccesses[purpose]?.isActive != true
            {
                throw FolderAccessAuthorizationError(purpose: purpose)
            }
            return true
        } catch {
            folderAccesses[purpose] = priorAccess
            statusMessage = "Could not retain folder access: \(Self.errorMessage(for: error))"
            settingsFeedback = SettingsFeedback(message: statusMessage, role: .error)
            return false
        }
    }

    private func ensureSourceAccessForScan() -> Bool {
        guard AppDistribution.current == .macAppStore else {
            return true
        }
        let sourcePath = expanded(cardPath)
        if hasActiveFolderAccess(covering: sourcePath) {
            return true
        }
        guard let selectedURL = FilePanelPresenter.chooseDirectoryURL(
            title: "Allow Access to Source",
            initialPath: sourcePath,
            prompt: "Allow Access",
            message: "Choose the card or source folder before \(AppDistribution.current.displayName) scans it."
        ) else {
            statusMessage = "Card scan cancelled"
            return false
        }
        guard retainSelectedFolderAccess(.source, url: selectedURL, persistBookmark: true) else {
            return false
        }
        unhideRecentPath(selectedURL.path)
        cardPath = selectedURL.path
        sourcePathDidChange()
        savePreferences()
        return true
    }

    private func ensureRequiredDestinationAccessForImport() -> Bool {
        guard AppDistribution.current == .macAppStore else {
            return true
        }
        for purpose in requiredDestinationPurposes() {
            let currentPath = purpose == .photos ? photosPath : videosPath
            let expandedPath = expanded(currentPath)
            if hasActiveFolderAccess(covering: expandedPath) {
                continue
            }
            let displayName = purpose == .photos ? "Photo Destination" : "Video Destination"
            guard let selectedURL = FilePanelPresenter.chooseDirectoryURL(
                title: "Allow Access to \(displayName)",
                initialPath: expandedPath,
                prompt: "Allow Access",
                message: "Choose the destination before \(AppDistribution.current.displayName) copies files to it."
            ) else {
                statusMessage = "Import cancelled"
                return false
            }
            guard retainSelectedFolderAccess(purpose, url: selectedURL, persistBookmark: false) else {
                return false
            }
            unhideRecentPath(selectedURL.path)
            if purpose == .photos {
                photosPath = selectedURL.path
            } else {
                videosPath = selectedURL.path
            }
            destinationPathDidChange()
        }
        return true
    }

    private func ensureAccessForRetryingJob(_ job: ImportJob) -> Bool {
        guard AppDistribution.current == .macAppStore else {
            return true
        }
        let destinationDirectories = selectedJobFiles.compactMap(\.destinationDirectory)
        var requests: [(purpose: BookmarkPurpose, path: String, title: String)] = [
            (.source, job.mountPath, "Retry Source")
        ]
        let destinationRequests: [(purpose: BookmarkPurpose, path: String, title: String)] = [
            (.photos, job.photosRoot, "Retry Photo Destination"),
            (.videos, job.videosRoot, "Retry Video Destination")
        ]
        requests.append(contentsOf: destinationRequests.filter { request in
            guard !destinationDirectories.isEmpty else {
                return true
            }
            let rootURL = URL(fileURLWithPath: request.path, isDirectory: true)
            return destinationDirectories.contains { directory in
                Self.isSameOrDescendant(
                    URL(fileURLWithPath: directory, isDirectory: true),
                    of: rootURL
                )
            }
        })
        for request in requests where !request.path.isEmpty {
            if hasActiveFolderAccess(covering: request.path) {
                continue
            }
            guard let selectedURL = FilePanelPresenter.chooseDirectoryURL(
                title: "Allow Access to \(request.title)",
                initialPath: request.path,
                prompt: "Allow Access",
                message: "Choose this folder again so \(AppDistribution.current.displayName) can retry the existing job."
            ) else {
                statusMessage = "Retry cancelled"
                return false
            }
            let requestedURL = URL(fileURLWithPath: request.path, isDirectory: true)
            guard Self.isSameOrDescendant(requestedURL, of: selectedURL) else {
                statusMessage = "Choose \(request.path) or one of its parent folders"
                return false
            }
            guard retainSelectedFolderAccess(
                request.purpose,
                url: selectedURL,
                persistBookmark: false
            ) else {
                return false
            }
        }
        return true
    }

    private func hasActiveFolderAccess(covering path: String) -> Bool {
        let requestedURL = URL(fileURLWithPath: expanded(path), isDirectory: true)
        return folderAccesses.values.contains { access in
            access.isActive && Self.isSameOrDescendant(requestedURL, of: access.url)
        }
    }

    private func activeFolderAccessPurposes() -> Set<BookmarkPurpose> {
        Set(
            BookmarkPurpose.allCases.filter { purpose in
                hasActiveFolderAccess(covering: folderPath(for: purpose))
            }
        )
    }

    private func refreshFolderAccesses() {
        for purpose in BookmarkPurpose.allCases {
            refreshFolderAccess(purpose)
        }
    }

    /// Removes legacy containerized or typed destination fallbacks that have
    /// no corresponding sandbox grant. A valid security-scoped bookmark keeps
    /// its path, and the direct edition retains its historical defaults.
    @discardableResult
    private func clearUnauthorizedAppStoreDestinationDefaults() -> Bool {
        guard AppDistribution.current == .macAppStore else {
            return false
        }

        var changed = false
        let hasPhotosAccess = !importDefaults.photosPath.isEmpty
            && hasActiveFolderAccess(covering: importDefaults.photosPath)
        let retainedPhotosPath = AppDistribution.current.retainedDestinationPath(
            importDefaults.photosPath,
            hasAuthorizedAccess: hasPhotosAccess
        )
        if retainedPhotosPath != importDefaults.photosPath {
            importDefaults.photosPath = retainedPhotosPath
            photosPath = retainedPhotosPath
            changed = true
        }
        let hasVideosAccess = !importDefaults.videosPath.isEmpty
            && hasActiveFolderAccess(covering: importDefaults.videosPath)
        let retainedVideosPath = AppDistribution.current.retainedDestinationPath(
            importDefaults.videosPath,
            hasAuthorizedAccess: hasVideosAccess
        )
        if retainedVideosPath != importDefaults.videosPath {
            importDefaults.videosPath = retainedVideosPath
            videosPath = retainedVideosPath
            changed = true
        }
        return changed
    }

    private func refreshFolderAccess(_ purpose: BookmarkPurpose) {
        do {
            folderAccesses[purpose] = try bookmarkStore?.beginAccess(
                purpose: purpose,
                staleBookmarkHandling: AppDistribution.current.staleBookmarkHandling
            )
        } catch {
            folderAccesses[purpose] = nil
        }
    }

    private func authorizedSourceURL(for volume: MountedVolume) -> URL? {
        guard let bookmarkStore,
              let resolved = try? bookmarkStore.resolveBookmark(purpose: .source),
              !resolved.isStale,
              Self.isSameOrDescendant(resolved.url, of: volume.mountURL)
        else {
            return nil
        }
        refreshFolderAccess(.source)
        guard let access = folderAccesses[.source], access.isActive else {
            return nil
        }
        return access.url
    }

    nonisolated private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func startMountObserver() {
        guard mountObserver == nil else {
            return
        }

        let observer = MountEventObserver(
            handler: { [weak self] volume in
                guard let self else {
                    return .deferred
                }
                self.refreshAvailableSourceVolumes()
                guard BackgroundPromptDeliveryPolicy.canCommitPrompt(
                    desiredEnabled: self.autoPromptEnabled,
                    hasCompletedOnboarding: self.hasCompletedOnboarding,
                    isWorking: self.isWorking || self.isEjectingSource,
                    hasPendingPrompt: self.pendingMountedVolume != nil
                ) else {
                    return .deferred
                }
                self.pendingMountedVolume = volume
                self.statusMessage = "Card detected"
                MainWindowPresenter.present()
                self.refreshBackgroundPromptHealth()
                return .accepted
            },
            shouldHandleDirectMount: { [weak self] in
                guard let self else {
                    return false
                }
                return BackgroundPromptDeliveryPolicy.canObserveDirectMount(
                    desiredEnabled: self.autoPromptEnabled,
                    hasCompletedOnboarding: self.hasCompletedOnboarding,
                    isAuthoritativeApplication: LoginItemController.applicationOwnership
                        .isCurrentApplicationAuthoritative
                )
            },
            shouldHandleHandoff: { [weak self] event in
                guard let self else {
                    return false
                }
                switch event.origin {
                case .backgroundAgent:
                    return self.currentlyOwnsBackgroundPromptRegistration()
                case .foregroundApplication:
                    return BackgroundPromptDeliveryPolicy.canObserveDirectMount(
                        desiredEnabled: self.autoPromptEnabled,
                        hasCompletedOnboarding: self.hasCompletedOnboarding,
                        isAuthoritativeApplication: LoginItemController.applicationOwnership
                            .isCurrentApplicationAuthoritative
                    )
                }
            },
            handoffAcknowledgedHandler: { [weak self] event in
                self?.recordSuccessfulBackgroundPromptDelivery(event)
            },
            errorHandler: { [weak self] message, eventSequence in
                guard let self else {
                    return
                }
                self.recordBackgroundPromptError(message, eventSequence: eventSequence)
            }
        )
        mountObserver = observer
        observer.start()
    }

    private func schedulePendingMountHandoffRetry() {
        pendingMountHandoffRetryTask?.cancel()
        pendingMountHandoffRetryTask = Task { [weak self] in
            await Task.yield()
            guard
                !Task.isCancelled,
                let self,
                self.autoPromptEnabled,
                self.hasCompletedOnboarding,
                !self.isWorking,
                !self.isEjectingSource,
                self.pendingMountedVolume == nil,
                BackgroundPromptDeliveryPolicy.canObserveDirectMount(
                    desiredEnabled: self.autoPromptEnabled,
                    hasCompletedOnboarding: self.hasCompletedOnboarding,
                    isAuthoritativeApplication: LoginItemController.applicationOwnership
                        .isCurrentApplicationAuthoritative
                )
            else {
                return
            }
            self.mountObserver?.consumePendingHandoffs()
        }
    }

    private func recordSuccessfulBackgroundPromptDelivery(_ event: MountHandoffEvent) {
        guard event.origin == .backgroundAgent else {
            return
        }
        do {
            try BackgroundPromptAgentStateStore.defaultStore().recordSuccessfulDelivery(
                agentBuild: event.agentBuild,
                agentBundlePath: expectedEmbeddedAgentPath,
                eventSequence: event.agentSequence
            )
            if BackgroundPromptHealth.shouldClearRuntimeAppError(
                errorSequence: backgroundPromptLastErrorSequence,
                successfulSequence: event.agentSequence
            ) {
                backgroundPromptLastError = nil
                backgroundPromptLastErrorSequence = nil
            }
            refreshBackgroundPromptHealth()
        } catch {
            recordBackgroundPromptError("Could not update background helper diagnostics")
        }
    }

    private func currentlyOwnsBackgroundPromptRegistration() -> Bool {
        let ownership = LoginItemController.applicationOwnership
        guard
            autoPromptEnabled,
            ownership.isCurrentApplicationAuthoritative,
            let state = try? BackgroundPromptAgentStateStore.defaultStore().load()
        else {
            return false
        }
        return BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
            identity: currentRepairIdentity,
            serviceStatus: LoginItemController.status,
            liveAgentState: state,
            minimumLaunchAt: minimumBackgroundPromptAgentLaunchAt
        )
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

    nonisolated private static func mountedSourceVolume(containing sourcePath: String) -> MountedVolume? {
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        guard
            let values = try? sourceURL.resourceValues(forKeys: [.volumeURLKey]),
            let volumeURL = values.volume
        else {
            return nil
        }

        let detector = VolumeDetector()
        let volume = detector.mountedVolume(from: volumeURL)
        return detector.isLikelyImportVolume(volume) ? volume : nil
    }

    private func rebuildSourceEjectionTargetCache() {
        cachedSelectedSourceEjectionTarget = selectedMountedSourceVolume.flatMap {
            sourceEjectionTarget(
                sourceVolume: $0,
                destinationPaths: [],
                mountedVolumes: mountedVolumesSnapshot
            )
        }

        cachedResultSourceEjectionTargets.removeAll(keepingCapacity: true)
        guard
            let result = currentResult,
            let target = buildSourceEjectionTarget(
                for: result,
                mountedVolumes: mountedVolumesSnapshot
            )
        else {
            return
        }
        cachedResultSourceEjectionTargets[result.jobID] = target
    }

    private func buildSourceEjectionTarget(
        for result: ImportResult,
        mountedVolumes: [MountedVolume]
    ) -> SourceEjectionTarget? {
        guard
            let job = jobs.first(where: { $0.id == result.jobID }),
            let volume = mountedSourceVolume(containing: job.mountPath, among: mountedVolumes),
            SourceEjectionPolicy().canEject(job: job, result: result, volume: volume)
        else {
            return nil
        }
        return sourceEjectionTarget(
            sourceVolume: volume,
            destinationPaths: [job.photosRoot, job.videosRoot],
            mountedVolumes: mountedVolumes
        )
    }

    private func sourceEjectionTarget(
        sourceVolume: MountedVolume,
        destinationPaths: [String],
        mountedVolumes: [MountedVolume]
    ) -> SourceEjectionTarget? {
        let grouper = MountedDeviceGrouper()
        let group = grouper.group(containing: sourceVolume, among: mountedVolumes)
        let ejectionVolumes = grouper.ejectionVolumes(for: sourceVolume, among: mountedVolumes)
        guard
            !ejectionVolumes.isEmpty,
            !destinationPaths.contains(where: {
                Self.destination($0, sharesDeviceWith: group.volumes)
            })
        else {
            return nil
        }

        return SourceEjectionTarget(
            displayName: group.isMultiVolume ? group.displayName : sourceVolume.name,
            volumes: group.volumes,
            ejectionVolumes: ejectionVolumes
        )
    }

    private var selectedMountedSourceVolume: MountedVolume? {
        let sourcePath = URL(fileURLWithPath: expanded(cardPath), isDirectory: true)
            .standardizedFileURL.path
        return availableSourceVolumes.first { volume in
            let mountPath = volume.mountURL.standardizedFileURL.path
            return sourcePath == mountPath || sourcePath.hasPrefix(mountPath + "/")
        }
    }

    private func mountedSourceVolume(
        containing sourcePath: String,
        among mountedVolumes: [MountedVolume]
    ) -> MountedVolume? {
        let sourcePath = URL(fileURLWithPath: sourcePath, isDirectory: true)
            .standardizedFileURL.path
        return mountedVolumes
            .filter { volume in
                let mountPath = volume.mountURL.standardizedFileURL.path
                return sourcePath == mountPath || sourcePath.hasPrefix(mountPath + "/")
            }
            .max {
                $0.mountURL.standardizedFileURL.path.count
                    < $1.mountURL.standardizedFileURL.path.count
            }
    }

    nonisolated private static func destination(
        _ destinationPath: String,
        sharesDeviceWith sourceVolumes: [MountedVolume]
    ) -> Bool {
        var destinationURL = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL
        while
            !FileManager.default.fileExists(atPath: destinationURL.path),
            destinationURL.path != "/"
        {
            destinationURL.deleteLastPathComponent()
        }
        guard
            let values = try? destinationURL.resourceValues(forKeys: [.volumeURLKey]),
            let volumeURL = values.volume
        else {
            return false
        }

        let destinationVolume = VolumeDetector().mountedVolume(from: volumeURL)
        return sourceVolumes.contains { sourceVolume in
            if
                let sourceDevice = sourceVolume.deviceGroupIdentifier,
                let destinationDevice = destinationVolume.deviceGroupIdentifier
            {
                return sourceDevice == destinationDevice
            }
            if
                let sourceDisk = sourceVolume.wholeDiskIdentifier,
                let destinationDisk = destinationVolume.wholeDiskIdentifier
            {
                return sourceDisk == destinationDisk
            }
            if
                let sourceUUID = sourceVolume.volumeUUID,
                let destinationUUID = destinationVolume.volumeUUID
            {
                return sourceUUID == destinationUUID
            }
            return false
        }
    }

    nonisolated private static func ejectDevice(_ target: SourceEjectionTarget) async throws {
        try await Task.detached(priority: .userInitiated) {
            var ejectedVolumeNames: [String] = []
            for volume in target.ejectionVolumes {
                guard FileManager.default.fileExists(atPath: volume.mountURL.path) else {
                    continue
                }
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volume.mountURL)
                    ejectedVolumeNames.append(volume.name)
                } catch {
                    throw SourceDeviceEjectionError(
                        failedVolumeName: volume.name,
                        ejectedVolumeNames: ejectedVolumeNames,
                        message: error.localizedDescription
                    )
                }
            }
        }.value
    }

    nonisolated private static func errorMessage(for error: Error) -> String {
        if case let SDImportError.insufficientDestinationSpace(path, requiredBytes, availableBytes) = error {
            let required = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return "Not enough space in \(path). Need \(required), available \(available)."
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return String(describing: error)
    }
}

private enum ImportPlanMode: Sendable {
    case rebuild(ImportPlanBuilder)
    case existing

    var destinationRoots: DestinationRoots? {
        switch self {
        case .rebuild(let builder):
            return builder.roots
        case .existing:
            return nil
        }
    }

    func updates(files: [JobFileRecord]) -> [JobFilePlanUpdate] {
        switch self {
        case .rebuild(let builder):
            return builder.updates(files: files)
        case .existing:
            return []
        }
    }
}

private struct FolderAccessAuthorizationError: LocalizedError {
    let purpose: BookmarkPurpose

    var errorDescription: String? {
        switch purpose {
        case .source:
            "Select the source folder in the macOS access panel."
        case .photos:
            "Select the photo destination in the macOS access panel."
        case .videos:
            "Select the video destination in the macOS access panel."
        }
    }
}

private enum DefaultsKeys {
    static let cardPath = "SDImport.cardPath"
    static let photosPath = "SDImport.photosPath"
    static let videosPath = "SDImport.videosPath"
    static let location = "SDImport.location"
    static let autoPromptEnabled = "SDImport.autoPromptEnabled"
    static let lastLoginItemRepairIdentity = "SDImport.lastLoginItemRepairIdentity"
    static let lastNotFoundRepairAttemptAt = "SDImport.lastNotFoundRepairAttemptAt"
    static let lastHealthRepairAttemptAt = "SDImport.lastHealthRepairAttemptAt"
    static let minimumBackgroundPromptAgentLaunchAt = "SDImport.minimumBackgroundPromptAgentLaunchAt"
    static let ejectAfterSuccessfulImport = "SDImport.ejectAfterSuccessfulImport"
    static let portableImportReceiptsEnabled = "SDImport.portableImportReceiptsEnabled"
    static let hasCompletedOnboarding = "SDImport.hasCompletedOnboarding"
    static let workflowProfile = "SDImport.workflowProfile"
    static let importMediaSelection = "SDImport.importMediaSelection"
    static let organizationPreset = "SDImport.organizationPreset"
    static let destinationLayout = "SDImport.destinationLayout"
    static let preferredMixedDestinationLayout = "SDImport.preferredMixedDestinationLayout"
    static let folderGrouping = "SDImport.folderGrouping"
    static let themePreference = "SDImport.themePreference"
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension RetentionPolicy {
    var diagnosticsTitle: String {
        switch self {
        case .days(let days):
            return "\(days) days"
        case .forever:
            return "Forever"
        }
    }
}
