import AppKit
import Foundation
import os
import OSLog
import SDImportCommerce
import SDImportCore

private let appLogSubsystem = Bundle.main.bundleIdentifier ?? "com.xcv58.SDImport"
private let importLogger = Logger(subsystem: appLogSubsystem, category: "Import")
private let diagnosticsLogger = Logger(subsystem: appLogSubsystem, category: "Diagnostics")

typealias ImportPreviewSession = ImportPlanSession

struct CompletedImportReceipt {
    let result: ImportResult
    let job: ImportJob?
    let files: [JobFileRecord]
}

struct ScanBothSession {
    struct Confirmation: Sendable {
        let draft: ImportDraft
        let plans: [ImportFilePlan]
        let destinations: ReviewedImportDestinations
        let copyFileCount: Int
        let destinationPaths: [String]
        var sharedBuilder: ImportPlanBuilder?
    }

    struct Entry: Identifiable {
        enum State {
            case waiting
            case scanning
            case complete(ScanSummary, SecurityScopedResourceAccess?, [String: ReviewedFileIdentity] = [:])
            case skipped(ScanBothIssue)
        }

        enum Disposition {
            case pending
            case imported
            case skipped
        }

        let id: UUID
        let volume: MountedVolume
        var state: State = .waiting
        var disposition: Disposition = .pending
        var hasStartedImport = false
        var draft: ImportDraft?
        var reviewNeedsAttention = false
        var confirmation: Confirmation?
        var result: ImportResult?
        var copyInterruption: String?

        var summary: ScanSummary? {
            if case .complete(let summary, _, _) = state { return summary }
            return nil
        }

        var jobID: String? { summary?.jobID }

        var access: SecurityScopedResourceAccess? {
            if case .complete(_, let access, _) = state { return access }
            return nil
        }

        var reviewedSourceFiles: [String: ReviewedFileIdentity]? {
            if case .complete(_, _, let files) = state { return files }
            return nil
        }

        var awaitsImport: Bool {
            guard case .complete = state, case .pending = disposition else { return false }
            return true
        }

        var canSkip: Bool {
            guard case .pending = disposition else { return false }
            switch state {
            case .complete, .skipped(.failed), .skipped(.accessUnavailable), .skipped(.cancelled), .skipped(.removed):
                return true
            default:
                return false
            }
        }

        var isResolved: Bool {
            if case .skipped = disposition { return true }
            switch state {
            case .complete:
                return !awaitsImport
            case .skipped(.accessDeclined):
                return true
            default:
                return false
            }
        }
    }

    let deviceName: String
    var entries: [Entry]
    var sharedReview: ScanBothReview?
    var removedMountPaths: Set<String> = []
    var reviewingJobID: String?
    private(set) var destinationRoot: ReviewedImportDestinations.Root?
    private(set) var destinationAccess: SecurityScopedResourceAccess?
    private(set) var confirmedDestinationPaths: Set<String>? = []
    var destinationPath: String { destinationRoot?.url.path ?? "" }

    init?(prompt: MountedDevicePrompt) {
        let group = prompt.deviceGroup
        guard group.volumes.count == 2 else { return nil }
        let entries = group.volumes.compactMap { volume in
            prompt.mountID(for: volume).map { Entry(id: $0, volume: volume) }
        }
        self.init(deviceName: group.displayName, entries: entries)
    }

    init?(deviceName: String, entries: [Entry]) {
        guard entries.count == 2 else { return nil }
        var entries = entries
        // Use chooser order when the firmware doesn't identify an internal volume.
        if !Self.isInternal(entries[0].volume), Self.isInternal(entries[1].volume) {
            entries.swapAt(0, 1)
        }
        self.deviceName = deviceName
        self.entries = entries
    }

    private static func isInternal(_ volume: MountedVolume) -> Bool {
        volume.isInternal || volume.name.localizedStandardContains("internal")
    }

    var reviewingEntry: Entry? {
        guard let reviewingJobID else { return nil }
        return entry(for: reviewingJobID)
    }

    func entry(for jobID: String) -> Entry? {
        entries.first { $0.jobID == jobID }
    }

    func hasDuplicateVolumeName(for entry: Entry) -> Bool {
        entries.contains {
            $0.id != entry.id && $0.volume.name.localizedStandardCompare(entry.volume.name) == .orderedSame
        }
    }

    func volumeTitle(for entry: Entry) -> String {
        hasDuplicateVolumeName(for: entry)
            ? L10n.tr("\(entry.volume.name) · \(entry.volume.mountPath)")
            : entry.volume.name
    }

    var hasPendingResults: Bool {
        entries.contains(where: \.awaitsImport)
    }

    var nextConfirmedEntry: Entry? {
        entries.first { $0.awaitsImport && $0.confirmation != nil }
    }

    var canStartImports: Bool {
        nextConfirmedEntry != nil && entries.allSatisfy { $0.isResolved || $0.confirmation != nil }
    }

    mutating func setConfirmation(_ confirmation: Confirmation?, for jobID: String) {
        guard let index = entries.firstIndex(where: { $0.jobID == jobID && $0.awaitsImport }) else { return }
        entries[index].confirmation = confirmation
    }

    var hasStartedImports: Bool {
        entries.contains(where: \.hasStartedImport)
    }

    @discardableResult
    mutating func setDestination(
        _ root: ReviewedImportDestinations.Root, access: SecurityScopedResourceAccess?
    ) -> Bool {
        let keepsDestination = destinationRoot.map {
            $0.url.standardizedFileURL.path == root.url.standardizedFileURL.path && $0.matches()
        } ?? false
        guard keepsDestination || !hasStartedImports else { return false }
        if !keepsDestination {
            for index in entries.indices {
                entries[index].confirmation = nil
                entries[index].reviewNeedsAttention = false
            }
            destinationRoot = root
        }
        destinationAccess = access
        return true
    }

    mutating func saveDraft(_ draft: ImportDraft, needsAttention: Bool, for jobID: String) {
        guard let index = entries.firstIndex(where: { $0.jobID == jobID && $0.awaitsImport }),
              !removedMountPaths.contains(entries[index].volume.mountPath)
        else { return }
        entries[index].draft = draft
        entries[index].reviewNeedsAttention = needsAttention
        if entries[index].confirmation?.draft != draft {
            entries[index].confirmation = nil
        }
    }

    var issueIfNoVolumeScanned: ScanBothIssue? {
        guard entries.allSatisfy({ $0.summary == nil }) else { return nil }
        for entry in entries {
            if case .skipped(let issue) = entry.state { return issue }
        }
        return nil
    }

    mutating func noteUnmount(at path: String) -> String? {
        guard let index = entries.firstIndex(where: { $0.volume.mountPath == path }) else { return nil }
        removedMountPaths.insert(path)
        entries[index].draft = nil
        entries[index].reviewNeedsAttention = false
        entries[index].confirmation = nil
        return entries[index].jobID
    }

    mutating func recordImportStarted(for jobID: String) {
        guard let index = entries.firstIndex(where: { $0.jobID == jobID }) else { return }
        entries[index].hasStartedImport = true
        entries[index].confirmation = nil
    }

    mutating func recordImport(_ result: ImportResult) {
        guard let index = entries.firstIndex(where: { $0.jobID == result.jobID }) else { return }
        entries[index].result = result
        entries[index].copyInterruption = nil
        if result.failedFiles == 0 {
            entries[index].disposition = .imported
            entries[index].draft = nil
            entries[index].reviewNeedsAttention = false
        }
    }

    mutating func recordInterruptedImport(
        jobID: String, files: [JobFileRecord], message: String, includeEmptyReceipt: Bool
    ) {
        guard let index = entries.firstIndex(where: { $0.jobID == jobID }) else { return }
        guard includeEmptyReceipt || files.contains(where: { $0.copyStatus == .copied || $0.copyStatus == .failed }) else {
            return
        }
        let totals = ImportReceiptTotals(files: files)
        entries[index].result = ImportResult(
            jobID: jobID, importedFiles: totals.copiedFiles, skippedFiles: totals.skippedFiles,
            failedFiles: totals.failedFiles, progressPath: nil
        )
        entries[index].copyInterruption = message
    }

    mutating func skipEntry(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.canSkip }) else { return }
        entries[index].disposition = .skipped
        entries[index].draft = nil
        entries[index].reviewNeedsAttention = false
        entries[index].confirmation = nil
    }

    func canInclude(_ entry: Entry) -> Bool {
        guard !hasStartedImports, case .skipped = entry.disposition,
              entry.summary != nil, !removedMountPaths.contains(entry.volume.mountPath) else { return false }
        return true
    }

    mutating func includeEntry(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id && canInclude($0) }) else { return }
        entries[index].disposition = .pending
    }

    mutating func recordImportDestinations(_ paths: Set<String>?, for jobID: String) {
        guard entry(for: jobID) != nil else { return }
        // Keep earlier destinations and unresolved paths even if a copy fails or History is removed.
        confirmedDestinationPaths = paths.flatMap { confirmedDestinationPaths?.union($0) }
    }

    var allowsEjection: Bool {
        removedMountPaths.isEmpty && entries.allSatisfy(\.isResolved)
    }

    var allowsAutomaticEjection: Bool {
        allowsEjection && entries.allSatisfy { entry in
            if case .imported = entry.disposition { return true }
            return !entry.hasStartedImport
        }
    }

    var plannedCopyVolumes: [MountedVolume] {
        entries.compactMap { entry in
            if case .skipped = entry.disposition { return nil }
            guard entry.summary != nil, !removedMountPaths.contains(entry.volume.mountPath) else { return nil }
            return entry.volume
        }
    }

    @MainActor
    func scan(
        update: (Int, Entry.State) -> Void,
        volume: (MountedVolume) async throws -> Entry.State
    ) async {
        for (index, entry) in entries.enumerated() {
            do {
                try Task.checkCancellation()
                update(index, .scanning)
                let result = try await volume(entry.volume)
                update(index, result)
            } catch {
                let issue: ScanBothIssue = Task.isCancelled
                    ? .cancelled
                    : (error as? ScanBothIssue ?? .failed(error.localizedDescription))
                update(index, .skipped(issue))
            }
        }
    }
}

enum ScanBothIssue: Error {
    case removed
    case accessDeclined
    case accessUnavailable
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .removed: L10n.tr("Card is not mounted")
        case .accessDeclined: L10n.tr("Access declined")
        case .accessUnavailable: L10n.tr("macOS needs your permission to read this source.")
        case .cancelled: L10n.tr("Scan cancelled")
        case .failed(let detail): L10n.tr("Scan failed: \(detail)")
        }
    }
}

struct ActiveCopySources: Sendable {
    private struct StopEvents: Sendable {
        var userCancelled = false
        var disconnectedVolume: String?
        var unmountedPaths: Set<String> = []
    }

    let volumes: [MountedVolume]
    private let stop = OSAllocatedUnfairLock(initialState: StopEvents())

    var disconnectedVolume: String? { stop.withLock { $0.disconnectedVolume } }

    init(volumes: [MountedVolume]) {
        self.volumes = volumes
    }

    mutating func noteUnmount(at path: String) -> Bool {
        guard let volume = volumes.first(where: { $0.mountPath == path }) else { return false }
        return stop.withLock { events in
            events.unmountedPaths.insert(path)
            guard events.disconnectedVolume == nil else { return false }
            events.disconnectedVolume = volume.name
            return true
        }
    }

    func noteUserCancellation() {
        stop.withLock { $0.userCancelled = true }
    }

    func wasStoppedOnlyBySiblingUnmount(sourcePath: String) -> Bool {
        stop.withLock {
            !$0.userCancelled && !$0.unmountedPaths.isEmpty && !$0.unmountedPaths.contains(sourcePath)
        }
    }
}

enum ImportPreviewGroupKind: Hashable {
    case rawJPEG
    case videoSidecars
    case insta360Clip
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
    var status: String { disposition.title }
    let willCopy: Bool
    let size: Int64
    let reimportRequested: Bool

    var canReimport: Bool {
        if case .known(let source) = disposition { return source != .destination }
        return false
    }

    var canSkipReimport: Bool {
        reimportRequested && disposition != .copied
    }
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
    case eject(jobID: String, target: SourceEjectionTarget)
}

private struct RescanContext: Sendable {
    let jobID: String
    let access: [SecurityScopedResourceAccess]
    var preparation: Insta360RescanRecovery.Preparation? = nil
}

private struct SourceDeviceEjectionError: LocalizedError {
    let failedVolumeName: String
    let ejectedVolumeNames: [String]
    let message: String

    var errorDescription: String? {
        if ejectedVolumeNames.isEmpty {
            return L10n.tr("\(failedVolumeName) remains mounted: \(message)")
        }
        return L10n.tr("\(ejectedVolumeNames.joined(separator: ", ")) ejected, but \(failedVolumeName) remains mounted: \(message)")
    }
}

struct RecentPathSuggestion: Identifiable {
    var id: String { choice.path }
    let choice: RecentPathChoice
    let validation: PathValidationResult

    var path: String { choice.path }
    var displayName: String { choice.displayName }
    var isAvailable: Bool { validation.isUsable }
    var canSelect: Bool { isAvailable || validation.status == .unreadable || validation.status == .unwritable }

    var menuTitle: String {
        let usage = choice.useCount == 1 ? L10n.tr("used once") : L10n.tr("used \(choice.useCount) times")
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
    let loadErrors: [ReportLoadError]

    var loadError: String? {
        loadErrors.isEmpty ? nil : loadErrors.map(\.message).joined(separator: "\n")
    }
}

enum ReportLoadError: Hashable, Sendable {
    case databaseNotReady
    case jsonReport(String)
    case jobFiles(String)

    var message: String {
        switch self {
        case .databaseNotReady: L10n.tr("Database is not ready")
        case .jsonReport(let detail): L10n.tr("JSON report: \(detail)")
        case .jobFiles(let detail): L10n.tr("Job files: \(detail)")
        }
    }
}

struct SettingsFeedback: Equatable {
    enum Role {
        case information
        case error
    }

    var message: String { localizedMessage.text }
    let role: Role
    let isBackgroundPrompt: Bool
    private let localizedMessage: RelocalizableMessage
    private let currentValue: LivePresentation<(message: String, role: Role)>?

    init(message: String, role: Role, render: (() -> String)? = nil, isBackgroundPrompt: Bool = false) {
        self.init(
            localizedMessage: RelocalizableMessage(message, render: render),
            role: role,
            isBackgroundPrompt: isBackgroundPrompt
        )
    }

    private init(localizedMessage: RelocalizableMessage, role: Role, isBackgroundPrompt: Bool) {
        self.localizedMessage = localizedMessage
        self.role = role
        self.isBackgroundPrompt = isBackgroundPrompt
        self.currentValue = nil
    }

    @MainActor
    init(currentValue: @escaping @MainActor () -> (message: String, role: Role)) {
        self.init(liveValue: LivePresentation(currentValue))
    }

    @MainActor
    private init(liveValue: LivePresentation<(message: String, role: Role)>) {
        self.localizedMessage = RelocalizableMessage(liveValue.value.message)
        self.role = liveValue.value.role
        self.isBackgroundPrompt = true
        self.currentValue = liveValue
    }

    @MainActor
    func relocalized(from previous: AppLanguage, to selected: AppLanguage) -> SettingsFeedback {
        if let currentValue {
            return SettingsFeedback(liveValue: currentValue.refreshed())
        }
        return SettingsFeedback(
            localizedMessage: localizedMessage.relocalized(from: previous, to: selected),
            role: role,
            isBackgroundPrompt: isBackgroundPrompt
        )
    }

    @MainActor
    func refreshedForStateChange() -> SettingsFeedback? {
        currentValue.map { SettingsFeedback(liveValue: $0.refreshed()) }
    }

    static func == (lhs: SettingsFeedback, rhs: SettingsFeedback) -> Bool {
        lhs.message == rhs.message && lhs.role == rhs.role && lhs.isBackgroundPrompt == rhs.isBackgroundPrompt
    }
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
    var isRepairingBackgroundPrompt: Bool { backgroundPrompt.isRepairingManually }
    @Published private var backgroundPromptPreferenceChange: (id: UUID, enablesPrompt: Bool)?

    var isStartingBackgroundPrompt: Bool {
        autoPromptEnabled && backgroundPromptCanConfigure
            && backgroundPromptPreferenceChange?.enablesPrompt == true
    }
    @Published private(set) var backgroundPromptAgentState: BackgroundPromptAgentState?
    @Published private(set) var backgroundPromptLastError: String? {
        didSet {
            if backgroundPromptLastError == nil {
                backgroundPromptLastErrorContent = nil
                backgroundPromptLastErrorIsRepairFailure = false
            }
        }
    }
    private var backgroundPromptLastErrorContent: RelocalizableMessage?
    private var backgroundPromptLastErrorIsRepairFailure = false
    @Published private var backgroundPromptLaunchTimeout: RelocalizableMessage?
    @Published private var backgroundPromptDiagnosticsReadFailed = false
    private var backgroundPromptLastErrorSequence: UInt64?
    @Published private(set) var backgroundPromptApplicationOwnership: BackgroundPromptApplicationOwnership
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
    @Published private var visiblePreviewSessions: [ImportPreviewSession] = []
    var previewSessions: [ImportPreviewSession] {
        get { visiblePreviewSessions }
        set {
            visiblePreviewSessions = newValue
            rebuildPreviewPlanCache()
        }
    }
    private var hiddenPreviewSessions: [String: ImportPreviewSession] = [:]
    @Published private(set) var previewRows: [ImportPreviewRow] = []
    @Published private(set) var previewTotals: ImportPreviewTotals = .empty
    @Published private(set) var previewDestinations: [ImportPreviewDestination] = []
    @Published private(set) var previewSpaceRequirements: [ImportPreviewSpaceRequirement] = []
    @Published var useOriginalInsta360Folders = true {
        didSet {
            if useOriginalInsta360Folders != oldValue {
                rebuildPreviewPlanCache()
            }
        }
    }
    @Published var currentSummary: ScanSummary? {
        didSet {
            if currentSummary?.jobID != oldValue?.jobID {
                hiddenPreviewSessions = [:]
            }
        }
    }
    private var insta360RescanRecovery: Insta360RescanRecovery?
    private var rescanContext: RescanContext?
    var hasInsta360RescanLensesToCopy: Bool {
        guard let insta360RescanRecovery else { return false }
        return previewRows.contains { row in
            row.willCopy && row.mediaKind == .video && insta360RescanRecovery.includes(sourcePath: row.sourcePath)
        }
    }
    var canCompleteInsta360InOriginalFolders: Bool {
        guard let insta360RescanRecovery else { return false }
        return previewRows.contains { row in
            (row.willCopy || row.disposition.attention == .blocking)
                && insta360RescanRecovery.originalFolder(for: row.sourcePath) != nil
        }
    }
    var hasIncompleteInsta360RescanRecording: Bool { insta360RescanRecovery?.hasIncompleteRecordings == true }
    var hasInsta360RescanConflict: Bool {
        guard let insta360RescanRecovery else { return false }
        return previewRows.contains { row in
            guard case .filenameConflict = row.disposition else { return false }
            return insta360RescanRecovery.includes(sourcePath: row.sourcePath)
        }
    }
    @Published private(set) var scanBothSession: ScanBothSession?
    private var previousScanBothSession: ScanBothSession?
    @Published private(set) var currentImportReceipt: CompletedImportReceipt? {
        didSet {
            rebuildSourceEjectionTargetCache()
        }
    }
    var currentResult: ImportResult? { currentImportReceipt?.result }
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
    @Published private var mountPrompts = MountedDevicePromptCoordinator() {
        didSet {
            if oldValue.pendingPrompt != nil, mountPrompts.pendingPrompt == nil {
                schedulePendingMountHandoffRetry()
            }
        }
    }
    var pendingMountPrompt: MountedDevicePrompt? { mountPrompts.pendingPrompt }
    @Published var reportPresentation: ImportReportPresentation?
    @Published var statusMessage = "" {
        didSet {
            statusMessageRenderer = nil
            statusMessageIsBackgroundPromptFeedback = false
        }
    }
    @Published var isShowingFeedbackEmailUnavailable = false
    @Published private(set) var settingsFeedback: SettingsFeedback?
    @Published private(set) var folderAccessFeedback: RelocalizableMessage? {
        didSet {
            if folderAccessFeedback == nil {
                folderAccessFeedbackIsScanBothCollision = false
            }
        }
    }
    private var folderAccessFeedbackIsScanBothCollision = false
    private var statusMessageRenderer: (() -> String)?
    private var statusMessageIsBackgroundPromptFeedback = false
    private var importFailureRenderer: (() -> String)?

    private func setLocalizedStatusMessage(_ render: @escaping () -> String) {
        statusMessage = render()
        statusMessageRenderer = render
    }

    private func showFolderAccessError(isScanBothCollision: Bool = false, _ render: @escaping () -> String) {
        setLocalizedStatusMessage(render)
        folderAccessFeedbackIsScanBothCollision = isScanBothCollision
        folderAccessFeedback = RelocalizableMessage(statusMessage, render: render)
    }

    private func setSettingsFeedbackFromStatus(role: SettingsFeedback.Role) {
        settingsFeedback = SettingsFeedback(message: statusMessage, role: role, render: statusMessageRenderer)
    }

    private func setBackgroundPromptFeedback(
        role: SettingsFeedback.Role? = nil,
        _ render: @escaping () -> String
    ) {
        guard !isRepairingBackgroundPrompt else { return }
        setLocalizedStatusMessage(render)
        statusMessageIsBackgroundPromptFeedback = true
        if let role {
            settingsFeedback = SettingsFeedback(
                message: statusMessage, role: role, render: render, isBackgroundPrompt: true
            )
            return
        }
        settingsFeedback = SettingsFeedback(currentValue: { [weak self] in
            guard let self else { return ("", .error) }
            return (
                self.backgroundPromptStatusDetail,
                self.backgroundPromptNeedsAttention ? .error : .information
            )
        })
    }

    private func refreshBackgroundPromptSettingsFeedbackIfNeeded() {
        if let refreshed = settingsFeedback?.refreshedForStateChange() {
            settingsFeedback = refreshed
        }
    }

    func interfaceLanguageDidChange(from previous: AppLanguage, to selected: AppLanguage) {
        let previousStatus = statusMessage
        if let content = setupErrorContent {
            let localized = content.relocalized(from: previous, to: selected)
            setupErrorContent = localized
            setupError = localized.text
        }
        if let error = backgroundPromptLastError {
            if let content = backgroundPromptLastErrorContent {
                let localized = content.relocalized(from: previous, to: selected)
                backgroundPromptLastError = localized.text
                backgroundPromptLastErrorContent = localized
            } else {
                backgroundPromptLastError = L10n.relocalizedStaticMessage(error, from: previous, to: selected)
            }
        }
        if let timeout = backgroundPromptLaunchTimeout {
            backgroundPromptLaunchTimeout = timeout.relocalized(from: previous, to: selected)
        }
        let wasBackgroundPromptFeedback = statusMessageIsBackgroundPromptFeedback
        if let render = statusMessageRenderer {
            statusMessage = render()
            statusMessageRenderer = render
        } else {
            statusMessage = L10n.relocalizedStaticMessage(statusMessage, from: previous, to: selected)
        }
        statusMessageIsBackgroundPromptFeedback = wasBackgroundPromptFeedback
        if let feedback = settingsFeedback {
            settingsFeedback = feedback.relocalized(from: previous, to: selected)
        }
        if let feedback = folderAccessFeedback {
            folderAccessFeedback = feedback.relocalized(from: previous, to: selected)
        }
        if let failure = importFailure {
            importFailure = ImportFailureState(
                operation: failure.operation,
                message: importFailureRenderer?()
                    ?? (failure.message == previousStatus
                        ? statusMessage
                        : L10n.relocalizedStaticMessage(failure.message, from: previous, to: selected))
            )
        }
    }
    @Published private var importAttempt: ImportWorkspaceAttempt?
    var isWorking: Bool { importAttempt.map { $0.operation != .eject } ?? false }
    var canCancelReimportSelection: Bool { reimportSelectionCancellation?.canCancel == true }
    var isEjectingSource: Bool { importAttempt?.operation == .eject }
    @Published private(set) var ejectedSourceJobID: String?
    @Published private(set) var ejectedSourceName: String?
    @Published private(set) var ejectedSourceVolumeCount = 0
    @Published var setupError: String? {
        didSet {
            if setupError == nil {
                setupErrorContent = nil
            }
        }
    }
    private var setupErrorContent: RelocalizableMessage?

    private let defaults: UserDefaults
    private let loginItem: LoginItemController
    private let backgroundPromptStateStore: () throws -> BackgroundPromptAgentStateStore
    private let backgroundPrompt: BackgroundPromptCoordinator
    private let purchaseManager: PurchaseManager
    private let scanBothMountLookup: @Sendable (MountedVolume) -> MountedVolume?
    private let destinationCapacity: DestinationSpaceChecker.CapacityProvider
    private let observeCopyProgress: (@Sendable (ImportProgress) -> Void)?
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
    private var reimportSelectionCancellation: ReimportSelectionCancellation?
    private var isRunningScanBothImports = false
    @Published private var activeCopySources: ActiveCopySources?
    var importDisconnectionMessage: String? {
        activeCopySources?.disconnectedVolume.map { Self.importDisconnectedMessage($0) }
    }
    private var historyRefreshTask: Task<Void, Never>?
    private var historyDetailTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var sourceEjectionTask: Task<Void, Never>?
    var backgroundPromptOperationTask: Task<Void, Never>? { backgroundPrompt.operationTask }
    private var mountedVolumesSnapshot: [MountedVolume] = []
    private var cachedSelectedSourceEjectionTarget: SourceEjectionTarget?
    private var cachedResultSourceEjectionTargets: [String: SourceEjectionTarget] = [:]
    private var copyEjectionDestinations: (jobID: String, paths: Set<String>?)?
    private var mountObserver: MountEventObserver?
    private var pendingMountHandoffRetryTask: Task<Void, Never>?
    private var activeImportRetryContext: ImportRetryContext?
    private var failedImportRetryContext: ImportRetryContext?
    private var workflowProfilesByVolume: [String: ImportWorkflowProfile] = [:]
    private var preferredMixedDestinationLayout: ImportDestinationLayout = .singleLibrary
    private var hiddenRecentPaths: Set<String> = []
    private var workflowProfileWasManuallyChosenForCurrentJob = false
    private var singleScanMount: (jobID: String, volume: MountedVolume)?
    @Published private var jobsRequiringRescan: Set<String> = []
    var isShowingScanBothResults: Bool {
        scanBothSession != nil && scanBothSession?.reviewingJobID == nil
    }
    var isReviewingScanBothVolume: Bool { scanBothSession?.reviewingJobID != nil }
    var isScanBothPlanLocked: Bool {
        isReviewingScanBothVolume && scanBothSession?.hasStartedImports == true
    }
    private var reviewSharedDestinationPath: String? {
        isReviewingScanBothVolume ? scanBothSession?.destinationPath : nil
    }
    var scanBothDestinationValidation: PathValidationResult {
        validateScanBothDestination(scanBothSession?.destinationPath ?? "")
    }
    var scanBothDestinationChangeMessage: String? {
        guard let session = scanBothSession, let root = session.destinationRoot else { return nil }
        let validation = scanBothDestinationValidation
        guard validation.status == .missing || validation.status == .notDirectory
                || (validation.isUsable && !root.matches()) else { return nil }
        return Self.scanBothDestinationChangedMessage(hasStartedImports: session.hasStartedImports)
    }

    private static func scanBothDestinationChangedMessage(hasStartedImports: Bool) -> String {
        hasStartedImports
            ? L10n.tr("Restore the original destination folder or start a new scan.")
            : L10n.tr("The shared destination changed. Choose the folder again.")
    }
    var scanBothDestinationNeedsAccess: Bool {
        let validation = scanBothDestinationValidation
        return destinationNeedsAccess(validation, additionalAccess: scanBothDestinationAccess)
    }
    var canStartScanBothImports: Bool {
        isShowingScanBothResults && !isWorking && !isEjectingSource && scanBothSession?.canStartImports == true
    }
    var activeScanBothImportVolumeName: String? {
        guard isRunningScanBothImports, let session = scanBothSession, let entry = session.reviewingEntry else {
            return nil
        }
        return session.volumeTitle(for: entry)
    }
    var importSourcePath: String {
        if isReviewingScanBothVolume, let currentSummary { return currentSummary.mountPath }
        return cardPath
    }
    private var scanBothSourceAccess: SecurityScopedResourceAccess? { scanBothSession?.reviewingEntry?.access }
    private var scanBothDestinationAccess: [SecurityScopedResourceAccess] {
        [scanBothSession?.destinationAccess].compactMap { $0 }
    }

    private var knownImportedPreviewFileIDs: Set<Int64> = []
    private var scanBothReviewHistory: [Int64: ImportHistoryMatch] = [:]
    private var currentPreviewFiles: [JobFileRecord] = [] {
        didSet {
            rebuildPreviewPlanCache()
        }
    }

    init(
        purchaseManager: PurchaseManager,
        defaults: UserDefaults = .standard,
        loginItem: LoginItemController = .live,
        backgroundPromptStateStore: @escaping () throws -> BackgroundPromptAgentStateStore = {
            try BackgroundPromptAgentStateStore.defaultStore()
        },
        backgroundPromptSleep: @escaping BackgroundPromptRetryScheduler.Sleep = { try await Task.sleep(for: $0) },
        backgroundPromptRetryNow: @escaping () -> Date = Date.init,
        startsBootstrap: Bool = true,
        scanBothMountLookup: (@Sendable (MountedVolume) -> MountedVolume?)? = nil,
        destinationCapacity: @escaping DestinationSpaceChecker.CapacityProvider = DestinationSpaceChecker.fileSystemCapacity,
        observeCopyProgress: (@Sendable (ImportProgress) -> Void)? = nil
    ) {
        self.purchaseManager = purchaseManager
        self.scanBothMountLookup = scanBothMountLookup ?? Self.currentPromptVolume
        self.destinationCapacity = destinationCapacity
        self.observeCopyProgress = observeCopyProgress
        self.defaults = defaults
        self.loginItem = loginItem
        self.backgroundPromptStateStore = backgroundPromptStateStore
        self.backgroundPrompt = BackgroundPromptCoordinator(
            defaults: defaults, sleep: backgroundPromptSleep, now: backgroundPromptRetryNow
        )
        self.backgroundPromptApplicationOwnership = loginItem.applicationOwnership
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
        if startsBootstrap {
            bootstrap()
        }
    }

    func bootstrap(at suppliedStateURL: URL? = nil, startsRuntimeServices: Bool = true) {
        do {
            let stateURL = try suppliedStateURL ?? DatabasePoolFactory.defaultApplicationSupportDirectory()
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
            guard startsRuntimeServices else { return }
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
                            ? L10n.tr("Imported legacy SD Import history")
                            : L10n.tr("Imported legacy SD Import settings")
                    } else {
                        legacyImportMessage = nil
                    }
                } catch {
                    legacyImportMessage = L10n.tr("Legacy import skipped: \(Self.errorMessage(for: error))")
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
                        L10n.tr("Could not persist the background helper QA preparation state")
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
            recoverInterruptedImports(databaseURL: databaseURL)
            refreshAvailableSourceVolumes()
            validatePaths()
            validateDefaultPaths()
            refreshHistory()
            loginItem.invalidateApplicationOwnershipCache()
            refreshBackgroundPromptHealth()
            do {
                try authorizeCurrentBackgroundPromptHelperIfNeeded()
            } catch {
                let render = { L10n.tr("Could not authorize the background helper: \(Self.errorMessage(for: error))") }
                recordBackgroundPromptError(render(), render: render)
            }
            startMountObserver()
            reconcileBackgroundPromptRegistration()
            statusMessage = legacyImportMessage ?? L10n.tr("Ready")
        } catch {
            let render = { Self.errorMessage(for: error) }
            let content = RelocalizableMessage(render(), render: render)
            setupErrorContent = content
            setupError = content.text
            statusMessage = L10n.tr("Setup failed")
        }
    }

    private func recoverInterruptedImports(databaseURL: URL) {
        let access = folderAccesses.values.filter(\.isActive)
        let portable = portableImportReceiptsEnabled
        Task.detached(priority: .utility) { [weak self] in
            defer { withExtendedLifetime(access) {} }
            do {
                let repository = try Self.makeRepositories(databaseURL: databaseURL).jobRepository
                let recovery = try RecoveryService(jobRepository: repository, portableReceiptsEnabled: portable)
                    .recoverInterruptedImports()
                guard recovery.recoveredJobs > 0 else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.refreshHistory()
                    if self.importAttempt == nil, self.statusMessage == L10n.tr("Ready") {
                        self.statusMessage = L10n.tr("Recovered interrupted import")
                    }
                }
            } catch {
                importLogger.error("Import recovery failed errorType=\(String(describing: type(of: error)), privacy: .public)")
            }
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
                setLocalizedStatusMessage { Self.errorMessage(for: error) }
                setSettingsFeedbackFromStatus(role: .error)
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
            setLocalizedStatusMessage { L10n.tr("Could not save settings: \(Self.errorMessage(for: error))") }
            setSettingsFeedbackFromStatus(role: .error)
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
            setLocalizedStatusMessage {
                L10n.tr("Settings saved, but folder access could not be refreshed: \(Self.errorMessage(for: error))")
            }
            setSettingsFeedbackFromStatus(role: .error)
            return AppDistribution.current != .macAppStore
        }
        return true
    }

    func chooseCardFolder() {
        guard let url = pickCardFolder(startingAt: cardPath) else { return }
        selectSourcePath(url.path)
    }

    private func pickCardFolder(startingAt path: String) -> URL? {
        guard let url = chooseCardFolderURL(startingAt: path),
              retainSelectedFolderAccess(.source, url: url, persistBookmark: true) else { return nil }
        return url
    }

    private func chooseCardFolderURL(startingAt path: String) -> URL? {
        FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Choose SD Card or Source Folder"),
            initialPath: path
        )
    }

    func chooseOnboardingCardFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Choose SD Card or Source Folder"),
            initialPath: sourceValidation.expandedPath,
            prompt: sourceNeedsAccess ? L10n.tr("Allow Access") : nil
        ), retainSelectedFolderAccess(.source, url: url, persistBookmark: true) else {
            return
        }
        cardPath = url.path
        sourcePathDidChange()
    }

    func chooseOnboardingPhotosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Choose Photo Destination"),
            initialPath: photosValidation.expandedPath,
            prompt: destinationNeedsAccess(photosValidation) ? L10n.tr("Allow Access") : nil
        ), retainSelectedFolderAccess(.photos, url: url, persistBookmark: true) else {
            return
        }
        photosPath = url.path
        destinationPathDidChange()
    }

    func chooseOnboardingVideosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Choose Video Destination"),
            initialPath: videosValidation.expandedPath,
            prompt: destinationNeedsAccess(videosValidation) ? L10n.tr("Allow Access") : nil
        ), retainSelectedFolderAccess(.videos, url: url, persistBookmark: true) else {
            return
        }
        videosPath = url.path
        destinationPathDidChange()
    }

    func choosePhotosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Choose Photo Destination"),
            initialPath: photosValidation.expandedPath,
            prompt: destinationNeedsAccess(photosValidation) ? L10n.tr("Allow Access") : nil
        ), retainSelectedFolderAccess(.photos, url: url, persistBookmark: false) else {
            return
        }
        unhideRecentPath(url.path)
        photosPath = url.path
        destinationPathDidChange()
    }

    func chooseVideosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Choose Video Destination"),
            initialPath: videosValidation.expandedPath,
            prompt: destinationNeedsAccess(videosValidation) ? L10n.tr("Allow Access") : nil
        ), retainSelectedFolderAccess(.videos, url: url, persistBookmark: false) else {
            return
        }
        unhideRecentPath(url.path)
        videosPath = url.path
        destinationPathDidChange()
    }

    func chooseScanBothDestination() {
        guard !isWorking, !isEjectingSource, let session = scanBothSession,
              !session.hasStartedImports || scanBothDestinationNeedsAccess,
              let url = FilePanelPresenter.chooseDirectoryURL(
                  title: L10n.tr("Shared Destination"),
                  initialPath: session.destinationPath,
                  prompt: scanBothDestinationNeedsAccess ? L10n.tr("Allow Access") : nil
              ) else { return }
        setScanBothDestination(url)
    }

    func setScanBothDestination(_ url: URL) {
        guard !isWorking, !isEjectingSource, scanBothSession != nil else { return }
        let path = url.standardizedFileURL.path
        let access = SecurityScopedResourceAccess(url: url)
        let validation = validateScanBothDestination(path)
        guard validation.isUsable else {
            showFolderAccessError { validation.message }
            return
        }
        guard AppDistribution.current != .macAppStore || access.isActive else {
            showFolderAccessError { L10n.tr("The destination folder is unavailable.") }
            return
        }
        guard let root = ReviewedImportDestinations.Root(
            at: URL(fileURLWithPath: validation.expandedPath, isDirectory: true)
        ) else {
            showFolderAccessError { L10n.tr("The destination folder is unavailable.") }
            return
        }
        guard scanBothSession?.setDestination(root, access: access.isActive ? access : nil) == true else {
            showFolderAccessError { Self.scanBothDestinationChangedMessage(hasStartedImports: true) }
            return
        }
        folderAccessFeedback = nil
        rebuildSharedScanBothReview()
        if isReviewingScanBothVolume {
            destinationPathDidChange()
        }
    }

    private func validateScanBothDestination(_ path: String) -> PathValidationResult {
        PathValidator().validate(path: path, purpose: .destination, allowsWhitespaceFallback: false)
    }

    func chooseDefaultPhotosFolder() {
        guard let url = FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Choose Default Photo Destination"),
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
            title: L10n.tr("Choose Default Video Destination"),
            initialPath: importDefaults.videosPath
        ), retainSelectedFolderAccess(.videos, url: url, persistBookmark: true) else {
            return
        }
        importDefaults.videosPath = url.path
        defaultDestinationPathDidChange()
        savePreferences()
    }

    func refreshAvailableSourceVolumes(
        including mountedVolume: MountedVolume? = nil,
        excluding unmountedURL: URL? = nil
    ) {
        let detector = VolumeDetector()
        var volumes = detector.allMountedVolumes(
            includeCapacity: AppDistribution.current.mountPrivacyPolicy.includesCapacityBeforeConsent
        )
        let unmountedPath = unmountedURL?.standardizedFileURL.path
        if let unmountedPath {
            volumes.removeAll { $0.mountURL.standardizedFileURL.path == unmountedPath }
            noteScanBothUnmount(at: unmountedPath)
        }
        // Workspace notifications can arrive ahead of /Volumes enumeration.
        if let mountedVolume, !volumes.contains(where: {
            $0.mountURL.standardizedFileURL.path == mountedVolume.mountURL.standardizedFileURL.path
        }), Self.currentPromptVolume(matching: mountedVolume) != nil {
            volumes.append(mountedVolume)
        }
        let observedPaths = Set(volumes.map { $0.mountURL.standardizedFileURL.path })
        volumes += availableSourceVolumes.filter { volume in
            let path = volume.mountURL.standardizedFileURL.path
            return path != unmountedPath && !observedPaths.contains(path)
                && Self.currentPromptVolume(matching: volume) != nil
        }
        mountedVolumesSnapshot = volumes
        let sourceVolumes = detector.likelyImportVolumes(from: mountedVolumesSnapshot)
#if DEBUG
        availableSourceVolumes = BackgroundPromptRuntimeQA.retainingLivePromptVolume(
            mountObserver?.runtimeQAPromptVolume,
            in: sourceVolumes
        ) { Self.currentPromptVolume(matching: $0) != nil }
#else
        availableSourceVolumes = sourceVolumes
#endif
        mountPrompts.updateMountedVolumes(availableSourceVolumes)
        rebuildSourceEjectionTargetCache()
        rebuildRecentImportSuggestions()
    }

    var availableSourceDeviceGroups: [MountedDeviceGroup] {
        MountedDeviceGrouper().groups(from: availableSourceVolumes)
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
            return L10n.tr("Ejecting Source…")
        }
        guard let target = cachedSelectedSourceEjectionTarget else {
            return L10n.tr("Eject Source")
        }
        if target.volumeCount > 1 {
            return L10n.tr("Eject \(target.displayName) — \(target.volumeCount) Volumes")
        }
        return L10n.tr("Eject \(target.displayName)")
    }

    func ejectSelectedSource() {
        guard
            AppDistribution.current.supportsSourceEjection,
            !isWorking,
            !isEjectingSource,
            let target = cachedSelectedSourceEjectionTarget
        else {
            statusMessage = L10n.tr("Source cannot be ejected safely")
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
        statusMessage = L10n.tr("Recent folder forgotten")
    }

    func restoreForgottenRecentPaths() {
        guard !hiddenRecentPaths.isEmpty else {
            return
        }

        hiddenRecentPaths.removeAll()
        rebuildRecentPathSuggestions()
        savePreferences()
        statusMessage = L10n.tr("Recent folders restored")
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
        scanBothSession = nil
        singleScanMount = nil
        clearSourceReview()
    }

    func changeScanBothSource() {
        guard !isWorking, !isEjectingSource else { return }
        if scanBothSession?.hasPendingResults == true {
            guard confirmLeavingScanBothResults(
                actionTitle: L10n.tr("Change Source"),
                message: L10n.tr("The current scan and review will be discarded. No copied files are deleted.")
            ), let url = pickCardFolder(startingAt: cardPath),
               let path = validatedSelectedSourcePath(url) else { return }
            selectSourcePath(path)
        } else {
            sourcePathDidChange()
        }
    }

    private func confirmLeavingScanBothResults(actionTitle: String, message: String? = nil) -> Bool {
        guard scanBothSession?.hasPendingResults == true else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Discard pending scan results?")
        alert.informativeText = message
            ?? L10n.tr("Starting a new scan closes this Scan Both session. Any remaining volumes will need a new scan.")
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: L10n.tr("Keep Scan Results")).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func clearSourceReview() {
        folderAccessFeedback = nil
        insta360RescanRecovery = nil
        rescanContext = nil
        currentSummary = nil
        currentImportReceipt = nil
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

    func destinationPathDidChange(clearFeedback: Bool = true) {
        if clearFeedback, !isShowingScanBothResults {
            folderAccessFeedback = nil
        }
        validatePaths()
        rebuildPreviewPlanCache(refreshingDates: true)
    }

    func defaultDestinationPathDidChange() {
        validateDefaultPaths()
    }

    var currentImportDraft: ImportDraft {
        ImportDraft(
            sourcePath: importSourcePath,
            photosPath: reviewSharedDestinationPath ?? photosPath,
            videosPath: reviewSharedDestinationPath ?? videosPath,
            shootName: location,
            workflowProfile: workflowProfile,
            mediaSelection: importMediaSelection,
            destinationLayout: destinationLayout,
            folderGrouping: folderGrouping,
            sessions: previewSessions,
            hiddenSessions: hiddenPreviewSessions
        )
    }

    var importDraftUsesDefaults: Bool {
        (isReviewingScanBothVolume
            || (photosPath == importDefaults.photosPath && videosPath == importDefaults.videosPath))
            && Self.defaultSessionLabel(for: location) == Self.defaultSessionLabel(for: importDefaults.shootName)
            && workflowProfile == importDefaults.workflowProfile
            && importMediaSelection == importDefaults.mediaSelection
            && destinationLayout == importDefaults.destinationLayout
            && folderGrouping == importDefaults.folderGrouping
    }

    func saveImportDraftAsDefaults() {
        guard !isScanBothPlanLocked else { return }
        let previousDefaults = importDefaults
        let savesDestinations = !isReviewingScanBothVolume
        importDefaults = ImportDefaults(
            photosPath: savesDestinations ? photosPath : previousDefaults.photosPath,
            videosPath: savesDestinations ? videosPath : previousDefaults.videosPath,
            shootName: Self.defaultSessionLabel(for: location),
            workflowProfile: workflowProfile,
            mediaSelection: importMediaSelection,
            destinationLayout: destinationLayout,
            preferredMixedDestinationLayout: preferredMixedDestinationLayout,
            folderGrouping: folderGrouping
        )
        validateDefaultPaths()
        if savePreferences(
            refreshFolderBookmarks: savesDestinations,
            folderBookmarkPurposes: Set([.source] + requiredDestinationPurposes())
        ) {
            if settingsFeedback == nil {
                statusMessage = L10n.tr("Import settings saved as defaults")
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
        sourceValidation = validator.validate(
            path: importSourcePath, purpose: .source,
            allowsWhitespaceFallback: !isReviewingScanBothVolume
        )
        if isReviewingScanBothVolume {
            photosValidation = scanBothDestinationValidation
            videosValidation = photosValidation
        } else {
            photosValidation = validator.validate(path: photosPath, purpose: .destination)
            videosValidation = validator.validate(path: videosPath, purpose: .destination)
        }
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

    var sourceNeedsAccess: Bool {
        AppDistribution.current.requiresSourceAccess(
            for: sourceValidation.status,
            hasAuthorizedAccess: hasActiveFolderAccess(
                covering: sourceValidation.expandedPath,
                additionalAccess: [scanBothSourceAccess].compactMap { $0 }
            )
        )
    }

    var canStartScan: Bool {
        !isWorking && !isEjectingSource && (sourceValidation.isUsable || sourceNeedsAccess)
    }

    func destinationNeedsAccess(
        _ validation: PathValidationResult, additionalAccess: [SecurityScopedResourceAccess] = []
    ) -> Bool {
        validation.status == .unwritable
            || (validation.isUsable && AppDistribution.current == .macAppStore
                && !hasActiveFolderAccess(covering: validation.expandedPath, additionalAccess: additionalAccess))
    }

    var canImportPlannedFiles: Bool {
        return !isWorking
            && !isEjectingSource
            && currentSummary.map { !needsRescan($0.jobID) } == true
            && previewTotals.copyFiles > 0
            && !previewRows.contains { $0.disposition.attention == .blocking }
            && sourceValidation.isUsable
            && !sourceNeedsAccess
            && requiredDestinationPathsAreUsable()
            && (isReviewingScanBothVolume || previewSpaceRequirements.allSatisfy(\.isSatisfied))
    }

    var importReadinessMessage: String? {
        if previewRows.contains(where: { $0.disposition.attention == .blocking }) {
            return L10n.tr("Conflicts")
        }
        if previewTotals.copyFiles == 0 {
            return L10n.tr("No files are selected for copying")
        }
        if sourceNeedsAccess {
            return L10n.tr("macOS needs your permission to read this source.")
        }
        if !sourceValidation.isUsable {
            return sourceValidation.message
        }
        if !requiredDestinationPathsAreUsable() {
            return (isReviewingScanBothVolume ? scanBothDestinationChangeMessage : nil)
                ?? L10n.tr("Choose usable destination folders")
        }
        if let requirement = previewSpaceRequirements.first(where: { !$0.isKnown }) {
            return L10n.tr("Available space couldn’t be checked for \(requirement.displayPath)")
        }
        if let requirement = previewSpaceRequirements.first(where: { !$0.isSatisfied }) {
            let required = L10n.fileSize(requirement.requiredBytes)
            let available = L10n.fileSize(requirement.availableBytes ?? 0)
            return L10n.tr("\(required) required; \(available) available")
        }
        return nil
    }

    var previewAttentionCount: Int {
        Dictionary(grouping: previewRows, by: previewUnitKey(for:))
            .values
            .filter { rows in
                rows.contains { $0.disposition.attention >= .attention }
            }
            .count
    }

    var previewDestinationIssueCount: Int {
        previewSpaceRequirements.filter { !$0.isSatisfied }.count
    }

    var previewNeedsAttention: Bool {
        previewRows.contains { $0.disposition.attention >= .attention }
            || previewSpaceRequirements.contains { !$0.isSatisfied }
    }

    var canCustomizeDates: Bool {
        guard folderGrouping == .byDay, let date = previewSessions.first else { return false }
        let label = date.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = defaultDateInclusion
        return previewSessions.count > 1
            || (!label.isEmpty && label != Self.defaultSessionLabel(for: location))
            || date.includePhotos != defaults.photos
            || date.includeVideos != defaults.videos
            || date.includeSidecars != defaults.sidecars
            || previewRows.contains { row in
                guard row.date == date.date, case .filenameConflict = row.disposition else { return false }
                return true
            }
    }

    func scan() {
        guard !isWorking, !isEjectingSource else {
            statusMessage = L10n.tr("Finish the current scan or import first")
            return
        }
        guard confirmLeavingScanBothResults(actionTitle: L10n.tr("Start New Scan")) else { return }
        guard let databaseURL else {
            statusMessage = L10n.tr("Database is not ready")
            return
        }
        validatePaths()
        let selectedURL: URL?
        if sourceNeedsAccess {
            guard let url = chooseAccessForSelectedSource() else { return }
            selectedURL = url
        } else {
            guard sourceValidation.isUsable else {
                let validation = sourceValidation
                setLocalizedStatusMessage { validation.message }
                return
            }
            selectedURL = nil
        }
        let sourceAccess = selectedURL.map { SecurityScopedResourceAccess(url: $0) }
        defer { withExtendedLifetime(sourceAccess) {} }
        let path: String
        if let selectedURL {
            guard let chosenPath = validatedSelectedSourcePath(selectedURL) else { return }
            path = chosenPath
        } else {
            path = resolvedPath(cardPath, validation: sourceValidation)
        }

        let recovering: RescanContext?
        if let rescanContext {
            guard let context = prepareRescan(rescanContext.jobID, sourcePath: path) else { return }
            recovering = context
        } else {
            recovering = nil
        }
        if let selectedURL {
            guard retainSelectedFolderAccess(.source, url: selectedURL, persistBookmark: true) else { return }
            retainPendingScanBothResults()
            selectSourcePath(path)
        }
        startScan(at: path, databaseURL: databaseURL, recovering: recovering)
    }

    private func validatedSelectedSourcePath(_ url: URL) -> String? {
        let validation = PathValidator().validate(
            path: url.path, purpose: .source, allowsWhitespaceFallback: false
        )
        guard validation.isUsable else {
            showFolderAccessError { validation.message }
            return nil
        }
        return validation.expandedPath
    }

    private func startScan(
        at cardPath: String,
        databaseURL: URL,
        recovering: RescanContext? = nil
    ) {
        retainPendingScanBothResults()
        savePreferences()
        scanBothSession = nil
        singleScanMount = nil
        insta360RescanRecovery = nil
        rescanContext = recovering
        currentImportReceipt = nil
        importProgress = nil
        ejectedSourceJobID = nil
        ejectedSourceName = nil
        ejectedSourceVolumeCount = 0
        previewSessions = []
        currentPreviewFiles = []
        clearPreviewPlanCache()
        let attemptID = beginImportAttempt(.scan, event: .beginScan)
        statusMessage = L10n.tr("Scanning...")
        importLogger.info("Scan started")

        let sourceURL = URL(fileURLWithPath: cardPath, isDirectory: true)
        let sourceVolume = VolumeDetector().removableSourceVolume(containing: sourceURL)
        let request = scanRequest(
            mountURL: sourceURL,
            sourceVolume: sourceVolume,
            rescanOfJobID: recovering?.jobID
        )
        singleScanMount = sourceVolume.map { (jobID: request.jobID, volume: $0) }
        let retainedAccess = Array(folderAccesses.values) + (recovering?.access ?? [])

        importTask = Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(retainedAccess) {} }
            do {
                try Task.checkCancellation()
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                if let recovering {
                    try RecoveryService(
                        jobRepository: repositories.jobRepository, portableReceiptsEnabled: request.portableReceiptsEnabled
                    ).recoverInterruptedImport(jobID: recovering.jobID, preparation: recovering.preparation)
                    try Task.checkCancellation()
                }
                let scanner = MediaScanner(
                    jobRepository: repositories.jobRepository,
                    dedupeRepository: repositories.dedupeRepository
                )
                let summary = try scanner.scan(request) {
                    Task.isCancelled
                }
                try Task.checkCancellation()
                let jobs = try repositories.jobRepository.listImportHistoryJobs(limit: 100)
                let files = try repositories.jobRepository.fetchJobFiles(jobID: summary.jobID)
                let insta360Recovery = try recovering.map { _ in
                    try Insta360RescanRecovery(
                        request: request, scannedFiles: files, jobRepository: repositories.jobRepository
                    )
                }
                try Task.checkCancellation()

                await MainActor.run {
                    guard let attempt = self.importAttempt, attempt.accepts(attemptID) else { return }
                    if attempt.cancellationRequested {
                        self.currentSummary = nil
                        self.statusMessage = L10n.tr("Scan cancelled")
                        self.finishScanAttempt(attemptID, event: .cancelled)
                        return
                    }
                    self.jobs = jobs
                    self.loadScanPreview(
                        summary, files: files, dedupeRepository: repositories.dedupeRepository,
                        insta360Recovery: insta360Recovery,
                        rescanContext: recovering.map { RescanContext(jobID: summary.jobID, access: $0.access) }
                    )
                    if let warning = summary.portableReceiptWarning {
                        self.setLocalizedStatusMessage {
                            let localizedWarning = L10n.portableReceiptWarning(
                                warning, sizeWarning: summary.portableReceiptSizeWarning
                            )
                            return L10n.tr("Scan complete. \(localizedWarning)")
                        }
                    } else if let portableKnownFiles = summary.portableKnownFiles, portableKnownFiles > 0 {
                        self.setLocalizedStatusMessage { L10n.tr("Scan complete. \(portableKnownFiles) files were imported on another Mac") }
                    } else {
                        self.statusMessage = L10n.tr("Scan complete")
                    }
                    self.finishScanAttempt(attemptID, event: .scanSucceeded)
                }
                importLogger.info(
                    "Scan complete scanned=\(summary.scannedFiles, privacy: .public) new=\(summary.newFiles, privacy: .public) known=\(summary.knownFiles, privacy: .public) sidecars=\(summary.unsupportedFiles, privacy: .public) conflicts=\(summary.conflictFiles, privacy: .public)"
                )
            } catch is CancellationError {
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    self.statusMessage = L10n.tr("Scan cancelled")
                    self.finishScanAttempt(attemptID, event: .cancelled)
                }
                importLogger.notice("Scan cancelled")
            } catch SDImportError.cancelled {
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    self.statusMessage = L10n.tr("Scan cancelled")
                    self.finishScanAttempt(attemptID, event: .cancelled)
                }
                importLogger.notice("Scan cancelled")
            } catch {
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    self.currentSummary = nil
                    self.previewSessions = []
                    self.currentPreviewFiles = []
                    self.knownImportedPreviewFileIDs = []
                    self.clearPreviewPlanCache()
                    let render: () -> String = { L10n.tr("Scan failed: \(Self.errorMessage(for: error))") }
                    self.setLocalizedStatusMessage(render)
                    let message = self.statusMessage
                    self.finishScanAttempt(
                        attemptID, event: .failed(operation: .scan, message: message), failureRenderer: render
                    )
                }
                importLogger.error("Scan failed errorType=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    private func retainPendingScanBothResults() {
        guard var session = scanBothSession, session.hasPendingResults else { return }
        if let jobID = session.reviewingJobID, currentSummary?.jobID == jobID {
            session.saveDraft(currentImportDraft, needsAttention: previewNeedsAttention, for: jobID)
        }
        session.reviewingJobID = nil
        previousScanBothSession = session
    }

    private func finishScanAttempt(
        _ id: UUID,
        event: ImportWorkspaceEvent,
        failureRenderer: (() -> String)? = nil
    ) {
        guard importAttempt?.accepts(id) == true else { return }
        let previous = previousScanBothSession
        previousScanBothSession = nil
        if let previous, event != .scanSucceeded {
            singleScanMount = nil
            scanBothSession = previous
            if let failureRenderer { showFolderAccessError(failureRenderer) }
            finishImportAttempt(id, event: .recover(hasScannedJob: true))
        } else {
            finishImportAttempt(id, event: event, failureRenderer: failureRenderer)
        }
    }

    private func scanRequest(
        mountURL: URL, sourceVolume: MountedVolume?, rescanOfJobID: String? = nil,
        plansDestinations: Bool = true
    ) -> ScanRequest {
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
        return ScanRequest(
            mountURL: mountURL,
            volumeName: sourceVolume?.name ?? mountURL.lastPathComponent,
            volumeUUID: sourceVolume?.volumeUUID,
            location: Self.defaultSessionLabel(for: location),
            roots: DestinationRoots(
                photosURL: URL(fileURLWithPath: photosPath, isDirectory: true),
                videosURL: URL(fileURLWithPath: videosPath, isDirectory: true)
            ),
            reportsDirectoryURL: reportsURL,
            portableReceiptsEnabled: portableImportReceiptsEnabled,
            volumeMountPath: sourceVolume?.mountPath,
            rescanOfJobID: rescanOfJobID,
            plansDestinations: plansDestinations
        )
    }

    func useImportMediaSelection(_ selection: ImportMediaSelection) {
        guard !isScanBothPlanLocked else { return }
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
        guard !isScanBothPlanLocked, importMediaSelection == .photosAndVideos else {
            return
        }
        destinationLayout = layout == .footageBackup ? .singleLibrary : layout
        preferredMixedDestinationLayout = destinationLayout
        applyCurrentImportOptions(userInitiated: true)
    }

    func useFolderGrouping(_ grouping: ImportFolderGrouping) {
        guard !isScanBothPlanLocked else { return }
        folderGrouping = grouping
        folderGroupingDidChange()
    }

    func setPreviewSessionInclusion(
        _ keyPath: WritableKeyPath<ImportPreviewSession, Bool>,
        to isIncluded: Bool
    ) {
        guard !isScanBothPlanLocked else { return }
        updatePreviewSessionChoices { session in
            session[keyPath: keyPath] = isIncluded
        }
    }

    private func updatePreviewSessionChoices(
        refreshingDates: Bool = false, _ update: (inout ImportPreviewSession) -> Void
    ) {
        func updated(_ session: ImportPreviewSession) -> ImportPreviewSession {
            var session = session
            update(&session)
            return session
        }

        hiddenPreviewSessions = hiddenPreviewSessions.mapValues(updated)
        let sessions = previewSessions.map(updated)
        if !refreshingDates || refreshScanBothPreviewDates(previousSessions: sessions) == nil {
            previewSessions = sessions
        }
    }

    func folderGroupingDidChange() {
        rebuildPreviewPlanCache(refreshingDates: true)
    }

    func themePreferenceDidChange() {
        savePreferences()
    }

    func applyWorkflowProfile(_ profile: ImportWorkflowProfile, userInitiated: Bool = true) {
        guard !userInitiated || !isScanBothPlanLocked else { return }
        workflowProfile = profile
        importMediaSelection = profile.mediaSelection
        destinationLayout = profile.mediaSelection == .photosAndVideos
            ? preferredMixedDestinationLayout
            : ImportDestinationLayout(organizationPreset: profile.organizationPreset)
        organizationPreset = destinationLayout.organizationPreset
        validatePaths()
        updatePreviewSessionChoices(refreshingDates: userInitiated) { session in
            session.includePhotos = profile.mediaSelection.includes(.photo)
            session.includeVideos = profile.mediaSelection.includes(.video)
            session.includeSidecars = profile.includesSidecarsByDefault
        }
        if userInitiated {
            workflowProfileWasManuallyChosenForCurrentJob = true
        }
    }

    private func applyCurrentImportOptions(userInitiated: Bool) {
        normalizeDestinationForCurrentImportType()
        updateWorkflowProfileForCurrentOptions()
        validatePaths()

        updatePreviewSessionChoices(refreshingDates: true) { session in
            session.includePhotos = importMediaSelection.includes(.photo)
            session.includeVideos = importMediaSelection.includes(.video)
            session.includeSidecars = workflowProfile.includesSidecarsByDefault
        }
        if userInitiated {
            workflowProfileWasManuallyChosenForCurrentJob = true
        }
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

    private func rebuildPreviewPlanCache(refreshingDates: Bool = false) {
        if refreshingDates, refreshScanBothPreviewDates() != nil {
            return
        }
        let plans = makePreviewPlan(files: currentPreviewFiles, sessions: previewSessions)?.files ?? []
        updatePreviewPlanCache(rows: makePreviewRows(files: currentPreviewFiles, plans: plans))
    }

    private func updatePreviewPlanCache(rows: [ImportPreviewRow]) {
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

    private typealias PreviewPlan = (builder: ImportPlanBuilder, files: [ImportFilePlan])

    private func makePreviewPlan(
        files: [JobFileRecord],
        sessions: [ImportPreviewSession],
        hiddenSessions: [String: ImportPreviewSession]? = nil
    ) -> PreviewPlan? {
        guard let currentSummary else { return nil }
        let builder = ImportPlanBuilder(
            sessions: sessions,
            mediaSelection: importMediaSelection,
            organizationPreset: organizationPreset,
            folderGrouping: folderGrouping,
            roots: effectiveDestinationRoots,
            fallbackLocation: Self.defaultSessionLabel(for: location),
            volumeName: currentSummary.volumeName,
            insta360Recovery: insta360RescanRecovery,
            useOriginalInsta360Folders: useOriginalInsta360Folders,
            hiddenSessions: hiddenSessions ?? hiddenPreviewSessions
        )
        let plans = builder.plans(files: files, refreshedHistory: isReviewingScanBothVolume ? scanBothReviewHistory : [:])
        return (builder, plans)
    }

    private var effectiveDestinationRoots: DestinationRoots {
        if isReviewingScanBothVolume, let root = scanBothSession?.destinationRoot {
            let folder = root.resolvedURL.standardizedFileURL
            return DestinationRoots(photosURL: folder, videosURL: folder)
        }
        return DestinationRoots(
            photosURL: URL(
                fileURLWithPath: resolvedPath(photosPath, validation: photosValidation),
                isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath(),
            videosURL: URL(
                fileURLWithPath: resolvedPath(videosPath, validation: videosValidation),
                isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    private func makePreviewRows(
        files: [JobFileRecord],
        plans: [ImportFilePlan]
    ) -> [ImportPreviewRow] {
        var visualGroups: [Int64: (id: String, kind: ImportPreviewGroupKind)] = [:]
        var canonicalInsta360DateByID: [Int64: String] = [:]
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
        for group in Insta360ClipDetector().groups(files: files) {
            let canonicalDate = group.masterFiles.first.map { ImportPlanBuilder.sessionDate(for: $0) }
            for file in group.files {
                if let id = file.id {
                    visualGroups[id] = (group.id, .insta360Clip)
                    if let canonicalDate {
                        canonicalInsta360DateByID[id] = canonicalDate
                    }
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
                date: canonicalInsta360DateByID[id] ?? ImportPlanBuilder.sessionDate(for: file),
                modificationDateString: file.modificationDateString,
                mediaKind: file.mediaKind,
                sourcePath: file.sourcePath,
                destinationPath: plan.destinationPath,
                disposition: plan.disposition,
                visualGroupID: visualGroups[id]?.id,
                visualGroupKind: visualGroups[id]?.kind,
                willCopy: plan.willCopy,
                size: file.size,
                reimportRequested: file.reimportRequested == true
            )
        }
    }

    private func syncPreviewSessionLabels(from previousLocation: String, to nextLocation: String) {
        let previousLabel = Self.defaultSessionLabel(for: previousLocation)
        let nextLabel = Self.defaultSessionLabel(for: nextLocation)
        guard previousLabel != nextLabel else {
            return
        }

        func updated(_ session: ImportPreviewSession) -> ImportPreviewSession {
            guard Self.defaultSessionLabel(for: session.label) == previousLabel else { return session }
            var session = session
            session.label = nextLabel
            return session
        }

        hiddenPreviewSessions = hiddenPreviewSessions.mapValues(updated)
        let sessions = previewSessions.map(updated)
        if refreshScanBothPreviewDates(previousSessions: sessions) == nil, sessions != previewSessions {
            previewSessions = sessions
        }
    }

    private func buildPreviewTotals(rows: [ImportPreviewRow]) -> ImportPreviewTotals {
        let units = Dictionary(grouping: rows, by: previewUnitKey(for:))
        return ImportPreviewTotals(
            copyFiles: units.values.filter { $0.contains(where: \.willCopy) }.count,
            skippedFiles: units.values.filter { !$0.contains(where: \.willCopy) }.count,
            copyBytes: rows.reduce(Int64(0)) { total, row in
                row.willCopy ? total + row.size : total
            }
        )
    }

    private func previewUnitKey(for row: ImportPreviewRow) -> String {
        if row.visualGroupKind == .insta360Clip, let groupID = row.visualGroupID {
            return "insta360:\(groupID)"
        }
        return "file:\(row.id)"
    }

    private func buildPreviewDestinationDirectories(rows: [ImportPreviewRow]) -> [ImportPreviewDestination] {
        let grouped = Dictionary(grouping: rows.filter(\.willCopy)) { row in
            row.destinationPath.map {
                URL(fileURLWithPath: $0, isDirectory: false).deletingLastPathComponent().path
            } ?? L10n.tr("Unknown")
        }

        return grouped
            .map { path, rows in
                let rootAndRelativePath = previewDestinationRoot(for: path, rows: rows)
                return ImportPreviewDestination(
                    path: path,
                    root: rootAndRelativePath.root,
                    relativePath: rootAndRelativePath.relativePath,
                    fileCount: Set(rows.map(previewUnitKey(for:))).count,
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
        let roots = effectiveDestinationRoots
        let photosRoot = roots.photosURL
        let videosRoot = roots.videosURL

        if destinationLayout == .singleLibrary, isDescendant(destination, of: photosRoot) {
            return (.library, relativePath(from: photosRoot, to: destination))
        }
        if photosRoot == videosRoot, isDescendant(destination, of: photosRoot) {
            let containsFootage = rows.contains {
                $0.mediaKind == .video
                    || $0.visualGroupKind == .videoSidecars
                    || $0.visualGroupKind == .insta360Clip
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

    private func buildPreviewSpaceRequirements(
        rows: [ImportPreviewRow], usingPlanHistory: Bool = false
    ) -> [ImportPreviewSpaceRequirement] {
        var grouped: [String: (capacity: VolumeCapacity, requiredBytes: Int64)] = [:]
        var unknownRequirements: [ImportPreviewSpaceRequirement] = []
        let rowsNeedingSpace = rows.filter { row in
            row.willCopy
                && row.size > 0
                && (usingPlanHistory || isReviewingScanBothVolume || !isKnownImportedFile(row))
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
                guard let capacity = try destinationCapacity(destinationDirectory) else {
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
        !row.reimportRequested && knownImportedPreviewFileIDs.contains(row.id)
            && insta360RescanRecovery?.includes(sourcePath: row.sourcePath) != true
    }

    func importCurrentJob() {
        guard !isWorking, !isEjectingSource else {
            statusMessage = L10n.tr("Finish the current scan or import first")
            return
        }
        if !isReviewingScanBothVolume, !purchaseManager.canStartImport {
            purchaseManager.isShowingPurchase = true
            statusMessage = L10n.tr("Start your 14-day trial or unlock unlimited imports to continue")
            return
        }
        guard let currentSummary else {
            statusMessage = L10n.tr("No scanned job selected")
            return
        }
        let jobID = currentSummary.jobID
        guard !needsRescan(jobID) else { return }
        guard let databaseURL else {
            statusMessage = L10n.tr("Database is not ready")
            return
        }
        guard let plan = validatedImportPlan() else { return }

        savePreferences()
        if isReviewingScanBothVolume {
            guard let entry = scanBothSession?.reviewingEntry, entry.jobID == jobID else { return }
            guard liveScanBothVolume(matching: entry.volume) != nil else {
                requireRescan(for: jobID)
                return
            }
            guard let root = scanBothSession?.destinationRoot,
                  let destinations = ReviewedImportDestinations(plans: plan.files, root: root) else {
                showFolderAccessError { L10n.tr("The destination folder is unavailable.") }
                return
            }
            let draft = currentImportDraft
            scanBothSession?.saveDraft(draft, needsAttention: previewNeedsAttention, for: jobID)
            scanBothSession?.setConfirmation(
                .init(
                    draft: draft,
                    plans: plan.files,
                    destinations: destinations,
                    copyFileCount: previewTotals.copyFiles,
                    destinationPaths: previewDestinations.map(\.path)
                ),
                for: jobID
            )
            returnToScanBothResults()
            return
        }

        startImport(jobID: jobID, databaseURL: databaseURL, builder: plan.builder, approvedPlans: plan.files)
    }

    private func validatedImportPlan(
        matching confirmation: ScanBothSession.Confirmation? = nil
    ) -> PreviewPlan? {
        validatePaths()
        guard !sourceNeedsAccess else {
            showFolderAccessError { L10n.tr("macOS needs your permission to read this source.") }
            return nil
        }
        guard sourceValidation.isUsable else {
            if let entry = scanBothSession?.reviewingEntry, let jobID = entry.jobID {
                requireRescan(for: jobID)
            } else {
                let validation = sourceValidation
                showFolderAccessError { validation.message }
            }
            return nil
        }
        guard requiredDestinationPathsAreUsable() else {
            if isReviewingScanBothVolume, scanBothDestinationChangeMessage != nil, let session = scanBothSession {
                let hasStarted = session.hasStartedImports
                showFolderAccessError { Self.scanBothDestinationChangedMessage(hasStartedImports: hasStarted) }
            } else {
                showFolderAccessError { L10n.tr("Choose usable destination folders") }
            }
            return nil
        }
        if let dedupeRepository {
            knownImportedPreviewFileIDs = Self.knownImportedFileIDs(
                files: currentPreviewFiles,
                dedupeRepository: dedupeRepository
            )
        }
        // Compare against what the user reviewed before refreshing history and dates.
        let reviewedRows = previewRows
        refreshScanBothReviewHistory(files: currentPreviewFiles)
        let refreshedPlan = refreshScanBothPreviewDates()
        guard let plan = refreshedPlan ?? makePreviewPlan(files: currentPreviewFiles, sessions: previewSessions) else {
            return nil
        }
        let plans = plan.files
        if refreshedPlan == nil {
            updatePreviewPlanCache(rows: makePreviewRows(files: currentPreviewFiles, plans: plans))
        }
        let planChanged = previewRows != reviewedRows
            || confirmation.map { $0.plans != plans || !$0.destinations.matches() } == true
        guard !planChanged else {
            if let entry = scanBothSession?.reviewingEntry, let jobID = entry.jobID,
               let scanned = entry.reviewedSourceFiles,
               !ReviewedFileIdentity.matchesSources(of: confirmation?.plans ?? plans, files: currentPreviewFiles, scanned: scanned) {
                requireRescan(for: jobID)
            } else {
                showFolderAccessError { L10n.tr("The import plan changed. Review it before copying.") }
            }
            return nil
        }
        folderAccessFeedback = nil
        guard previewTotals.copyFiles > 0,
              !previewRows.contains(where: { $0.disposition.attention == .blocking })
        else { return nil }
        if let failure = previewSpaceRequirements.first(where: { !$0.isSatisfied }) {
            let path = failure.displayPath
            if failure.isKnown {
                showFolderAccessError { L10n.tr("Not enough space in \(path)") }
            } else {
                showFolderAccessError { L10n.tr("Could not check available space in \(path)") }
            }
            return nil
        }

        return plan
    }

    func setReimportSelection(_ fileIDs: Set<Int64>, requested: Bool, volumeID: UUID? = nil) {
        guard !isWorking, !isEjectingSource, !isScanBothPlanLocked, importUIPhase == .review,
              let databaseURL else { return }
        let jobID: String
        let rows: [ImportPreviewRow]
        if let volumeID {
            guard let session = scanBothSession, !session.hasStartedImports,
                  let entry = session.entries.first(where: { $0.id == volumeID && $0.awaitsImport }),
                  let id = entry.jobID, !needsRescan(id),
                  let volumePlan = session.sharedReview?.volumes[volumeID] else { return }
            jobID = id
            rows = volumePlan.rows
        } else {
            guard let id = currentSummary?.jobID else { return }
            jobID = id
            rows = previewRows
        }

        // Treat a multi-lens recording as one selection, even from a single lens row.
        let recordings = Set(rows.compactMap { row in
            fileIDs.contains(row.id) && row.visualGroupKind == .insta360Clip ? row.visualGroupID : nil
        })
        let selectedIDs = Set(rows.compactMap { row -> Int64? in
            guard requested ? row.canReimport : row.canSkipReimport else { return nil }
            let selectedRecording = row.visualGroupKind == .insta360Clip
                && row.visualGroupID.map(recordings.contains) == true
            return fileIDs.contains(row.id) || selectedRecording ? row.id : nil
        })
        guard !selectedIDs.isEmpty else { return }

        let cancellation = ReimportSelectionCancellation()
        reimportSelectionCancellation = cancellation
        let attemptID = beginImportAttempt(
            .reimportSelection, event: .beginAuxiliaryOperation(.reimportSelection)
        )
        folderAccessFeedback = nil
        importTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                guard let files = try repositories.jobRepository.withImportLock(jobID: jobID, {
                    try Task.checkCancellation()
                    return try repositories.jobRepository.setReimportSelection(
                        jobID: jobID, fileIDs: selectedIDs, requested: requested, cancellation: cancellation
                    )
                }) else {
                    throw SDImportError.invalidArgument(L10n.tr("Finish the current scan or import first"))
                }

                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    if volumeID != nil {
                        self.loadSharedScanBothReview()
                        if self.selectedJobID == jobID { self.selectedJobFiles = files }
                        self.finishImportAttempt(attemptID, event: .endAuxiliaryOperation)
                        return
                    }
                    self.refreshScanBothReviewHistory(files: files)
                    self.currentPreviewFiles = files
                    if self.selectedJobID == jobID {
                        self.selectedJobFiles = files
                    }
                    self.rebuildPreviewSessions(files: files, defaultLabel: self.location)
                    if self.scanBothSession?.reviewingJobID == jobID {
                        let draft = self.currentImportDraft
                        self.scanBothSession?.saveDraft(draft, needsAttention: self.previewNeedsAttention, for: jobID)
                        self.scanBothSession?.setConfirmation(nil, for: jobID)
                    }
                    self.statusMessage = ""
                    self.finishImportAttempt(attemptID, event: .endAuxiliaryOperation)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    self.statusMessage = ""
                    self.finishImportAttempt(attemptID, event: .endAuxiliaryOperation)
                }
            } catch {
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    self.showFolderAccessError {
                        L10n.tr("Could not update re-import selection: \(Self.errorMessage(for: error))")
                    }
                    self.finishImportAttempt(attemptID, event: .endAuxiliaryOperation)
                }
            }
        }
    }

    private func startImport(
        jobID: String,
        databaseURL: URL,
        builder: ImportPlanBuilder,
        approvedPlans: [ImportFilePlan],
        reviewedDestinations: ReviewedImportDestinations? = nil
    ) {
        let scanBothEntry = scanBothSession?.entry(for: jobID)
        let isScanBothImport = scanBothEntry != nil
        let reviewedSourceFiles = scanBothEntry?.reviewedSourceFiles
        let startedApproval = scanBothEntry?.confirmation
        let expectedSource = scanBothEntry?.volume
            ?? singleScanMount.flatMap { $0.jobID == jobID ? $0.volume : nil }
        let currentSource = expectedSource.flatMap { volume in
            scanBothEntry == nil ? Self.currentPromptVolume(matching: volume) : liveScanBothVolume(matching: volume)
        }
        if expectedSource != nil, currentSource == nil {
            requireRescan(for: jobID)
            return
        }
        guard purchaseManager.canStartImport else {
            purchaseManager.isShowingPurchase = true
            statusMessage = L10n.tr("Start your 14-day trial or unlock unlimited imports to continue")
            return
        }
        let attemptID = beginImportAttempt(.prepareImport, event: .beginPreparation(.prepareImport))
        scanBothSession?.recordImportStarted(for: jobID)
        let plannedVolumes = scanBothEntry == nil
            ? [expectedSource].compactMap { $0 }
            : scanBothSession?.plannedCopyVolumes ?? []
        let volumeLookup = isScanBothImport ? scanBothMountLookup : Self.currentPromptVolume
        let copySources = ActiveCopySources(volumes: plannedVolumes)
        activeCopySources = copySources
        currentImportReceipt = nil
        importProgress = nil
        ejectedSourceJobID = nil
        ejectedSourceName = nil
        ejectedSourceVolumeCount = 0
        statusMessage = L10n.tr("Preparing import...")
        importLogger.info("Import started jobID=\(jobID, privacy: .private)")
        let portableImportReceiptsEnabled = self.portableImportReceiptsEnabled
        let reviewedSourcePath = currentSummary?.mountPath
        let destinationCapacity = self.destinationCapacity
        let observeCopyProgress = self.observeCopyProgress
        let retainedAccess = (
            Array(folderAccesses.values) + (isScanBothImport ? scanBothDestinationAccess : [])
                + [scanBothSourceAccess].compactMap { $0 } + (rescanContext?.access ?? [])
        ).filter(\.isActive)
        let reviewedInsta360RescanMembers = Set(approvedPlans.compactMap { plan in
            plan.isInsta360RescanMember ? plan.update?.id : nil
        })

        importTask = Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(retainedAccess) {} }
            do {
                if Task.isCancelled { throw SDImportError.cancelled }
                let destinations = SourceEjectionPolicy().resolvedDestinationVolumePaths(plans: approvedPlans)
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID, isProgress: true) == true else { return }
                    self.rememberEjectionDestinations(destinations, for: jobID)
                }
                if Task.isCancelled { throw SDImportError.cancelled }
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                let result = try {
                    let sourceDirectory: CopySourceDirectory?
                    if expectedSource != nil, let reviewedSourcePath {
                        sourceDirectory = try CopySourceDirectory(at: URL(fileURLWithPath: reviewedSourcePath, isDirectory: true))
                    } else {
                        sourceDirectory = nil
                    }
                    if let missing = plannedVolumes.first(where: { volumeLookup($0) == nil }) {
                        throw CopyVolumeUnavailable(volume: missing)
                    }
                    if Task.isCancelled { throw SDImportError.cancelled }
                    let engine = ImportEngine(
                        jobRepository: repositories.jobRepository,
                        dedupeRepository: repositories.dedupeRepository,
                        copyEngine: CopyEngine(sourceDirectory: sourceDirectory),
                        destinationSpaceChecker: DestinationSpaceChecker(capacityProvider: destinationCapacity),
                        portableReceiptsEnabled: portableImportReceiptsEnabled,
                        reviewedInsta360RescanMembers: reviewedInsta360RescanMembers,
                        reviewedDestinations: reviewedDestinations,
                        reviewedSourceFiles: reviewedSourceFiles,
                        preserveUntouchedScanOnCancellation: {
                            guard isScanBothImport, let expectedSource else { return false }
                            return copySources.wasStoppedOnlyBySiblingUnmount(sourcePath: expectedSource.mountPath)
                                && volumeLookup(expectedSource) != nil
                        }
                    )
                    var lastPublishedAt = Date(timeIntervalSince1970: 0)
                    let minimumUpdateInterval: TimeInterval = 0.75

                    return try engine.importFiles(
                        preparing: {
                            let files = try repositories.jobRepository.fetchJobFiles(jobID: jobID)
                            let history = reviewedSourcePath.map { sourcePath in
                                isScanBothImport ? engine.refreshedReviewHistory(files: files, sourcePath: sourcePath) : [:]
                            } ?? [:]
                            guard builder.plans(files: files, refreshedHistory: history) == approvedPlans else {
                                if let reviewedSourceFiles,
                                   !ReviewedFileIdentity.matchesSources(of: approvedPlans, files: files, scanned: reviewedSourceFiles) {
                                    throw SDImportError.reviewedSourceChanged
                                }
                                throw SDImportError.reviewedDestinationChanged
                            }
                            if Task.isCancelled { throw SDImportError.cancelled }
                            try repositories.jobRepository.updateJobImportPlan(
                                jobID: jobID,
                                destinationRoots: builder.roots,
                                updates: approvedPlans.compactMap(\.update)
                            )
                        },
                        jobID: jobID,
                        requiresReviewedDestinations: true,
                        onProgress: { progress in
                            observeCopyProgress?(progress)
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
                                guard self.importAttempt?.accepts(attemptID, isProgress: true) == true else { return }
                                self.importProgress = progress
                                self.transitionImportWorkspace(.beginCopy)
                                self.setLocalizedStatusMessage { Self.importStatusMessage(for: progress) }
                            }
                        },
                        shouldCancel: {
                            Task.isCancelled
                        }
                    )
                }()
                let finalDestinations = SourceEjectionPolicy().resolvedDestinationVolumePaths(plans: approvedPlans)
                let jobs = try repositories.jobRepository.listImportHistoryJobs(limit: 100)
                let files = try repositories.jobRepository.fetchJobFiles(jobID: jobID)

                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    self.rememberEjectionDestinations(finalDestinations, for: jobID)
                    self.currentImportReceipt = CompletedImportReceipt(
                        result: result, job: jobs.first { $0.id == result.jobID }, files: files
                    )
                    self.importProgress = nil
                    self.jobs = jobs
                    self.scanBothSession?.recordImport(result)
                    if result.failedFiles > 0 || (!isScanBothImport && self.activeCopySources?.disconnectedVolume != nil) {
                        self.jobsRequiringRescan.insert(jobID)
                    } else {
                        if isScanBothImport { self.jobsRequiringRescan.remove(jobID) }
                    }
                    self.selectedJobID = jobID
                    self.selectedJobFiles = files
                    if self.currentSummary?.jobID == jobID {
                        self.currentPreviewFiles = files
                    } else {
                        self.rebuildPreviewPlanCache()
                    }
                    if let warning = result.portableReceiptWarning {
                        self.setLocalizedStatusMessage {
                            let localizedWarning = L10n.portableReceiptWarning(
                                warning, sizeWarning: result.portableReceiptSizeWarning
                            )
                            return L10n.tr("Import finished. \(localizedWarning)")
                        }
                    } else {
                        self.statusMessage = L10n.tr("Import finished")
                    }
                    let finishedSuccessfully = result.failedFiles == 0
                        && self.importAttempt?.cancellationRequested == false
                        && self.activeCopySources?.disconnectedVolume == nil
                    self.finishImportAttempt(attemptID, event: .completed)
                    if finishedSuccessfully, self.isRunningScanBothImports,
                       self.scanBothSession?.nextConfirmedEntry != nil {
                        self.startNextScanBothImport()
                    } else {
                        self.isRunningScanBothImports = false
                    }
                    if finishedSuccessfully, self.importUIPhase == .completed {
                        self.autoEjectAfterImport(result)
                    }
                }
                importLogger.info(
                    "Import finished imported=\(result.importedFiles, privacy: .public) skipped=\(result.skippedFiles, privacy: .public) failed=\(result.failedFiles, privacy: .public)"
                )
            } catch SDImportError.insta360RescanCopyChanged {
                let snapshot = try? Self.historySnapshot(databaseURL: databaseURL, jobID: jobID)
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    if let snapshot {
                        self.jobs = snapshot.jobs
                        self.selectedJobFiles = snapshot.files
                        self.currentPreviewFiles = snapshot.files
                    }
                    self.useOriginalInsta360Folders = false
                    self.importProgress = nil
                    self.finishImportAttempt(attemptID, event: .recover(hasScannedJob: true))
                    self.showFolderAccessError {
                        L10n.tr("An existing Insta360 lens file could not be verified. Choose a different folder for both files.")
                    }
                }
            } catch let error as SDImportError where Self.canRecoverImportReview(error, isScanBothImport: isScanBothImport) {
                let snapshot = try? Self.historySnapshot(databaseURL: databaseURL, jobID: jobID)
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    self.validatePaths()
                    if let snapshot {
                        self.jobs = snapshot.jobs
                        self.selectedJobFiles = snapshot.files
                        self.refreshScanBothReviewHistory(files: snapshot.files)
                        self.currentPreviewFiles = snapshot.files
                        self.recordScanBothInterruption(jobID: jobID, files: snapshot.files, message: Self.errorMessage(for: error))
                    } else {
                        self.rebuildPreviewPlanCache()
                    }
                    self.importProgress = nil
                    if error == .reviewedSourceChanged || !isScanBothImport || snapshot?.job?.status != .scanned {
                        self.jobsRequiringRescan.insert(jobID)
                    }
                    self.finishImportAttempt(
                        attemptID, event: .recover(hasScannedJob: self.currentSummary?.jobID == jobID)
                    )
                    self.showFolderAccessError { Self.errorMessage(for: error) }
                }
            } catch let error as CopyVolumeUnavailable {
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    if !isScanBothImport { self.jobsRequiringRescan.insert(jobID) }
                    self.invalidateScansAtUnmount(error.volume.mountURL)
                    if let expectedSource, copySources.wasStoppedOnlyBySiblingUnmount(sourcePath: expectedSource.mountPath),
                       self.liveScanBothVolume(matching: expectedSource) != nil {
                        self.scanBothSession?.setConfirmation(startedApproval, for: jobID)
                    }
                    self.finishImportAttempt(attemptID, event: .cancelled)
                }
            } catch let error as SDImportError where error == .cancelled || error == .sourceVolumeUnavailable {
                let snapshot = try? Self.historySnapshot(databaseURL: databaseURL, jobID: jobID)
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    let sourceFolderChanged = isScanBothImport && error == .sourceVolumeUnavailable
                        && expectedSource.map { self.liveScanBothVolume(matching: $0) != nil } == true
                    let interruption = sourceFolderChanged
                        ? Self.errorMessage(for: SDImportError.reviewedSourceChanged)
                        : L10n.tr("Import cancelled")
                    let untouchedSiblingDisconnect = isScanBothImport && error == .cancelled && snapshot?.job?.status == .scanned
                        && expectedSource.map {
                            copySources.wasStoppedOnlyBySiblingUnmount(sourcePath: $0.mountPath)
                                && self.liveScanBothVolume(matching: $0) != nil
                        } == true
                    if untouchedSiblingDisconnect {
                        self.scanBothSession?.setConfirmation(startedApproval, for: jobID)
                    } else {
                        self.jobsRequiringRescan.insert(jobID)
                    }
                    if error == .sourceVolumeUnavailable, !sourceFolderChanged, let expectedSource {
                        self.invalidateScansAtUnmount(expectedSource.mountURL)
                    }
                    if let snapshot {
                        self.jobs = snapshot.jobs
                        self.selectedJobID = jobID
                        self.selectedJobFiles = snapshot.files
                        if self.currentSummary?.jobID == jobID {
                            self.currentPreviewFiles = snapshot.files
                        } else {
                            self.rebuildPreviewPlanCache()
                        }
                        self.recordScanBothInterruption(
                            jobID: jobID, files: snapshot.files, message: interruption,
                            includeEmptyReceipt: snapshot.job?.status == .cancelled
                        )
                    }
                    self.currentImportReceipt = nil
                    self.importProgress = nil
                    self.statusMessage = interruption
                    if sourceFolderChanged {
                        self.finishImportAttempt(attemptID, event: .recover(hasScannedJob: self.currentSummary?.jobID == jobID))
                        self.showFolderAccessError { Self.errorMessage(for: SDImportError.reviewedSourceChanged) }
                    } else {
                        self.finishImportAttempt(attemptID, event: .cancelled)
                    }
                }
                importLogger.notice("Import cancelled jobID=\(jobID, privacy: .private)")
            } catch {
                let snapshot = isScanBothImport ? try? Self.historySnapshot(databaseURL: databaseURL, jobID: jobID) : nil
                await MainActor.run {
                    guard self.importAttempt?.accepts(attemptID) == true else { return }
                    self.jobsRequiringRescan.insert(jobID)
                    self.currentImportReceipt = nil
                    self.importProgress = nil
                    let failedOperation = self.activeImportOperation ?? .copy
                    let render: () -> String = { L10n.tr("Import failed: \(Self.errorMessage(for: error))") }
                    self.setLocalizedStatusMessage(render)
                    let message = self.statusMessage
                    if let snapshot {
                        self.jobs = snapshot.jobs
                        self.selectedJobFiles = snapshot.files
                        self.recordScanBothInterruption(jobID: jobID, files: snapshot.files, message: message)
                    }
                    self.finishImportAttempt(
                        attemptID, event: .failed(operation: failedOperation, message: message),
                        failureRenderer: render
                    )
                }
                importLogger.error("Import failed errorType=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    private func recordScanBothInterruption(
        jobID: String, files: [JobFileRecord], message: String, includeEmptyReceipt: Bool = false
    ) {
        scanBothSession?.recordInterruptedImport(
            jobID: jobID, files: files, message: importDisconnectionMessage ?? message, includeEmptyReceipt: includeEmptyReceipt
        )
    }

    nonisolated private static func canRecoverImportReview(_ error: SDImportError, isScanBothImport: Bool) -> Bool {
        switch error {
        case .reviewedDestinationChanged, .reviewedSourceChanged:
            return true
        case .insufficientDestinationSpace:
            return isScanBothImport
        default:
            return false
        }
    }

    func cancelImport() {
        guard importTask != nil, importAttempt?.operation != .eject else { return }
        if let reimportSelectionCancellation, !reimportSelectionCancellation.cancel() { return }
        activeCopySources?.noteUserCancellation()
        importAttempt?.requestCancellation()
        statusMessage = L10n.tr("Cancelling...")
        importTask?.cancel()
    }

    private func beginImportAttempt(
        _ operation: ImportOperationKind,
        event: ImportWorkspaceEvent,
        retryContext: ImportRetryContext? = nil
    ) -> UUID {
        let attempt = ImportWorkspaceAttempt(operation: operation)
        activeImportRetryContext = retryContext
        failedImportRetryContext = nil
        importAttempt = attempt
        transitionImportWorkspace(event)
        return attempt.id
    }

    private func finishImportAttempt(
        _ id: UUID,
        event: ImportWorkspaceEvent,
        failureRenderer: (() -> String)? = nil
    ) {
        guard let attempt = importAttempt, attempt.accepts(id) else { return }
        if let volume = activeCopySources?.disconnectedVolume {
            isRunningScanBothImports = false
            let render = { Self.importDisconnectedMessage(volume) }
            let message = render()
            folderAccessFeedback = nil
            statusMessage = message
            failedImportRetryContext = activeImportRetryContext
            transitionImportWorkspace(.failed(operation: .copy, message: message), failureRenderer: render)
        } else {
            if event != .completed {
                isRunningScanBothImports = false
            }
            if case .failed = event { failedImportRetryContext = activeImportRetryContext }
            transitionImportWorkspace(event, failureRenderer: failureRenderer)
        }
        activeCopySources = nil
        activeImportRetryContext = nil
        reimportSelectionCancellation = nil
        if attempt.operation == .eject {
            sourceEjectionTask = nil
        } else {
            importTask = nil
        }
        importAttempt = nil
        schedulePendingMountHandoffRetry()
    }

    private func transitionImportWorkspace(
        _ event: ImportWorkspaceEvent,
        failureRenderer: (() -> String)? = nil
    ) {
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
        if next.failure != importFailure || failureRenderer != nil {
            importFailureRenderer = failureRenderer
        }
        importFailure = next.failure
    }

    func recoverImportWorkspace() {
        guard importAttempt == nil else { return }
        failedImportRetryContext = nil
        let hasReview = currentSummary != nil || isShowingScanBothResults
        transitionImportWorkspace(.recover(hasScannedJob: hasReview))
        statusMessage = hasReview ? L10n.tr("Review import") : L10n.tr("Ready")
    }

    func recoverImportReceipt() {
        guard importAttempt == nil else { return }
        guard currentResult != nil else {
            recoverImportWorkspace()
            return
        }
        failedImportRetryContext = nil
        transitionImportWorkspace(.recoverCompleted)
        statusMessage = L10n.tr("Import finished")
    }

    func retryFailedImportOperation() {
        guard importAttempt == nil else { return }
        let operation = importFailure?.operation
        let retryContext = failedImportRetryContext
        failedImportRetryContext = nil
        switch retryContext {
        case .eject(let jobID, let target):
            transitionImportWorkspace(
                currentResult == nil
                    ? .recover(hasScannedJob: currentSummary != nil || isShowingScanBothResults)
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
        case .prepareImport, .copy, .reimportSelection:
            recoverImportWorkspace()
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
        scanBothSession = nil
        singleScanMount = nil
        insta360RescanRecovery = nil
        rescanContext = nil
        currentSummary = nil
        currentImportReceipt = nil
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
        statusMessage = L10n.tr("Ready for another card")
    }

    func acceptMountedVolumePrompt(_ volume: MountedVolume, from prompt: MountedDevicePrompt) {
        let promptID = prompt.id
        guard let mountID = prompt.mountID(for: volume), promptContains(volume, id: promptID, mountID: mountID) else {
            return
        }
        guard !isWorking, !isEjectingSource else {
            statusMessage = L10n.tr("Finish the current operation before scanning another card")
            return
        }
        guard let databaseURL else {
            showFolderAccessError { L10n.tr("Database is not ready") }
            return
        }
        guard confirmLeavingScanBothResults(actionTitle: L10n.tr("Start New Scan")) else {
            mountPrompts.dismiss(promptID)
            return
        }
        guard promptContains(volume, id: promptID, mountID: mountID) else { return }
        guard let observedVolume = Self.currentPromptVolume(matching: volume) else {
            refreshAvailableSourceVolumes()
            statusMessage = L10n.tr("Card scan cancelled")
            return
        }
        let sourceURL: URL
        if AppDistribution.current == .macAppStore {
            if let authorizedURL = authorizedSourceURL(for: volume) {
                sourceURL = authorizedURL
            } else {
                let selection = FilePanelPresenter.chooseDirectoryURL(
                    title: L10n.tr("Allow Access to \(volume.name)"),
                    initialPath: volume.mountURL.path,
                    prompt: L10n.tr("Allow Access"),
                    message: L10n.tr("\(AppDistribution.current.displayName) will scan this folder only after you allow access.")
                )
                // The modal picker runs an event loop. The same path may now
                // belong to a new card, even if the camera's chooser stayed open.
                refreshAvailableSourceVolumes()
                guard promptContains(volume, id: promptID, mountID: mountID),
                      let currentVolume = Self.currentPromptVolume(matching: observedVolume) else {
                    statusMessage = L10n.tr("Card scan cancelled")
                    return
                }
                guard let selectedURL = selection else {
                    mountPrompts.dismiss(promptID)
                    statusMessage = L10n.tr("Card scan cancelled")
                    return
                }
                guard Self.isSameOrDescendant(selectedURL, of: volume.mountURL) else {
                    let name = volume.name
                    setLocalizedStatusMessage { L10n.tr("Choose \(name) or a folder on that card") }
                    return
                }
                if !currentVolume.hasVerifiedMediaContinuity(with: observedVolume) {
                    guard confirmScanOfCurrentVolume(currentVolume) else {
                        statusMessage = L10n.tr("Card scan cancelled")
                        return
                    }
                    refreshAvailableSourceVolumes()
                    guard promptContains(volume, id: promptID, mountID: mountID),
                          Self.currentPromptVolume(matching: currentVolume) != nil else {
                        statusMessage = L10n.tr("Card scan cancelled")
                        return
                    }
                }
                guard retainSelectedFolderAccess(
                    .source,
                    url: selectedURL,
                    persistBookmark: true
                ) else {
                    mountPrompts.dismiss(promptID)
                    return
                }
                sourceURL = selectedURL
            }
        } else {
            sourceURL = volume.mountURL
        }

        guard let path = validatedSelectedSourcePath(sourceURL) else { return }
        guard mountPrompts.dismiss(promptID) else { return }
        retainPendingScanBothResults()
        selection = .import
        cardPath = path
        refreshAvailableSourceVolumes(including: volume)
        sourcePathDidChange()
        startScan(at: path, databaseURL: databaseURL)
    }

    func acceptScanBoth(_ prompt: MountedDevicePrompt) {
        guard !isWorking, !isEjectingSource,
              pendingMountPrompt?.deviceGroup.volumes.count == 2,
              let session = ScanBothSession(prompt: prompt),
              session.entries.allSatisfy({ promptContains($0.volume, id: prompt.id, mountID: $0.id) }),
              databaseURL != nil else { return }
        guard confirmLeavingScanBothResults(actionTitle: L10n.tr("Start New Scan")) else {
            mountPrompts.dismiss(prompt.id)
            return
        }
        guard session.entries.allSatisfy({ promptContains($0.volume, id: prompt.id, mountID: $0.id) }) else { return }
        guard mountPrompts.dismiss(prompt.id) else { return }
        beginScanBoth(session)
    }

    func beginScanBoth(_ session: ScanBothSession) {
        guard !isWorking, !isEjectingSource, let databaseURL else { return }
        var session = session
        retainPendingScanBothResults()
        sourcePathDidChange()
        resetImportDraftFromDefaults()
        selection = .import
        session.sharedReview = ScanBothReview(
            shootName: location, mediaSelection: importMediaSelection, folderGrouping: folderGrouping
        )
        let sharedPhotos = validateScanBothDestination(photosPath)
        let sharedVideos = validateScanBothDestination(videosPath)
        if sharedPhotos.isUsable, sharedVideos.isUsable,
           sharedPhotos.expandedPath == sharedVideos.expandedPath,
           let root = ReviewedImportDestinations.Root(
               at: URL(fileURLWithPath: sharedPhotos.expandedPath, isDirectory: true)
           ) {
            let access = [folderAccesses[.photos], folderAccesses[.videos]].compactMap { $0 }.first {
                $0.isActive && Self.isSameOrDescendant(root.url, of: $0.url)
            }
            session.setDestination(root, access: access)
        }
        scanBothSession = session
        let attemptID = beginImportAttempt(.scan, event: .beginScan)
        importTask = Task {
            await session.scan { index, state in
                scanBothSession?.entries[index].state = state
            } volume: { volume in
                try await scanBothVolume(volume, databaseURL: databaseURL)
            }
            if previousScanBothSession != nil, Task.isCancelled {
                statusMessage = L10n.tr("Scan cancelled")
                finishScanAttempt(attemptID, event: .cancelled)
            } else if previousScanBothSession != nil,
                      let issue = scanBothSession?.issueIfNoVolumeScanned {
                let render = { issue.message }
                finishScanAttempt(
                    attemptID, event: .failed(operation: .scan, message: render()), failureRenderer: render
                )
            } else {
                statusMessage = ""
                loadSharedScanBothReview()
                finishScanAttempt(attemptID, event: .scanSucceeded)
            }
        }
    }

    private func scanBothVolume(_ volume: MountedVolume, databaseURL: URL) async throws -> ScanBothSession.Entry.State {
        do {
            let (sourceURL, access) = try authorizeScanBothVolume(volume)
            try Task.checkCancellation()
            let validation = PathValidator().validate(
                path: sourceURL.path, purpose: .source, allowsWhitespaceFallback: false
            )
            guard validation.isUsable else { throw ScanBothIssue.failed(validation.message) }
            // Destination paths are planned after both sources have been scanned.
            let request = scanRequest(
                mountURL: URL(fileURLWithPath: validation.expandedPath, isDirectory: true),
                sourceVolume: volume, plansDestinations: false
            )
            let worker = Task.detached(priority: .userInitiated) {
                defer { withExtendedLifetime(access) {} }
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                let scanner = MediaScanner(
                    jobRepository: repositories.jobRepository,
                    dedupeRepository: repositories.dedupeRepository
                )
                var reviewedSources: [String: ReviewedFileIdentity] = [:]
                let summary = try scanner.scan(request, recordReviewedSource: { path, identity in
                    reviewedSources[path] = identity
                }, shouldCancel: { Task.isCancelled })
                try Task.checkCancellation()
                return (summary, reviewedSources)
            }
            let (summary, reviewedSources) = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard liveScanBothVolume(matching: volume) != nil else { throw ScanBothIssue.removed }
            return .complete(summary, access, reviewedSources)
        } catch {
            if let issue = error as? ScanBothIssue { throw issue }
            guard liveScanBothVolume(matching: volume) != nil else { throw ScanBothIssue.removed }
            throw ScanBothIssue.failed(Self.errorMessage(for: error))
        }
    }

    private func authorizeScanBothVolume(
        _ volume: MountedVolume
    ) throws -> (URL, SecurityScopedResourceAccess?) {
        guard let observed = liveScanBothVolume(matching: volume) else { throw ScanBothIssue.removed }
        guard AppDistribution.current == .macAppStore else { return (volume.mountURL, nil) }
        if let url = authorizedSourceURL(for: volume), let access = folderAccesses[.source] {
            return (url, access)
        }
        let selection = FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Allow Access to \(volume.name)"),
            initialPath: volume.mountPath,
            prompt: L10n.tr("Allow Access"),
            message: L10n.tr("\(AppDistribution.current.displayName) will scan this folder only after you allow access.")
        )
        guard let current = liveScanBothVolume(matching: observed) else { throw ScanBothIssue.removed }
        guard let selection else { throw ScanBothIssue.accessDeclined }
        guard Self.isSameOrDescendant(selection, of: current.mountURL) else {
            throw ScanBothIssue.failed(L10n.tr("Choose \(volume.name) or a folder on that card"))
        }
        if !current.hasVerifiedMediaContinuity(with: observed) {
            guard confirmScanOfCurrentVolume(current) else { throw ScanBothIssue.accessDeclined }
            guard liveScanBothVolume(matching: current) != nil else { throw ScanBothIssue.removed }
        }
        let access = SecurityScopedResourceAccess(url: selection)
        guard access.isActive else { throw ScanBothIssue.accessUnavailable }
        return (selection, access)
    }

    private func liveScanBothVolume(matching volume: MountedVolume) -> MountedVolume? {
        guard scanBothSession?.removedMountPaths.contains(volume.mountPath) == false else { return nil }
        return scanBothMountLookup(volume)
    }

    func updateSharedScanBothReview<Value>(_ field: WritableKeyPath<ScanBothReview, Value>, to value: Value) {
        guard !isWorking, !isEjectingSource, scanBothSession?.hasStartedImports == false else { return }
        scanBothSession?.sharedReview?[keyPath: field] = value
        folderAccessFeedback = nil
        rebuildSharedScanBothReview()
    }

    func includeScanBothImport(_ entryID: UUID) {
        guard !isWorking, !isEjectingSource else { return }
        scanBothSession?.includeEntry(entryID)
        folderAccessFeedback = nil
        rebuildSharedScanBothReview()
    }

    @discardableResult
    private func loadSharedScanBothReview() -> Bool {
        guard var session = scanBothSession, var review = session.sharedReview,
              let jobRepository, let dedupeRepository else { return false }
        do {
            for entry in session.entries {
                guard let summary = entry.summary, !session.removedMountPaths.contains(entry.volume.mountPath) else {
                    review.sources[entry.id] = nil
                    continue
                }
                let files = try jobRepository.fetchJobFiles(jobID: summary.jobID)
                let engine = ImportEngine(
                    jobRepository: jobRepository, dedupeRepository: dedupeRepository,
                    portableReceiptsEnabled: portableImportReceiptsEnabled, reviewedSourceFiles: entry.reviewedSourceFiles
                )
                review.sources[entry.id] = ScanBothReview.Source(
                    files: files, history: engine.refreshedReviewHistory(files: files, sourcePath: summary.mountPath)
                )
            }
            session.sharedReview = review
            scanBothSession = session
            rebuildSharedScanBothReview()
            return true
        } catch {
            showFolderAccessError { Self.errorMessage(for: error) }
            return false
        }
    }

    private func rebuildSharedScanBothReview() {
        guard var session = scanBothSession, var review = session.sharedReview else { return }
        // A single shoot uses the same capture-date range for every included volume.
        if !session.hasStartedImports {
            let files = session.entries.filter(\.awaitsImport).flatMap { review.sources[$0.id]?.files ?? [] }
            review.sessions = makePreviewSessions(
                files: files.filter { review.mediaSelection.includes($0.mediaKind) },
                defaultLabel: review.shootName, existing: [:],
                inclusion: (review.mediaSelection.includes(.photo), review.mediaSelection.includes(.video), false)
            )
        }
        let root = session.destinationRoot
        let usableRoot = root.flatMap { $0.matches() ? $0 : nil }
        review.volumes = Dictionary(uniqueKeysWithValues: session.entries.compactMap { entry in
            guard let summary = entry.summary, let source = review.sources[entry.id] else { return nil }
            let volume = makeSharedScanBothVolumePlan(
                summary: summary, source: source, review: review, root: usableRoot
            )
            return (entry.id, volume)
        })
        review.blockingMessage = sharedScanBothBlockingMessage(session: session, review: review)
        session.sharedReview = review
        scanBothSession = session
    }

    private func makeSharedScanBothVolumePlan(
        summary: ScanSummary, source: ScanBothReview.Source, review: ScanBothReview,
        root: ReviewedImportDestinations.Root?
    ) -> ScanBothReview.VolumePlan {
        guard let root else {
            let plans = source.files.map { file in
                let disposition = file.knownSource.map { ImportPlanDisposition.known($0) } ?? .notReady
                return ImportFilePlan(update: nil, willCopy: false, disposition: disposition, destinationPath: nil)
            }
            return ScanBothReview.VolumePlan(
                rows: makePreviewRows(files: source.files, plans: plans), totals: .empty, paths: [], confirmation: nil
            )
        }
        let draft = ImportDraft(
            sourcePath: summary.mountPath, photosPath: root.url.path, videosPath: root.url.path,
            shootName: review.shootName, workflowProfile: .mixedShootSession,
            mediaSelection: review.mediaSelection, destinationLayout: .singleLibrary,
            folderGrouping: review.folderGrouping, sessions: review.sessions
        )
        let builder = ImportPlanBuilder(
            sessions: review.sessions, mediaSelection: review.mediaSelection,
            organizationPreset: draft.destinationLayout.organizationPreset, folderGrouping: review.folderGrouping,
            roots: DestinationRoots(photosURL: root.resolvedURL, videosURL: root.resolvedURL),
            fallbackLocation: Self.defaultSessionLabel(for: review.shootName), volumeName: summary.volumeName
        )
        let plans = builder.plans(files: source.files, refreshedHistory: source.history)
        let rows = makePreviewRows(files: source.files, plans: plans)
        let totals = buildPreviewTotals(rows: rows)
        let paths = Set(plans.compactMap { plan in
            plan.willCopy ? plan.destinationPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } : nil
        }).sorted()
        let confirmation = ReviewedImportDestinations(plans: plans, root: root).map {
            ScanBothSession.Confirmation(
                draft: draft, plans: plans, destinations: $0, copyFileCount: totals.copyFiles,
                destinationPaths: paths, sharedBuilder: builder
            )
        }
        return ScanBothReview.VolumePlan(rows: rows, totals: totals, paths: paths, confirmation: confirmation)
    }

    private func sharedScanBothBlockingMessage(session: ScanBothSession, review: ScanBothReview) -> String? {
        guard session.destinationRoot != nil else { return nil }
        let pending = session.entries.filter(\.awaitsImport)
        guard !pending.isEmpty else { return nil }
        let volumes = pending.compactMap { review.volumes[$0.id] }
        if volumes.contains(where: \.hasConflict) {
            return L10n.tr("Resolve filename conflicts before starting imports.")
        }
        if volumes.count != pending.count || volumes.contains(where: { $0.confirmation == nil }) {
            return L10n.tr("The destination folder is unavailable.")
        }
        let approvals = volumes.compactMap(\.confirmation)
        if approvals.count == 2,
           let filename = approvals[0].destinations.firstFilenameCollision(
               in: approvals[0].plans, with: approvals[1].destinations, siblingPlans: approvals[1].plans
           ) {
            return L10n.tr("Both volumes target \(filename) in the same folder. Skip one volume to continue.")
        }
        if let failure = buildPreviewSpaceRequirements(
            rows: volumes.flatMap(\.rows), usingPlanHistory: true
        ).first(where: { !$0.isSatisfied }) {
            return failure.isKnown ? L10n.tr("Not enough space in \(failure.displayPath)")
                : L10n.tr("Could not check available space in \(failure.displayPath)")
        }
        return nil
    }

    var canStartSharedScanBothImports: Bool {
        guard !isWorking, !isEjectingSource,
              let session = scanBothSession, let review = session.sharedReview,
              session.destinationRoot != nil, session.entries.allSatisfy({ entry in
                  entry.isResolved || entry.awaitsImport && entry.jobID.map { !needsRescan($0) } == true
              }) else { return false }
        return !review.queuedEntries(in: session).isEmpty || review.blockingMessage != nil
    }

    func startSharedScanBothImports() {
        guard canStartSharedScanBothImports, let previous = scanBothSession?.sharedReview,
              let session = scanBothSession else { return }
        guard let root = session.destinationRoot, root.matches(), scanBothDestinationValidation.isUsable,
              !scanBothDestinationNeedsAccess else {
            showFolderAccessError { [weak self] in
                self?.scanBothDestinationChangeMessage ?? L10n.tr("Choose usable destination folders")
            }
            return
        }
        for volume in session.plannedCopyVolumes where liveScanBothVolume(matching: volume) == nil {
            invalidateScansAtUnmount(volume.mountURL)
            showFolderAccessError { Self.importDisconnectedMessage(volume.name) }
            return
        }
        guard loadAndValidateSharedScanBothReview(previous, session: session) else { return }
        guard purchaseManager.canStartImport else {
            purchaseManager.isShowingPurchase = true
            return
        }
        guard let refreshed = scanBothSession?.sharedReview, !refreshed.queuedEntries(in: session).isEmpty else { return }
        for entry in session.entries where entry.awaitsImport {
            guard let jobID = entry.jobID, let volume = refreshed.volumes[entry.id] else { return }
            if volume.totals.copyFiles == 0 {
                scanBothSession?.skipEntry(entry.id)
            } else {
                scanBothSession?.setConfirmation(volume.confirmation, for: jobID)
            }
        }
        folderAccessFeedback = nil
        isRunningScanBothImports = true
        startNextScanBothImport()
    }

    private func loadAndValidateSharedScanBothReview(_ previous: ScanBothReview, session: ScanBothSession) -> Bool {
        guard loadSharedScanBothReview(), let refreshed = scanBothSession?.sharedReview else { return false }
        if let message = refreshed.blockingMessage {
            showFolderAccessError { message }
            return false
        }
        for entry in session.entries where entry.awaitsImport {
            guard let summary = entry.summary, let files = refreshed.sources[entry.id]?.files,
                  let volume = refreshed.volumes[entry.id], let confirmation = volume.confirmation else { return false }
            let validation = PathValidator().validate(path: summary.mountPath, purpose: .source, allowsWhitespaceFallback: false)
            guard validation.isUsable,
                  entry.reviewedSourceFiles.map({
                      ReviewedFileIdentity.matchesSources(of: confirmation.plans, files: files, scanned: $0)
                  }) != false else {
                requireRescan(for: summary.jobID)
                return false
            }
            let shown = previous.volumes[entry.id]
            guard volume.rows == shown?.rows, confirmation.plans == shown?.confirmation?.plans,
                  shown?.confirmation?.destinations.matches() == true else {
                showFolderAccessError { L10n.tr("The import plan changed. Review it before copying.") }
                return false
            }
        }
        return true
    }

    func reviewScanBothVolume(_ entryID: UUID) {
        guard !isWorking, !isEjectingSource,
              scanBothSession?.destinationPath.isEmpty == false,
              let entry = scanBothSession?.entries.first(where: { $0.id == entryID }),
              entry.awaitsImport, let summary = entry.summary, !needsRescan(summary.jobID),
              scanBothSession?.reviewingJobID != summary.jobID else { return }
        if isReviewingScanBothVolume {
            returnToScanBothResults()
        }
        _ = openScanBothVolume(entry, summary: summary)
    }

    func startScanBothImports() {
        guard canStartScanBothImports, let session = scanBothSession,
              session.hasStartedImports || validateScanBothDestinations(session) else { return }
        guard purchaseManager.canStartImport else {
            purchaseManager.isShowingPurchase = true
            return
        }
        isRunningScanBothImports = true
        startNextScanBothImport()
    }

    private func validateScanBothDestinations(_ session: ScanBothSession) -> Bool {
        let changedJobs = session.entries.compactMap { entry in
            entry.awaitsImport && entry.confirmation?.destinations.matches() == false ? entry.jobID : nil
        }
        guard changedJobs.isEmpty else {
            for jobID in changedJobs {
                scanBothSession?.setConfirmation(nil, for: jobID)
            }
            showFolderAccessError { L10n.tr("The import plan changed. Review it before copying.") }
            return false
        }

        let first = session.entries[0]
        let second = session.entries[1]
        guard first.awaitsImport, second.awaitsImport,
              let firstPlan = first.confirmation, let secondPlan = second.confirmation,
              let filename = firstPlan.destinations.firstRecordingFilenameCollision(
                  in: firstPlan.plans, with: secondPlan.destinations, siblingPlans: secondPlan.plans
              ) else { return true }
        let firstVolume = session.volumeTitle(for: first)
        let secondVolume = session.volumeTitle(for: second)
        showFolderAccessError(isScanBothCollision: true) {
            L10n.tr("\(firstVolume) and \(secondVolume) both target \(filename) in the same folder. Change one volume’s Shoot name or Folder label in Customize Dates, or skip that volume.")
        }
        return false
    }

    private func startNextScanBothImport() {
        defer {
            if !isWorking { isRunningScanBothImports = false }
        }
        guard let session = scanBothSession, session.canStartImports,
              let entry = session.nextConfirmedEntry,
              let confirmation = entry.confirmation, let summary = entry.summary else { return }
        guard let databaseURL else {
            showFolderAccessError { L10n.tr("Database is not ready") }
            return
        }
        if let missing = session.plannedCopyVolumes.first(where: { liveScanBothVolume(matching: $0) == nil }) {
            invalidateScansAtUnmount(missing.mountURL)
            returnToScanBothResults()
            showFolderAccessError { Self.importDisconnectedMessage(missing.name) }
            return
        }
        if let builder = confirmation.sharedBuilder {
            guard confirmation.destinations.matches() else {
                scanBothSession?.setConfirmation(nil, for: summary.jobID)
                returnToScanBothResults()
                showFolderAccessError { L10n.tr("The import plan changed. Review it before copying.") }
                return
            }
            activateSharedScanBothVolume(summary)
            let siblingApprovals = session.entries.compactMap { sibling in
                sibling.id == entry.id ? nil : sibling.confirmation?.destinations
            }
            startImport(
                jobID: summary.jobID, databaseURL: databaseURL,
                builder: builder, approvedPlans: confirmation.plans,
                reviewedDestinations: confirmation.destinations.sharingMaterializedDirectories(with: siblingApprovals)
            )
            return
        }
        guard openScanBothVolume(entry, summary: summary) else {
            scanBothSession?.setConfirmation(nil, for: summary.jobID)
            return
        }
        guard let plan = validatedImportPlan(matching: confirmation) else {
            scanBothSession?.setConfirmation(nil, for: summary.jobID)
            return
        }
        let siblingApprovals = session.entries.compactMap { sibling in
            sibling.id == entry.id ? nil : sibling.confirmation?.destinations
        }
        startImport(
            jobID: summary.jobID, databaseURL: databaseURL,
            builder: plan.builder, approvedPlans: confirmation.plans,
            reviewedDestinations: confirmation.destinations.sharingMaterializedDirectories(with: siblingApprovals)
        )
    }

    private func activateSharedScanBothVolume(_ summary: ScanSummary) {
        scanBothSession?.reviewingJobID = summary.jobID
        currentSummary = summary
        rescanContext = nil
        insta360RescanRecovery = nil
        folderAccessFeedback = nil
        currentPreviewFiles = []
        recoverImportWorkspace()
    }

    private func openScanBothVolume(_ entry: ScanBothSession.Entry, summary: ScanSummary) -> Bool {
        guard liveScanBothVolume(matching: entry.volume) != nil,
              PathValidator().validate(path: summary.mountPath, purpose: .source, allowsWhitespaceFallback: false).isUsable
        else {
            requireRescan(for: summary.jobID)
            return false
        }
        do {
            guard let jobRepository, let dedupeRepository else { return false }
            let files = try jobRepository.fetchJobFiles(jobID: summary.jobID)
            if try jobRepository.fetchJob(id: summary.jobID)?.canRetryImport == true {
                requireRescan(for: summary.jobID)
                return false
            }
            scanBothSession?.reviewingJobID = summary.jobID
            folderAccessFeedback = nil
            currentImportReceipt = nil
            resetImportDraftFromDefaults()
            previewSessions = []
            let draft = entry.draft
            workflowProfileWasManuallyChosenForCurrentJob = draft != nil
            if let draft {
                location = draft.shootName
                workflowProfile = draft.workflowProfile
                importMediaSelection = draft.mediaSelection
                destinationLayout = draft.destinationLayout
                organizationPreset = draft.destinationLayout.organizationPreset
                if draft.mediaSelection == .photosAndVideos {
                    preferredMixedDestinationLayout = draft.destinationLayout
                }
                folderGrouping = draft.folderGrouping
            }
            loadScanPreview(summary, files: files, dedupeRepository: dedupeRepository, restoring: draft)
            recoverImportWorkspace()
            return true
        } catch {
            showFolderAccessError { Self.errorMessage(for: error) }
            return false
        }
    }

    private func loadScanPreview(
        _ summary: ScanSummary, files: [JobFileRecord], dedupeRepository: DedupeRepository,
        insta360Recovery: Insta360RescanRecovery? = nil, rescanContext: RescanContext? = nil,
        restoring draft: ImportDraft? = nil
    ) {
        insta360RescanRecovery = insta360Recovery.flatMap { $0.isEmpty ? nil : $0 }
        self.rescanContext = rescanContext
        currentSummary = summary
        if isReviewingScanBothVolume {
            validatePaths()
        }
        selectedJobID = summary.jobID
        selectedJobFiles = files
        currentPreviewFiles = files
        useOriginalInsta360Folders = true
        knownImportedPreviewFileIDs = Self.knownImportedFileIDs(files: files, dedupeRepository: dedupeRepository)
        refreshScanBothReviewHistory(files: files)
        applyRecommendationAfterScan(files: files, summary: summary)
        let defaultLabel = isReviewingScanBothVolume ? location : summary.location
        rebuildPreviewSessions(files: files, defaultLabel: defaultLabel, restoring: draft)
    }

    func returnToScanBothResults() {
        guard let jobID = scanBothSession?.reviewingJobID, !isWorking, !isEjectingSource else { return }
        let draft = currentImportDraft
        scanBothSession?.saveDraft(draft, needsAttention: previewNeedsAttention, for: jobID)
        scanBothSession?.reviewingJobID = nil
        folderAccessFeedback = nil
        currentSummary = nil
        currentImportReceipt = nil
        importProgress = nil
        previewSessions = []
        currentPreviewFiles = []
        knownImportedPreviewFileIDs = []
        mediaContentProfile = nil
        photoPairSummary = nil
        clearPreviewPlanCache()
        resetImportDraftFromDefaults()
        transitionImportWorkspace(.recover(hasScannedJob: true))
        loadSharedScanBothReview()
    }

    func skipScanBothImport(_ entryID: UUID) {
        guard !isWorking, !isEjectingSource,
              let entry = scanBothSession?.entries.first(where: { $0.id == entryID }), entry.canSkip else { return }
        if scanBothSession?.reviewingEntry?.id == entryID {
            returnToScanBothResults()
        }
        scanBothSession?.skipEntry(entryID)
        rebuildSharedScanBothReview()
        if folderAccessFeedbackIsScanBothCollision {
            folderAccessFeedback = nil
        }
    }

    private func promptContains(_ volume: MountedVolume, id: UUID, mountID: UUID) -> Bool {
        guard let prompt = pendingMountPrompt, prompt.id == id else { return false }
        return prompt.mountID(for: volume) == mountID
    }

    private func confirmScanOfCurrentVolume(_ volume: MountedVolume) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Scan the card currently mounted?")
        alert.informativeText = "\(volume.name)\n\(volume.mountPath)"
        alert.addButton(withTitle: L10n.tr("Scan Card"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    nonisolated private static func currentPromptVolume(matching expected: MountedVolume) -> MountedVolume? {
        guard let current = VolumeDetector().currentMountedVolume(from: expected.mountURL, includeCapacity: false),
              current.isSameMount(as: expected),
              MountHandoffVolumeIdentity.matchesCurrentVolume(
                  expectedUUID: expected.volumeUUID, currentUUID: current.volumeUUID
              ) else { return nil }
        return current
    }

    func skipMountedVolumePrompt(_ promptID: UUID) {
        guard mountPrompts.dismiss(promptID) else { return }
        statusMessage = L10n.tr("Ready")
    }

    @discardableResult
    func setAutoPromptEnabled(_ enabled: Bool) -> Bool {
        guard !isRepairingBackgroundPrompt else { return false }
        refreshBackgroundPromptHealth()
        guard backgroundPromptCanConfigure else {
            setBackgroundPromptFeedback { [weak self] in self?.backgroundPromptStatusDetail ?? "" }
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

        let changeID = UUID()
        backgroundPromptPreferenceChange = (changeID, enabled)
        backgroundPrompt.cancelPoll()
        enqueueBackgroundPromptOperation { model in
            await model.performAutoPromptPreferenceChange(enabled, changeID: changeID)
        }
        return true
    }

    private func performAutoPromptPreferenceChange(_ enabled: Bool, changeID: UUID) async {
        guard backgroundPromptPreferenceChange?.id == changeID else { return }
        defer {
            if backgroundPromptPreferenceChange?.id == changeID {
                backgroundPromptPreferenceChange = nil
            }
        }
        guard enabled == autoPromptEnabled else { return }

        backgroundPrompt.cancelPoll()
        loginItem.invalidateApplicationOwnershipCache()
        clearBackgroundPromptRuntimeError()
        backgroundPromptLaunchTimeout = nil
        var failure: Error?
        do {
            try authorizeCurrentBackgroundPromptHelperIfNeeded()
            if enabled {
                let statusBeforeEnable = loginItem.status
                if statusBeforeEnable == .notFound || statusBeforeEnable == .notRegistered {
                    backgroundPrompt.recordRegistrationAttempt()
                }
                // A superseded disable may leave the existing registration running.
                if statusBeforeEnable != .enabled {
                    backgroundPrompt.requireLaunch(after: Date())
                }
            }
            try await loginItem.setEnabled(enabled)
            guard backgroundPromptPreferenceChange?.id == changeID, enabled == autoPromptEnabled else { return }
            let health = refreshBackgroundPromptHealth()
            if enabled, backgroundPromptServiceStatus == .enabled {
                recordCurrentRepairIdentity()
                backgroundPrompt.clearRegistrationAttempt()
                if health == .waiting {
                    await scheduleBackgroundPromptHealthRefresh().value
                }
            } else if !enabled {
                backgroundPrompt.cancelRetry(resetAttempts: true)
            }
        } catch {
            guard backgroundPromptPreferenceChange?.id == changeID, enabled == autoPromptEnabled else { return }
            refreshBackgroundPromptHealth()
            recordBackgroundPromptError(error)
            failure = error
        }

        guard backgroundPromptPreferenceChange?.id == changeID, enabled == autoPromptEnabled else { return }
        backgroundPromptPreferenceChange = nil
        if enabled, backgroundPromptServiceStatus == .notFound || backgroundPromptServiceStatus == .notRegistered {
            scheduleRegistrationRetry()
        }
        if let failure {
            setBackgroundPromptFeedback(role: .error) {
                L10n.tr("Could not update background prompt: \(Self.errorMessage(for: failure))")
            }
        } else if enabled, backgroundPromptNeedsAttention {
            setBackgroundPromptFeedback { [weak self] in self?.backgroundPromptStatusDetail ?? "" }
        } else {
            setBackgroundPromptFeedback(role: .information) {
                enabled ? L10n.tr("Background prompt enabled") : L10n.tr("Background prompt disabled")
            }
        }
    }

    func updateLoginItemRegistration() {
        reconcileBackgroundPromptRegistration(showFeedback: true)
    }

    func applicationDidBecomeActive() {
        loginItem.invalidateApplicationOwnershipCache()
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
        guard backgroundPromptCanRepair else { return }
        objectWillChange.send()
        let repairID = backgroundPrompt.beginManualRepair()
        if statusMessageIsBackgroundPromptFeedback {
            statusMessage = ""
        }
        if settingsFeedback?.isBackgroundPrompt == true {
            settingsFeedback = nil
        }
        enqueueBackgroundPromptOperation { model in
            defer {
                model.objectWillChange.send()
                model.backgroundPrompt.finishManualRepair(repairID)
            }
            guard model.autoPromptEnabled else { return }
            await model.performBackgroundPromptRepair(userInitiated: true)
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
                ? L10n.tr("Install required")
                : L10n.tr("Managed by installed copy")
        }
        guard autoPromptEnabled else {
            return L10n.tr("Off")
        }
        if isStartingBackgroundPrompt {
            return L10n.tr("Starting background helper…")
        }
        if backgroundPromptEffectiveError != nil {
            return L10n.tr("Needs attention")
        }
        switch backgroundPromptServiceStatus {
        case .enabled:
            if backgroundPromptAgentMismatch {
                return L10n.tr("Helper update needed")
            }
            return backgroundPromptOwnsCurrentRegistration ? L10n.tr("Running") : L10n.tr("Needs attention")
        case .notRegistered:
            return L10n.tr("Not registered")
        case .requiresApproval:
            return L10n.tr("Needs approval")
        case .notFound:
            return L10n.tr("Helper missing")
        case .unknown:
            return L10n.tr("Unavailable")
        }
    }

    var backgroundPromptStatusDetail: String {
        guard backgroundPromptCanConfigure else {
            if let path = backgroundPromptApplicationOwnership.authoritativeApplicationPath {
                return L10n.tr("Background prompts are managed by the installed copy at \(path). Open that copy to change this setting.")
            }
            return L10n.tr("Move \(AppDistribution.current.displayName) to /Applications or ~/Applications before enabling background prompts.")
        }
        if isStartingBackgroundPrompt {
            return backgroundPromptStatusTitle
        }
        if let backgroundPromptEffectiveError {
            return backgroundPromptEffectiveError
        }
        guard autoPromptEnabled else {
            return L10n.tr("The background helper is disabled.")
        }
        switch backgroundPromptServiceStatus {
        case .enabled:
            if backgroundPromptAgentMismatch {
                return L10n.tr("The running helper does not match this app build. Repair it before relying on automatic prompts.")
            }
            return backgroundPromptOwnsCurrentRegistration
                ? L10n.tr("The background helper is registered with macOS.")
                : BackgroundPromptHealth.missingLaunchError
        case .notRegistered:
            return L10n.tr("The saved setting is on, but the background helper is not registered.")
        case .requiresApproval:
            return L10n.tr("Allow \(AppDistribution.current.displayName) in System Settings → General → Login Items & Extensions.")
        case .notFound:
            return L10n.tr("The bundled background helper could not be found. Reinstall \(AppDistribution.current.displayName) in Applications.")
        case .unknown:
            return L10n.tr("macOS returned an unrecognized background helper status.")
        }
    }

    var backgroundPromptNeedsAttention: Bool {
        !backgroundPromptCanConfigure
            || (autoPromptEnabled
            && !isStartingBackgroundPrompt
            && (!backgroundPromptOwnsCurrentRegistration
                || backgroundPromptEffectiveError != nil))
    }

    var backgroundPromptCanRepair: Bool {
        backgroundPromptCanConfigure
            && autoPromptEnabled
            && !isRepairingBackgroundPrompt
            && !isStartingBackgroundPrompt
            && backgroundPromptServiceStatus != .requiresApproval
    }

    private var backgroundPromptAgentMismatch: Bool {
        BackgroundPromptRegistrationPolicy.agentMismatch(
            state: backgroundPromptAgentState,
            expectedIdentity: currentRepairIdentity,
            lastRepairIdentity: lastRepairIdentity
        )
    }

    private var backgroundPromptOwnsCurrentRegistration: Bool {
        autoPromptEnabled
            && backgroundPromptCanConfigure
            && BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
                identity: currentRepairIdentity,
                serviceStatus: backgroundPromptServiceStatus,
                liveAgentState: backgroundPromptAgentState,
                minimumLaunchAt: backgroundPrompt.minimumLaunchAt
            )
    }

    private var backgroundPromptEffectiveError: String? {
        if backgroundPromptDiagnosticsReadFailed && !backgroundPromptLastErrorIsRepairFailure {
            return L10n.tr("Could not read background helper diagnostics")
        }
        let launchTimeout = backgroundPromptServiceStatus == .enabled ? backgroundPromptLaunchTimeout?.text : nil
        return BackgroundPromptHealth.effectiveError(
            appError: backgroundPromptLastError ?? launchTimeout,
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

    private func recordCurrentRepairIdentity() {
        guard let data = try? JSONEncoder().encode(currentRepairIdentity) else {
            return
        }
        defaults.set(data, forKey: DefaultsKeys.lastLoginItemRepairIdentity)
        loginItem.invalidateApplicationOwnershipCache()
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
            lastAttemptAt: backgroundPrompt.lastRegistrationAttemptAt,
            now: backgroundPrompt.now()
        )
        backgroundPrompt.scheduleRetry(after: delay) { [weak self] in
            self?.reconcileBackgroundPromptRegistration()
        }
    }

    private func scheduleMissingHelperHealthRepair() {
        guard
            autoPromptEnabled,
            hasCompletedOnboarding,
            backgroundPromptCanConfigure,
            backgroundPromptServiceStatus == .enabled
        else {
            return
        }
        backgroundPrompt.scheduleRetry(after: backgroundPrompt.healthRetryDelay) { [weak self] in
            guard let self else {
                return
            }
            self.enqueueBackgroundPromptOperation { model in
                await model.performScheduledMissingHelperHealthRepair()
            }
        }
    }

    private func performScheduledMissingHelperHealthRepair() async {
        let health = refreshBackgroundPromptHealth()
        let ownsRegistration = health == .ready
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
                backgroundPrompt.cancelRetry(
                    resetAttempts: !autoPromptEnabled || !backgroundPromptCanConfigure || ownsRegistration
                )
            }
            return
        }
        // Another retry may have run while this operation was waiting in the queue.
        if backgroundPrompt.healthRetryDelay > 0 {
            scheduleMissingHelperHealthRepair()
            return
        }
        backgroundPrompt.recordHealthRepair()
        // Recheck on the cooldown when diagnostics can't establish whether the helper is already healthy.
        if health != .diagnosticsUnavailable {
            await performBackgroundPromptRepair(userInitiated: false)
        }
        if backgroundPromptDiagnosticsReadFailed, backgroundPromptLaunchTimeout != nil {
            scheduleMissingHelperHealthRepair()
        }
    }

    private func performBackgroundPromptRepair(userInitiated: Bool) async {
        backgroundPrompt.cancelPoll()
        loginItem.invalidateApplicationOwnershipCache()
        let initialHealth = refreshBackgroundPromptHealth()
        guard backgroundPromptCanConfigure else {
            backgroundPrompt.cancelRetry(resetAttempts: true)
            return
        }
        guard userInitiated || initialHealth == .waiting else { return }
        clearBackgroundPromptRuntimeError()
        do {
            try authorizeCurrentBackgroundPromptHelperIfNeeded()
            backgroundPrompt.recordRegistrationAttempt()
            backgroundPromptServiceStatus = try await repairBackgroundPromptService(userInitiated: userInitiated)
            if backgroundPromptServiceStatus == .enabled {
                recordCurrentRepairIdentity()
                backgroundPrompt.clearRegistrationAttempt()
            }
            let health = refreshBackgroundPromptHealth()
            if backgroundPromptServiceStatus == .enabled, health == .waiting,
               autoPromptEnabled, backgroundPromptCanConfigure {
                let refreshTask = scheduleBackgroundPromptHealthRefresh()
                if userInitiated {
                    await refreshTask.value
                }
            }
            if backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            }
        } catch {
            refreshBackgroundPromptHealth()
            let message = { L10n.tr("Could not repair background prompt: \(Self.errorMessage(for: error))") }
            recordBackgroundPromptError(message(), render: message, isRepairFailure: true)
            if backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            }
        }
    }

    private func repairBackgroundPromptService(
        userInitiated: Bool,
        clearErrorOnRegistration: Bool = false
    ) async throws -> BackgroundPromptServiceStatus {
        let registrationID = backgroundPrompt.beginRegistration()
        defer { backgroundPrompt.finishRegistration(registrationID) }
        return try await loginItem.repair(
            didRegister: {
                if clearErrorOnRegistration { clearBackgroundPromptRepairError() }
            },
            requireLaunchAfter: { backgroundPrompt.requireLaunch(after: $0, registrationID: registrationID) }
        ) { [weak self] in
            guard let self, self.backgroundPrompt.isCurrentRegistration(registrationID),
                  self.autoPromptEnabled, userInitiated || self.hasCompletedOnboarding else {
                return false
            }
            self.loginItem.invalidateApplicationOwnershipCache()
            return self.loginItem.applicationOwnership.isCurrentApplicationAuthoritative
        }
    }

    private func performBackgroundPromptReconciliation(showFeedback: Bool) async {
        backgroundPrompt.cancelPoll()
        loginItem.invalidateApplicationOwnershipCache()
        refreshBackgroundPromptHealth()
        guard hasCompletedOnboarding else {
            backgroundPrompt.cancelRetry(resetAttempts: false)
            return
        }
        guard backgroundPromptCanConfigure else {
            backgroundPrompt.cancelRetry(resetAttempts: true)
            if showFeedback {
                setBackgroundPromptFeedback { [weak self] in self?.backgroundPromptStatusDetail ?? "" }
            }
            return
        }

        do {
            try authorizeCurrentBackgroundPromptHelperIfNeeded()
            if shouldRefreshMismatchedBackgroundHelper {
                if backgroundPromptServiceStatus == .notFound
                    || backgroundPromptServiceStatus == .notRegistered {
                    backgroundPrompt.recordRegistrationAttempt()
                }
                backgroundPromptServiceStatus = try await repairBackgroundPromptService(
                    userInitiated: false, clearErrorOnRegistration: true
                )
                if backgroundPromptServiceStatus == .enabled {
                    recordCurrentRepairIdentity()
                    backgroundPrompt.clearRegistrationAttempt()
                }
            } else {
                let statusBeforeReconciliation = backgroundPromptServiceStatus
                let now = backgroundPrompt.now()
                let allowRegistrationAttempt = BackgroundPromptRegistrationPolicy
                    .allowsNotFoundRegistration(lastAttemptAt: backgroundPrompt.lastRegistrationAttemptAt, now: now)
                let willAttemptRegistration = BackgroundPromptRegistrationPolicy
                    .shouldAttemptMissingRegistration(
                        desiredEnabled: autoPromptEnabled,
                        serviceStatus: statusBeforeReconciliation,
                        lastAttemptAt: backgroundPrompt.lastRegistrationAttemptAt,
                        now: now
                    )
                let registrationIsMissing = statusBeforeReconciliation == .notRegistered
                    || statusBeforeReconciliation == .notFound
                if willAttemptRegistration {
                    backgroundPrompt.recordRegistrationAttempt()
                    backgroundPrompt.requireLaunch(after: Date())
                }
                backgroundPromptServiceStatus = try await loginItem.reconcile(
                    desiredEnabled: autoPromptEnabled
                        && (!registrationIsMissing || willAttemptRegistration),
                    allowNotFoundRegistration: allowRegistrationAttempt,
                    didRegister: clearBackgroundPromptRepairError
                )
                if
                    autoPromptEnabled,
                    statusBeforeReconciliation == .notRegistered,
                    backgroundPromptServiceStatus == .enabled
                {
                    recordCurrentRepairIdentity()
                    backgroundPrompt.clearRegistrationAttempt()
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
                backgroundPrompt.cancelRetry(resetAttempts: true)
            } else {
                backgroundPrompt.cancelRetry(resetAttempts: false)
            }

            if showFeedback {
                setBackgroundPromptFeedback { [weak self] in self?.backgroundPromptStatusDetail ?? "" }
            }
        } catch {
            backgroundPromptServiceStatus = loginItem.status
            recordBackgroundPromptError(error)
            if backgroundPromptServiceStatus == .notFound
                || backgroundPromptServiceStatus == .notRegistered {
                scheduleRegistrationRetry()
            } else {
                backgroundPrompt.cancelRetry(resetAttempts: false)
            }
            setBackgroundPromptFeedback(role: .error) { L10n.tr("Could not update background prompt: \(Self.errorMessage(for: error))") }
        }
    }

    private var shouldRefreshMismatchedBackgroundHelper: Bool {
        BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
            desiredEnabled: autoPromptEnabled,
            serviceStatus: backgroundPromptServiceStatus,
            embeddedHelperExists: loginItem.embeddedAgentExists,
            state: backgroundPromptAgentState,
            expectedIdentity: currentRepairIdentity,
            lastRepairIdentity: lastRepairIdentity,
            lastNotFoundRepairAttemptAt: backgroundPrompt.lastRegistrationAttemptAt,
            now: backgroundPrompt.now()
        )
    }

    private func enqueueBackgroundPromptOperation(
        _ operation: @escaping @MainActor (AppModel) async -> Void
    ) {
        backgroundPrompt.enqueue { [weak self] in
            guard let self else { return }
            await operation(self)
        }
    }

    private func recordBackgroundPromptError(
        _ message: String,
        render: (() -> String)? = nil,
        eventSequence: UInt64? = nil,
        isRepairFailure: Bool = false
    ) {
        let sequence: UInt64
        if let eventSequence {
            sequence = eventSequence
        } else {
            do {
                sequence = try backgroundPromptStateStore()
                    .reserveDiagnosticSequence(
                        agentBuild: currentAppBuild,
                        agentBundlePath: expectedEmbeddedAgentPath
                    )
            } catch {
                let issuedSequence = (try? backgroundPromptStateStore()
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
        backgroundPromptLastErrorIsRepairFailure = isRepairFailure
        backgroundPromptLastError = message
        backgroundPromptLastErrorContent = RelocalizableMessage(message, render: render)
        backgroundPromptLastErrorSequence = sequence
        refreshBackgroundPromptSettingsFeedbackIfNeeded()
    }

    private func recordBackgroundPromptError(_ error: Error) {
        let render = { Self.errorMessage(for: error) }
        recordBackgroundPromptError(render(), render: render)
    }

    private func clearBackgroundPromptRuntimeError() {
        backgroundPromptLastError = nil
        backgroundPromptLastErrorSequence = nil
    }

    private func clearBackgroundPromptRepairError() {
        if backgroundPromptLastErrorIsRepairFailure {
            clearBackgroundPromptRuntimeError()
        }
    }

    enum BackgroundPromptHealthRefresh {
        case ready
        case waiting
        case diagnosticsUnavailable
    }

    @discardableResult
    func refreshBackgroundPromptHealth() -> BackgroundPromptHealthRefresh {
        backgroundPromptApplicationOwnership = loginItem.applicationOwnership
        backgroundPromptServiceStatus = loginItem.status
        let health: BackgroundPromptHealthRefresh
        do {
            backgroundPromptAgentState = try backgroundPromptStateStore().load()
            backgroundPromptDiagnosticsReadFailed = false
            if BackgroundPromptHealth.shouldPreferAgentError(
                appErrorSequence: backgroundPromptLastErrorSequence,
                agentErrorSequence: backgroundPromptAgentState?.lastErrorSequence
            ) {
                clearBackgroundPromptRuntimeError()
            }
            health = backgroundPromptOwnsCurrentRegistration ? .ready : .waiting
        } catch {
            backgroundPromptAgentState = nil
            backgroundPromptDiagnosticsReadFailed = true
            health = .diagnosticsUnavailable
        }
        if health == .ready || !autoPromptEnabled {
            backgroundPromptLaunchTimeout = nil
        }
        let interruptedLaunchRecovery = health == .diagnosticsUnavailable
            && backgroundPromptLaunchTimeout != nil
            && backgroundPrompt.isPolling
        if health != .waiting || !autoPromptEnabled || !backgroundPromptCanConfigure
            || backgroundPromptServiceStatus == .requiresApproval {
            backgroundPrompt.cancelPoll()
        }
        if health == .ready {
            backgroundPrompt.cancelRetry(resetAttempts: true)
            mountObserver?.consumePendingHandoffs()
        } else if !backgroundPromptCanConfigure || !autoPromptEnabled {
            backgroundPrompt.cancelRetry(resetAttempts: true)
        } else if interruptedLaunchRecovery {
            scheduleMissingHelperHealthRepair()
        }
        refreshBackgroundPromptSettingsFeedbackIfNeeded()
        return health
    }

    private func authorizeCurrentBackgroundPromptHelperIfNeeded() throws {
        guard backgroundPromptCanConfigure else {
            return
        }
        try backgroundPromptStateStore().authorize(
            agentBuild: currentAppBuild,
            agentBundlePath: expectedEmbeddedAgentPath
        )
    }

    @discardableResult
    private func scheduleBackgroundPromptHealthRefresh() -> Task<Void, Never> {
        backgroundPrompt.pollForLaunch(
            whileWaiting: { [weak self] in self?.refreshBackgroundPromptHealth() == .waiting },
            timedOut: { [weak self] in self?.backgroundPromptPollingTimedOut() }
        )
    }

    private func backgroundPromptPollingTimedOut() {
        guard autoPromptEnabled, backgroundPromptCanConfigure, backgroundPromptServiceStatus == .enabled else {
            return
        }
        let state = backgroundPromptAgentState
        let identity = currentRepairIdentity
        let message = { BackgroundPromptHealth.ownershipTimeoutError(state: state, expectedIdentity: identity) }
        backgroundPromptLaunchTimeout = RelocalizableMessage(message(), render: message)
        refreshBackgroundPromptSettingsFeedbackIfNeeded()
        scheduleMissingHelperHealthRepair()
    }

    func refreshHistory() {
        guard let databaseURL else {
            statusMessage = L10n.tr("Database is not ready")
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
                    guard !Task.isCancelled else { return }
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
                    guard !Task.isCancelled else { return }
                    self.isHistoryLoading = false
                    self.isHistoryDetailLoading = false
                    self.historyRefreshTask = nil
                    let detail = Self.errorMessage(for: error)
                    self.setLocalizedStatusMessage { L10n.tr("Could not load history: \(detail)") }
                }
            }
        }
    }

    func openImportInHistory(jobID: String) {
        loadJobDetail(jobID: jobID)
        selection = .history
    }

    func loadJobDetail(jobID: String) {
        guard selectedJobID != jobID || selectedJobFiles.isEmpty else {
            return
        }
        selectedJobID = jobID
        selectedJobFiles = []
        guard let databaseURL else {
            statusMessage = L10n.tr("Database is not ready")
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
                    guard !Task.isCancelled, self.selectedJobID == jobID else {
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
                    guard !Task.isCancelled, self.selectedJobID == jobID else {
                        return
                    }
                    self.selectedJobFiles = []
                    self.isHistoryDetailLoading = false
                    self.historyDetailTask = nil
                    let detail = Self.errorMessage(for: error)
                    self.setLocalizedStatusMessage { L10n.tr("Could not load job: \(detail)") }
                }
            }
        }
    }

    func needsRescan(_ jobID: String) -> Bool {
        jobsRequiringRescan.contains(jobID)
    }

    func rescanSource(startingAt path: String, recoveringJobID: String) {
        guard !isWorking, !isEjectingSource else { return }
        guard let databaseURL else {
            showFolderAccessError { L10n.tr("Database is not ready") }
            return
        }
        guard confirmLeavingScanBothResults(actionTitle: L10n.tr("Start New Scan")),
              let url = chooseCardFolderURL(startingAt: path) else { return }
        // Keep the current source bookmark until the rescan is ready to start.
        let sourceAccess = SecurityScopedResourceAccess(url: url)
        defer { withExtendedLifetime(sourceAccess) {} }
        guard let chosenPath = validatedSelectedSourcePath(url),
              let recovering = prepareRescan(recoveringJobID, sourcePath: chosenPath),
              retainSelectedFolderAccess(.source, url: url, persistBookmark: true) else { return }
        retainPendingScanBothResults()
        selectSourcePath(chosenPath)
        resetImportDraftFromDefaults()
        selection = .import
        startScan(at: chosenPath, databaseURL: databaseURL, recovering: recovering)
    }

    private func prepareRescan(_ jobID: String, sourcePath: String) -> RescanContext? {
        let belongsToSession = scanBothSession?.entry(for: jobID) != nil
        // The check below matches live grants to destination folders across rescans.
        let previousAccess = rescanContext?.access ?? []
        let sessionAccess = belongsToSession ? scanBothDestinationAccess : []
        var grantedPaths: Set<String> = []
        var access = (sessionAccess + previousAccess + Array(folderAccesses.values)).filter {
            $0.isActive && grantedPaths.insert($0.url.standardizedFileURL.path).inserted
        }
        guard let jobRepository else {
            showFolderAccessError { L10n.tr("Database is not ready") }
            return nil
        }

        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let request = scanRequest(
            mountURL: sourceURL,
            sourceVolume: VolumeDetector().removableSourceVolume(containing: sourceURL),
            rescanOfJobID: jobID
        )
        let preparation: Insta360RescanRecovery.Preparation
        do {
            preparation = try Insta360RescanRecovery.prepare(
                request: request, jobRepository: jobRepository
            )
        } catch {
            showFolderAccessError { Self.errorMessage(for: error) }
            return nil
        }
        func context() -> RescanContext {
            RescanContext(jobID: jobID, access: access, preparation: preparation)
        }
        guard AppDistribution.current == .macAppStore else { return context() }

        let sharedFolder = belongsToSession ? scanBothSession?.destinationRoot?.url : nil
        func canVerifyCopies(in folder: URL) -> Bool {
            access.contains { Self.isSameOrDescendant(folder, of: $0.url) }
                && PathValidator().validate(path: folder.path, purpose: .destination).status != .unwritable
        }
        var missingFolders: [URL: [URL]] = [:]
        for folder in preparation.destinationFolders where !canVerifyCopies(in: folder) {
            let suggested = sharedFolder.flatMap { Self.isSameOrDescendant(folder, of: $0) ? $0 : nil } ?? folder
            missingFolders[suggested, default: []].append(folder)
        }
        guard !missingFolders.isEmpty else { return context() }

        let alert = NSAlert()
        alert.messageText = L10n.tr("Allow Access to Original Destinations")
        alert.informativeText = L10n.tr("SD Card Import can check the Insta360 files already copied if you allow access to their folders. Continuing without access may include those files in the new plan.")
        alert.addButton(withTitle: L10n.tr("Allow Access"))
        alert.addButton(withTitle: L10n.tr("Continue Without Access"))
        alert.addButton(withTitle: L10n.tr("Cancel")).keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            return context()
        case .alertFirstButtonReturn:
            break
        default:
            return nil
        }

        for (suggested, folders) in missingFolders.sorted(by: { $0.key.path < $1.key.path }) {
            guard !folders.allSatisfy(canVerifyCopies(in:)) else { continue }
            guard let url = FilePanelPresenter.chooseDirectoryURL(
                title: L10n.tr("Allow Access to \(suggested.lastPathComponent)"),
                initialPath: suggested.path,
                prompt: L10n.tr("Allow Access")
            ) else { return nil }
            let grant = SecurityScopedResourceAccess(url: url)
            guard grant.isActive, folders.allSatisfy({ Self.isSameOrDescendant($0, of: url) }) else {
                let destination = suggested.path
                showFolderAccessError { L10n.tr("Choose \(destination) to restore access.") }
                return nil
            }
            access.append(grant)
        }
        return context()
    }

    private func requireRescan(for jobID: String) {
        jobsRequiringRescan.insert(jobID)
        scanBothSession?.setConfirmation(nil, for: jobID)
        showFolderAccessError { L10n.tr("Source changed since scan; scan again") }
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
            statusMessage = L10n.tr("Ready")
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
        statusMessage = L10n.tr("Setup skipped. Defaults can be changed in Settings.")
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
            statusMessage = L10n.tr("No report file found")
        }
    }

    func viewReport(for job: ImportJob) {
        guard let databaseURL else {
            reportPresentation = ImportReportPresentation(
                job: job,
                report: nil,
                files: selectedJobID == job.id ? selectedJobFiles : [],
                loadErrors: [.databaseNotReady]
            )
            return
        }

        reportTask?.cancel()
        let cachedFiles = selectedJobID == job.id ? selectedJobFiles : []
        let jsonPath = job.summaryJSONPath
        statusMessage = L10n.tr("Loading report...")

        reportTask = Task.detached(priority: .userInitiated) {
            let reportLoader = ImportReportLoader()
            var report: ImportReport?
            var files: [JobFileRecord] = []
            var loadErrors: [ReportLoadError] = []

            if let jsonPath {
                do {
                    report = try reportLoader.loadJSON(from: URL(fileURLWithPath: jsonPath))
                } catch {
                    loadErrors.append(.jsonReport(Self.errorMessage(for: error)))
                }
            }

            do {
                let repositories = try Self.makeRepositories(databaseURL: databaseURL)
                files = try repositories.jobRepository.fetchJobFiles(jobID: job.id)
            } catch {
                loadErrors.append(.jobFiles(Self.errorMessage(for: error)))
                files = cachedFiles.isEmpty ? (report?.files ?? []) : cachedFiles
            }

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.reportPresentation = ImportReportPresentation(
                    job: job,
                    report: report,
                    files: files,
                    loadErrors: loadErrors
                )
                self.statusMessage = loadErrors.isEmpty ? L10n.tr("Report ready") : L10n.tr("Report opened with warnings")
                self.reportTask = nil
            }
        }
    }

    func openReportFile(for job: ImportJob) {
        guard let path = existingReportPath(for: job) else {
            statusMessage = L10n.tr("No report file found")
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
        statusMessage = L10n.tr("Summary copied")
    }

    func exportSummary(for job: ImportJob) {
        guard let url = FilePanelPresenter.chooseSaveURL(
            title: L10n.tr("Export Summary"),
            suggestedName: "\(job.id)-summary.txt"
        ) else {
            return
        }

        do {
            try summaryText(for: job).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = L10n.tr("Summary exported")
        } catch {
            let detail = Self.errorMessage(for: error)
            setLocalizedStatusMessage { L10n.tr("Could not export summary: \(detail)") }
        }
    }

    func sendFeedback() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let url = AppSupport.feedbackEmailURL(
            appName: AppDistribution.current.displayName,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "dev",
            appBuild: info["CFBundleVersion"] as? String ?? "dev",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        ), NSWorkspace.shared.open(url) else {
            isShowingFeedbackEmailUnavailable = true
            return
        }
    }

    func copyFeedbackEmailAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppSupport.emailAddress, forType: .string)
    }

    func copyDiagnostics() {
        let text = diagnosticsText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        diagnosticsLogger.notice("Diagnostics copied")
        statusMessage = L10n.tr("Diagnostics copied")
    }

    func exportDiagnostics() {
        guard let url = FilePanelPresenter.chooseSaveURL(
            title: L10n.tr("Export Diagnostics"),
            suggestedName: "sd-import-diagnostics.md"
        ) else {
            return
        }

        do {
            try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
            diagnosticsLogger.notice("Diagnostics exported")
            statusMessage = L10n.tr("Diagnostics exported")
        } catch {
            diagnosticsLogger.error("Diagnostics export failed errorType=\(String(describing: type(of: error)), privacy: .public)")
            let detail = Self.errorMessage(for: error)
            setLocalizedStatusMessage { L10n.tr("Could not export diagnostics: \(detail)") }
        }
    }

    func revealCrashReportsFolder() {
        guard AppDistribution.current.canBrowseSystemCrashReports else {
            statusMessage = L10n.tr("Crash reports remain available in macOS Console")
            return
        }
        let directory = CrashReportLocator.defaultDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            statusMessage = L10n.tr("No crash report folder found")
            return
        }

        NSWorkspace.shared.open(directory)
        diagnosticsLogger.notice("Crash reports folder revealed")
        statusMessage = L10n.tr("Crash reports folder opened")
    }

    func exportLatestCrashReport() {
        guard AppDistribution.current.canBrowseSystemCrashReports else {
            statusMessage = L10n.tr("Crash reports remain available in macOS Console")
            return
        }
        guard let report = CrashReportLocator.findReports(limit: 1).first else {
            setLocalizedStatusMessage { L10n.tr("No \(AppDistribution.current.displayName) crash reports found") }
            return
        }

        let suggestedName = "sd-import-crash-report.\(report.url.pathExtension.lowercased())"
        guard let url = FilePanelPresenter.chooseSaveURL(
            title: L10n.tr("Export Latest Crash Report"),
            suggestedName: suggestedName
        ) else {
            return
        }

        do {
            let data = try Data(contentsOf: report.url)
            try data.write(to: url, options: .atomic)
            diagnosticsLogger.notice("Crash report exported")
            statusMessage = L10n.tr("Crash report exported")
        } catch {
            diagnosticsLogger.error("Crash report export failed errorType=\(String(describing: type(of: error)), privacy: .public)")
            let detail = Self.errorMessage(for: error)
            setLocalizedStatusMessage { L10n.tr("Could not export crash report: \(detail)") }
        }
    }

    func pruneHistory(dryRun: Bool) {
        guard let databaseURL else {
            statusMessage = L10n.tr("Database is not ready")
            setSettingsFeedbackFromStatus(role: .error)
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
                let count = summary.matchedJobs
                setLocalizedStatusMessage { L10n.tr("\(count) old jobs would be deleted") }
            } else {
                let count = summary.deletedJobs
                setLocalizedStatusMessage { L10n.tr("Deleted \(count) old jobs") }
            }
            setSettingsFeedbackFromStatus(role: .information)
        } catch {
            setLocalizedStatusMessage { L10n.tr("Could not prune history: \(Self.errorMessage(for: error))") }
            setSettingsFeedbackFromStatus(role: .error)
        }
    }

    func forgetImportedFiles(for job: ImportJob) throws {
        guard let dedupeRepository else {
            throw SDImportError.invalidArgument(L10n.tr("Import history is not ready"))
        }

        try dedupeRepository.forgetImportedFiles(jobID: job.id)
        refreshHistory()
        loadSharedScanBothReview()
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
        return scanBothAllowsEjection(for: result.jobID) && cachedResultSourceEjectionTargets[result.jobID] != nil
    }

    func canEjectSource(for result: ImportResult) -> Bool {
        AppDistribution.current.supportsSourceEjection
            && scanBothAllowsEjection(for: result.jobID)
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
            scanBothAllowsEjection(for: result.jobID),
            !isEjectingSource,
            let target = cachedResultSourceEjectionTargets[result.jobID]
        else {
            statusMessage = L10n.tr("Source cannot be ejected safely")
            return
        }

        ejectSource(jobID: result.jobID, target: target)
    }

    private func scanBothAllowsEjection(for jobID: String) -> Bool {
        guard let session = scanBothSession, session.entry(for: jobID) != nil else { return true }
        return session.allowsEjection
    }

    private var scanBothManualEjectionTarget: SourceEjectionTarget? {
        guard AppDistribution.current.supportsSourceEjection, isShowingScanBothResults,
              !isWorking, !isEjectingSource, ejectedSourceJobID == nil,
              let session = scanBothSession, session.allowsEjection,
              let destinations = session.confirmedDestinationPaths else { return nil }
        let policy = SourceEjectionPolicy()
        let liveVolumes = session.entries.compactMap { entry in
            mountedVolumesSnapshot.first {
                $0.isSameMount(as: entry.volume) && policy.canEjectCurrentVolume($0, matching: entry.volume)
            }
        }
        guard liveVolumes.count == session.entries.count, let source = liveVolumes.first,
              let target = sourceEjectionTarget(
                sourceVolume: source,
                destinationPaths: destinations,
                mountedVolumes: mountedVolumesSnapshot
              ),
              Set(liveVolumes.map(\.mountPath)).isSubset(of: Set(target.volumes.map(\.mountPath)))
        else { return nil }
        return target
    }

    var canEjectScanBoth: Bool { scanBothManualEjectionTarget != nil }

    func ejectScanBoth() {
        guard let target = scanBothManualEjectionTarget,
              let sessionID = scanBothSession?.entries.first?.id else { return }
        ejectSource(jobID: sessionID.uuidString, target: target)
    }

    private func autoEjectAfterImport(_ result: ImportResult) {
        guard ejectAfterSuccessfulImport, result.importedFiles > 0, canEjectSource(for: result) else { return }
        if let session = scanBothSession, session.entry(for: result.jobID) != nil, !session.allowsAutomaticEjection {
            return
        }
        ejectSource(for: result)
    }

    private func ejectSource(jobID: String, target: SourceEjectionTarget) {
        guard AppDistribution.current.supportsSourceEjection else {
            statusMessage = L10n.tr("Eject the source in Finder")
            return
        }
        guard !isWorking, !isEjectingSource else {
            statusMessage = L10n.tr("Finish the current operation before ejecting")
            return
        }
        let attemptID = beginImportAttempt(
            .eject, event: .beginAuxiliaryOperation(.eject),
            retryContext: .eject(jobID: jobID, target: target)
        )
        if target.volumeCount > 1 {
            let name = target.displayName
            setLocalizedStatusMessage { L10n.tr("Ejecting \(name) storage...") }
        } else {
            statusMessage = L10n.tr("Ejecting source...")
        }
        sourceEjectionTask?.cancel()
        sourceEjectionTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await Self.ejectDevice(target)
                guard self.importAttempt?.accepts(attemptID) == true else { return }
                if Task.isCancelled {
                    self.finishImportAttempt(attemptID, event: .endAuxiliaryOperation)
                    return
                }
                self.ejectedSourceName = target.displayName
                self.ejectedSourceVolumeCount = target.volumeCount
                self.ejectedSourceJobID = jobID
                self.finishImportAttempt(attemptID, event: .endAuxiliaryOperation)
                self.refreshAvailableSourceVolumes()
                self.validatePaths()
                if target.volumeCount > 1 {
                    let name = target.displayName
                    self.setLocalizedStatusMessage { L10n.tr("\(name) ejected safely") }
                } else {
                    self.statusMessage = L10n.tr("Source ejected safely")
                }
            } catch is CancellationError {
                self.finishImportAttempt(attemptID, event: .endAuxiliaryOperation)
            } catch {
                guard self.importAttempt?.accepts(attemptID) == true else { return }
                let render: () -> String = { L10n.tr("Could not eject source: \(error.localizedDescription)") }
                self.setLocalizedStatusMessage(render)
                let message = self.statusMessage
                self.finishImportAttempt(
                    attemptID, event: .failed(operation: .eject, message: message), failureRenderer: render
                )
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
        if isReviewingScanBothVolume, scanBothSession?.destinationRoot?.matches() != true {
            return false
        }
        if useOriginalInsta360Folders, let recovery = insta360RescanRecovery {
            let copyRows = previewRows.filter(\.willCopy)
            let originalFolders = copyRows.compactMap { recovery.originalFolder(for: $0.sourcePath) }
            if AppDistribution.current == .macAppStore,
               originalFolders.contains(where: {
                   !hasActiveFolderAccess(covering: $0.path, additionalAccess: rescanContext?.access ?? [])
               }) {
                return false
            }
            if !copyRows.isEmpty, originalFolders.count == copyRows.count {
                return true
            }
        }
        let access = isReviewingScanBothVolume ? scanBothDestinationAccess : []
        return requiredDestinationValidations().allSatisfy {
            $0.isUsable && !destinationNeedsAccess($0, additionalAccess: access)
        }
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

    private func refreshScanBothPreviewDates(previousSessions: [ImportPreviewSession]? = nil) -> PreviewPlan? {
        guard let jobID = scanBothSession?.reviewingJobID, jobID == currentSummary?.jobID else {
            return nil
        }
        return rebuildPreviewSessions(files: currentPreviewFiles, defaultLabel: location, previousSessions: previousSessions)
    }

    @discardableResult
    private func rebuildPreviewSessions(
        files: [JobFileRecord], defaultLabel: String, restoring draft: ImportDraft? = nil,
        previousSessions: [ImportPreviewSession]? = nil
    ) -> PreviewPlan? {
        let priorSessions = draft?.sessions ?? previousSessions ?? previewSessions
        let previousHidden = draft?.hiddenSessions ?? hiddenPreviewSessions
        let visible = Dictionary(uniqueKeysWithValues: priorSessions.map { ($0.date, $0) })
        let existing = previousHidden.merging(visible) { _, visible in visible }
        let sessions = makePreviewSessions(files: files, defaultLabel: defaultLabel, existing: existing)
        let choicesByDate = Dictionary(uniqueKeysWithValues: sessions.map { ($0.date, $0) })
        // Start with the current shoot range while retaining the choices for every scanned date.
        let planningSessions = folderGrouping == .oneShootFolder && !priorSessions.isEmpty
            ? sessions.filter { visible[$0.date] != nil } : sessions
        guard let initialPlan = makePreviewPlan(files: files, sessions: planningSessions, hiddenSessions: choicesByDate) else {
            return nil
        }
        let updated = ImportPreviewSessionFilter().visibleSessions(
            files: files,
            plans: initialPlan.files,
            sessions: sessions,
            importMediaSelection: importMediaSelection,
            organizationPreset: organizationPreset,
            folderGrouping: folderGrouping
        )
        let plan: PreviewPlan
        if folderGrouping == .oneShootFolder,
           ImportPlanBuilder.dateRangeTitle(for: planningSessions.map(\.date)) != ImportPlanBuilder.dateRangeTitle(for: updated.map(\.date)) {
            guard let rangedPlan = makePreviewPlan(files: files, sessions: updated, hiddenSessions: choicesByDate) else {
                return nil
            }
            plan = rangedPlan
        } else {
            plan = initialPlan
        }
        // Clearing a re-import selection can hide a date until it is included again.
        let visibleDates = Set(updated.map(\.date))
        hiddenPreviewSessions = existing.filter { !visibleDates.contains($0.key) }
        visiblePreviewSessions = updated
        updatePreviewPlanCache(rows: makePreviewRows(files: files, plans: plan.files))
        return plan
    }

    private var defaultDateInclusion: (photos: Bool, videos: Bool, sidecars: Bool) {
        (
            organizationPreset != .footageBackup && importMediaSelection.includes(.photo),
            importMediaSelection.includes(.video),
            workflowProfile.includesSidecarsByDefault
        )
    }

    private func makePreviewSessions(
        files: [JobFileRecord],
        defaultLabel: String,
        existing: [String: ImportPreviewSession],
        inclusion: (photos: Bool, videos: Bool, sidecars: Bool)? = nil
    ) -> [ImportPreviewSession] {
        let grouped = Dictionary(grouping: files) { ImportPlanBuilder.sessionDate(for: $0) }
        let defaults = inclusion ?? defaultDateInclusion
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
                includePhotos: prior?.includePhotos ?? defaults.photos,
                includeVideos: prior?.includeVideos ?? defaults.videos,
                includeSidecars: prior?.includeSidecars ?? defaults.sidecars
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
    ) throws -> (jobs: [ImportJob], files: [JobFileRecord], job: ImportJob?) {
        let repositories = try makeRepositories(databaseURL: databaseURL)
        return (
            try repositories.jobRepository.listImportHistoryJobs(limit: 100),
            try repositories.jobRepository.fetchJobFiles(jobID: jobID),
            try repositories.jobRepository.fetchJob(id: jobID)
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

    private func refreshScanBothReviewHistory(files: [JobFileRecord]) {
        guard let entry = scanBothSession?.reviewingEntry, let summary = currentSummary,
              let jobRepository, let dedupeRepository else {
            scanBothReviewHistory = [:]
            return
        }
        let engine = ImportEngine(
            jobRepository: jobRepository, dedupeRepository: dedupeRepository,
            portableReceiptsEnabled: portableImportReceiptsEnabled,
            reviewedSourceFiles: entry.reviewedSourceFiles
        )
        scanBothReviewHistory = engine.refreshedReviewHistory(files: files, sourcePath: summary.mountPath)
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
            let detail = Self.errorMessage(for: error)
            setLocalizedStatusMessage { L10n.tr("Could not refresh background prompt settings: \(detail)") }
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
            sourcePath: isReviewingScanBothVolume
                ? PathValidator().validate(path: cardPath, purpose: .source).expandedPath
                : resolvedPath(cardPath, validation: sourceValidation),
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
        folderAccessFeedback = nil
        if purpose == .source {
            let validation = PathValidator().validate(
                path: url.path, purpose: .source, allowsWhitespaceFallback: false
            )
            if validation.status == .symbolicLink {
                showFolderAccessError { validation.message }
                return false
            }
        }
        let priorAccess = folderAccesses[purpose]
        do {
            let access: SecurityScopedResourceAccess?
            if persistBookmark {
                guard let bookmarkStore else {
                    throw FolderAccessAuthorizationError(purpose: purpose)
                }
                try bookmarkStore.saveBookmark(purpose: purpose, url: url)
                refreshFolderAccess(purpose)
                access = folderAccesses[purpose]
            } else {
                access = SecurityScopedResourceAccess(url: url)
            }
            if AppDistribution.current == .macAppStore, access?.isActive != true {
                throw FolderAccessAuthorizationError(purpose: purpose)
            }
            if !persistBookmark, let access {
                folderAccesses[purpose] = access
            }
            return true
        } catch {
            folderAccesses[purpose] = priorAccess
            showFolderAccessError { L10n.tr("Could not retain folder access: \(Self.errorMessage(for: error))") }
            setSettingsFeedbackFromStatus(role: .error)
            return false
        }
    }

    private func chooseAccessForSelectedSource() -> URL? {
        folderAccessFeedback = nil
        let sourcePath = sourceValidation.expandedPath
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let sourceName = sourceURL.lastPathComponent
        guard let selectedURL = FilePanelPresenter.chooseDirectoryURL(
            title: L10n.tr("Allow Access to \(sourceName)"),
            initialPath: sourcePath,
            prompt: L10n.tr("Allow Access"),
            message: L10n.tr("Choose the card or source folder before \(AppDistribution.current.displayName) scans it.")
        ) else {
            statusMessage = L10n.tr("Card scan cancelled")
            return nil
        }
        guard Self.isSameOrDescendant(selectedURL, of: sourceURL) else {
            showFolderAccessError { L10n.tr("Choose \(sourceName) or one of its subfolders.") }
            return nil
        }
        return selectedURL
    }

    private func hasActiveFolderAccess(
        covering path: String, additionalAccess: [SecurityScopedResourceAccess] = []
    ) -> Bool {
        let requestedURL = URL(fileURLWithPath: expanded(path), isDirectory: true)
        return (Array(folderAccesses.values) + additionalAccess).contains { access in
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
        let candidateComponents = candidate.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return candidateComponents.starts(with: rootComponents)
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
                self.refreshAvailableSourceVolumes(including: volume)
                guard Self.currentPromptVolume(matching: volume) != nil else { return .accepted }
                let canPresent = BackgroundPromptDeliveryPolicy.canCommitPrompt(
                    desiredEnabled: self.autoPromptEnabled,
                    hasCompletedOnboarding: self.hasCompletedOnboarding,
                    isWorking: self.isWorking || self.isEjectingSource,
                    hasPendingPrompt: self.pendingMountPrompt != nil
                )
                switch self.mountPrompts.receive(volume, among: self.availableSourceVolumes, canPresent: canPresent) {
                case .alreadyPresented, .stale:
                    return .accepted
                case .deferred:
                    return .deferred
                case .present:
                    self.statusMessage = L10n.tr("Card detected")
                    MainWindowPresenter.present()
                    self.refreshBackgroundPromptHealth()
                    return .accepted
                }
            },
            volumeMountedHandler: { [weak self] volume in
                self?.refreshAvailableSourceVolumes(including: volume)
            },
            volumeUnmountedHandler: { [weak self] url in
                self?.invalidateScansAtUnmount(url)
            },
            unmountHandler: { [weak self] url in
                self?.refreshAvailableSourceVolumes(excluding: url)
            },
            shouldHandleDirectMount: { [weak self] in
                guard let self else {
                    return false
                }
                return BackgroundPromptDeliveryPolicy.canObserveDirectMount(
                    desiredEnabled: self.autoPromptEnabled,
                    hasCompletedOnboarding: self.hasCompletedOnboarding,
                    isAuthoritativeApplication: self.loginItem.applicationOwnership
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
                        isAuthoritativeApplication: self.loginItem.applicationOwnership
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

    func invalidateScansAtUnmount(_ url: URL) {
        let path = url.standardizedFileURL.path
        if activeCopySources?.noteUnmount(at: path) == true {
            importAttempt?.requestCancellation()
            importTask?.cancel()
            selection = .import
        }
        if let singleScanMount, singleScanMount.volume.mountPath == path {
            jobsRequiringRescan.insert(singleScanMount.jobID)
            self.singleScanMount = nil
        }
        noteScanBothUnmount(at: path)
    }

    private func noteScanBothUnmount(at path: String) {
        // A remount can hide the unmount from a later volume lookup.
        if let jobID = scanBothSession?.noteUnmount(at: path) {
            jobsRequiringRescan.insert(jobID)
        }
        if let jobID = previousScanBothSession?.noteUnmount(at: path) {
            jobsRequiringRescan.insert(jobID)
        }
    }

    private static func importDisconnectedMessage(_ volume: String) -> String {
        L10n.tr("Import stopped because \(volume) disconnected.")
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
                self.pendingMountPrompt == nil,
                BackgroundPromptDeliveryPolicy.canObserveDirectMount(
                    desiredEnabled: self.autoPromptEnabled,
                    hasCompletedOnboarding: self.hasCompletedOnboarding,
                    isAuthoritativeApplication: self.loginItem.applicationOwnership
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
            try backgroundPromptStateStore().recordSuccessfulDelivery(
                agentBuild: event.agentBuild,
                agentBundlePath: expectedEmbeddedAgentPath,
                eventSequence: event.agentSequence
            )
            if BackgroundPromptHealth.shouldClearRuntimeAppError(
                errorSequence: backgroundPromptLastErrorSequence,
                successfulSequence: event.agentSequence
            ) {
                clearBackgroundPromptRuntimeError()
            }
            refreshBackgroundPromptHealth()
        } catch {
            recordBackgroundPromptError(L10n.tr("Could not update background helper diagnostics"))
        }
    }

    private func currentlyOwnsBackgroundPromptRegistration() -> Bool {
        let ownership = loginItem.applicationOwnership
        guard
            autoPromptEnabled,
            ownership.isCurrentApplicationAuthoritative,
            let state = try? backgroundPromptStateStore().load()
        else {
            return false
        }
        return BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
            identity: currentRepairIdentity,
            serviceStatus: loginItem.status,
            liveAgentState: state,
            minimumLaunchAt: backgroundPrompt.minimumLaunchAt
        )
    }

    nonisolated private static func importStatusMessage(for progress: ImportProgress) -> String {
        switch progress.status {
        case "completed":
            return L10n.tr("Import finished")
        case "completed_with_errors":
            return L10n.tr("Import finished with errors")
        case "idle":
            return L10n.tr("Nothing to import")
        default:
            let percent = Int(progress.percent.rounded())
            if progress.throughputBytesPerSecond > 1 {
                let speed = L10n.fileSize(Int64(progress.throughputBytesPerSecond))
                return L10n.tr("Importing \(percent)% at \(speed)/s")
            }
            if progress.totalFiles == 1 {
                return L10n.tr("Importing \(progress.doneFiles) of 1 file")
            }
            return L10n.tr("Importing \(progress.doneFiles) of \(progress.totalFiles) files")
        }
    }

    private func rememberEjectionDestinations(_ paths: Set<String>?, for jobID: String) {
        if scanBothSession?.entry(for: jobID) != nil {
            scanBothSession?.recordImportDestinations(paths, for: jobID)
        } else if let prior = copyEjectionDestinations, prior.jobID == jobID {
            copyEjectionDestinations = (jobID, paths.flatMap { prior.paths?.union($0) })
        } else {
            copyEjectionDestinations = (jobID, paths)
        }
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
        let paths: Set<String>?
        if let session = scanBothSession, session.entry(for: job.id) != nil {
            paths = session.confirmedDestinationPaths
        } else {
            guard copyEjectionDestinations?.jobID == job.id else { return nil }
            paths = copyEjectionDestinations?.paths
        }
        guard let paths else { return nil }
        return sourceEjectionTarget(
            sourceVolume: volume,
            destinationPaths: paths,
            mountedVolumes: mountedVolumes
        )
    }

    private func sourceEjectionTarget(
        sourceVolume: MountedVolume,
        destinationPaths: Set<String>,
        mountedVolumes: [MountedVolume]
    ) -> SourceEjectionTarget? {
        let grouper = MountedDeviceGrouper()
        let group = grouper.group(containing: sourceVolume, among: mountedVolumes)
        let ejectionVolumes = grouper.ejectionVolumes(for: sourceVolume, among: mountedVolumes)
        guard
            !ejectionVolumes.isEmpty,
            ejectionVolumes.allSatisfy({ $0.volumeUUID?.isEmpty == false }),
            destinationPaths.allSatisfy({
                Self.canEject(group.volumes, withDestinationVolumeAt: $0)
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

    nonisolated static func canEject(
        _ sourceVolumes: [MountedVolume],
        withDestinationVolumeAt path: String
    ) -> Bool {
        let destinationURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        // Earlier destination permissions may have ended with that volume's review.
        if sourceVolumes.contains(where: { destinationURL.path == $0.mountPath }) {
            return false
        }
        guard let destinationVolume = VolumeDetector().currentMountedVolume(
            from: destinationURL, includeCapacity: false
        ) else { return false }
        return !sourceVolumes.contains { sourceVolume in
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
                    let mount = URL(fileURLWithPath: volume.mountURL.path, isDirectory: true)
                    let currentRoot = try mount.resourceValues(forKeys: [.volumeURLKey]).volume
                    guard currentRoot?.standardizedFileURL.path == mount.standardizedFileURL.path else {
                        continue
                    }
                    let current = VolumeDetector().mountedVolume(from: mount, includeCapacity: false)
                    guard SourceEjectionPolicy().canEjectCurrentVolume(current, matching: volume) else {
                        throw SDImportError.invalidArgument(L10n.tr("Source cannot be ejected safely"))
                    }
                    try NSWorkspace.shared.unmountAndEjectDevice(at: mount)
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
            let required = L10n.fileSize(requiredBytes)
            let available = L10n.fileSize(availableBytes)
            return L10n.tr("Not enough space in \(path). Need \(required), available \(available).")
        }

        return L10n.errorMessage(for: error)
    }
}

private struct CopyVolumeUnavailable: Error {
    let volume: MountedVolume
}

private struct FolderAccessAuthorizationError: LocalizedError {
    let purpose: BookmarkPurpose

    var errorDescription: String? {
        switch purpose {
        case .source:
            L10n.tr("Select the source folder in the macOS access panel.")
        case .photos:
            L10n.tr("Select the photo destination in the macOS access panel.")
        case .videos:
            L10n.tr("Select the video destination in the macOS access panel.")
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
            return L10n.tr("\(days) days")
        case .forever:
            return L10n.tr("Forever")
        }
    }
}
