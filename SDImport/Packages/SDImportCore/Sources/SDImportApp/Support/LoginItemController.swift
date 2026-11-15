import AppKit
import Foundation
import SDImportCore
import ServiceManagement

@MainActor
struct LoginItemController {
    let readStatus: () -> BackgroundPromptServiceStatus
    let readApplicationOwnership: () -> BackgroundPromptApplicationOwnership
    let invalidateApplicationOwnershipCache: () -> Void
    let hasEmbeddedAgent: () -> Bool
    let register: () throws -> Void
    let unregister: () async throws -> Void

    var status: BackgroundPromptServiceStatus { readStatus() }
    var applicationOwnership: BackgroundPromptApplicationOwnership { readApplicationOwnership() }
    var embeddedAgentExists: Bool { hasEmbeddedAgent() }

    static let live = Self(
        readStatus: { liveServiceStatus },
        readApplicationOwnership: { liveApplicationOwnership },
        invalidateApplicationOwnershipCache: { cachedApplicationOwnership = nil },
        hasEmbeddedAgent: { FileManager.default.fileExists(atPath: embeddedAgentURL.path) },
        register: { try service.register() },
        unregister: unregisterServiceAndWait
    )

    static var identifier: String {
        AppDistribution.current == .macAppStore
            ? AppDistribution.appStoreAgentBundleIdentifier
            : "com.xcv58.SDImport.Agent"
    }

    private static var cachedApplicationOwnership: BackgroundPromptApplicationOwnership?

    private static var liveServiceStatus: BackgroundPromptServiceStatus {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    private static var liveApplicationOwnership: BackgroundPromptApplicationOwnership {
        if let cachedApplicationOwnership {
            return cachedApplicationOwnership
        }
        let ownership = BackgroundPromptApplicationOwnershipPolicy.ownership(
            currentApplicationPath: Bundle.main.bundleURL.path,
            candidateApplicationPaths: discoveredApplicationURLs.map(\.path),
            userApplicationsPath: userApplicationsURL.path
        )
        cachedApplicationOwnership = ownership
        return ownership
    }

    func setEnabled(_ enabled: Bool) async throws {
        try requireAuthoritativeApplication()
        if enabled {
            switch status {
            case .notRegistered:
                try register()
            case .notFound:
                guard embeddedAgentExists else {
                    throw LoginItemControllerError.missingEmbeddedHelper
                }
                try register()
            case .enabled, .requiresApproval, .unknown:
                break
            }
        } else {
            if status == .enabled || status == .requiresApproval {
                try await unregister()
            }
        }
    }

    @discardableResult
    func reconcile(
        desiredEnabled: Bool,
        allowNotFoundRegistration: Bool,
        didRegister: () -> Void
    ) async throws -> BackgroundPromptServiceStatus {
        try requireAuthoritativeApplication()
        let action = BackgroundPromptRegistrationPolicy.action(
            desiredEnabled: desiredEnabled,
            serviceStatus: status,
            embeddedHelperExists: embeddedAgentExists,
            allowNotFoundRegistration: allowNotFoundRegistration
        )
        switch action {
        case .register:
            guard embeddedAgentExists else {
                throw LoginItemControllerError.missingEmbeddedHelper
            }
            try register()
            didRegister()
        case .unregister:
            try await unregister()
        case .none, .requestApproval, .reportMissingHelper:
            break
        }
        return status
    }

    @discardableResult
    @MainActor
    func repair(
        didRegister: () -> Void = {},
        requireLaunchAfter: (Date) -> Void,
        shouldRegister: @escaping @MainActor () -> Bool = { true }
    ) async throws -> BackgroundPromptServiceStatus {
        try requireAuthoritativeApplication()
        guard embeddedAgentExists else {
            throw LoginItemControllerError.missingEmbeddedHelper
        }

        try await BackgroundPromptRepairSequence.execute(
            BackgroundPromptRepairSequence.operations(for: status),
            unregister: unregister,
            register: { registrationStartedAt in
                guard shouldRegister() else { return }
                try requireAuthoritativeApplication()
                // Registration may already have been restored by another caller.
                // The previous launch record still predates this repair.
                requireLaunchAfter(registrationStartedAt)
                if status != .enabled {
                    try register()
                    didRegister()
                }
            }
        )
        return status
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func openAuthoritativeApplication() {
        guard let path = liveApplicationOwnership.authoritativeApplicationPath else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path, isDirectory: true),
            configuration: configuration
        ) { _, _ in }
    }

    private static var service: SMAppService {
        SMAppService.loginItem(identifier: identifier)
    }

    private static var embeddedAgentURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent("SDImportAgent.app", isDirectory: true)
    }

    private static var userApplicationsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    private static var discoveredApplicationURLs: [URL] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return [Bundle.main.bundleURL]
        }
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            userApplicationsURL
        ]
        var applications = [Bundle.main.bundleURL]
        if let registeredURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            applications.append(registeredURL)
        }

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let candidate as URL in enumerator where candidate.pathExtension == "app" {
                if Bundle(url: candidate)?.bundleIdentifier == bundleIdentifier {
                    applications.append(candidate)
                }
            }
        }
        return applications
    }

    private func requireAuthoritativeApplication() throws {
        let ownership = applicationOwnership
        guard ownership.isCurrentApplicationAuthoritative else {
            if ownership.authoritativeApplicationPath == nil {
                throw LoginItemControllerError.installationRequired
            }
            throw LoginItemControllerError.managedByAnotherCopy
        }
    }

    private static func unregisterServiceAndWait() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            service.unregister(completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

private enum LoginItemControllerError: LocalizedError {
    case missingEmbeddedHelper
    case installationRequired
    case managedByAnotherCopy

    var errorDescription: String? {
        switch self {
        case .missingEmbeddedHelper:
            return L10n.tr("The background helper is missing. Reinstall \(AppDistribution.current.displayName) in Applications.")
        case .installationRequired:
            return L10n.tr("Move \(AppDistribution.current.displayName) to Applications before enabling background prompts.")
        case .managedByAnotherCopy:
            return L10n.tr("Background prompts are managed by the installed copy of \(AppDistribution.current.displayName).")
        }
    }
}

@MainActor
final class BackgroundPromptCoordinator {
    private enum RegistrationPhase: Equatable {
        case registering(UUID)
        case waitingForLaunch(UUID)
    }

    private enum Keys {
        static let minimumLaunch = "SDImport.minimumBackgroundPromptAgentLaunchAt"
        static let lastRegistration = "SDImport.lastNotFoundRepairAttemptAt"
        static let lastHealthRepair = "SDImport.lastHealthRepairAttemptAt"
    }

    let now: () -> Date
    private let defaults: UserDefaults
    private let sleep: BackgroundPromptRetryScheduler.Sleep
    private let retries: BackgroundPromptRetryScheduler
    private var manualRepairID: UUID?
    private var registration: RegistrationPhase?
    private var pollID: UUID?
    private var pollTask: Task<Void, Never>?
    private(set) var operationTask: Task<Void, Never>?

    init(
        defaults: UserDefaults, sleep: @escaping BackgroundPromptRetryScheduler.Sleep, now: @escaping () -> Date
    ) {
        self.defaults = defaults
        self.sleep = sleep
        self.now = now
        retries = BackgroundPromptRetryScheduler(sleep: sleep)
    }

    var isRepairingManually: Bool { manualRepairID != nil }
    var isPolling: Bool { pollTask != nil }
    var minimumLaunchAt: Date? { storedDate(Keys.minimumLaunch) }
    var lastRegistrationAttemptAt: Date? { storedDate(Keys.lastRegistration) }
    var healthRetryDelay: TimeInterval {
        BackgroundPromptRetryPolicy.remainingDelay(lastAttemptAt: storedDate(Keys.lastHealthRepair), now: now())
    }

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let preceding = operationTask
        operationTask = Task {
            _ = await preceding?.value
            await operation()
        }
    }

    func beginManualRepair() -> UUID {
        let id = UUID()
        manualRepairID = id
        return id
    }

    func finishManualRepair(_ id: UUID) {
        if manualRepairID == id { manualRepairID = nil }
    }

    func beginRegistration() -> UUID {
        let id = UUID()
        registration = .registering(id)
        return id
    }

    func isCurrentRegistration(_ id: UUID) -> Bool {
        registration == .registering(id) || registration == .waitingForLaunch(id)
    }

    func finishRegistration(_ id: UUID) {
        if isCurrentRegistration(id) { registration = nil }
    }

    func requireLaunch(after date: Date, registrationID: UUID? = nil) {
        if let id = registrationID {
            guard isCurrentRegistration(id) else { return }
            registration = .waitingForLaunch(id)
        }
        defaults.set(date.timeIntervalSince1970, forKey: Keys.minimumLaunch)
    }

    func recordRegistrationAttempt() {
        defaults.set(now().timeIntervalSince1970, forKey: Keys.lastRegistration)
    }

    func clearRegistrationAttempt() { defaults.removeObject(forKey: Keys.lastRegistration) }

    func recordHealthRepair() {
        defaults.set(now().timeIntervalSince1970, forKey: Keys.lastHealthRepair)
    }

    func scheduleRetry(after delay: TimeInterval, _ operation: @escaping @MainActor @Sendable () async -> Void) {
        retries.schedule(after: delay, operation: operation)
    }

    func cancelRetry(resetAttempts: Bool) {
        retries.cancel()
        if resetAttempts {
            clearRegistrationAttempt()
            defaults.removeObject(forKey: Keys.lastHealthRepair)
        }
    }

    func pollForLaunch(
        whileWaiting: @escaping @MainActor () -> Bool,
        timedOut: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        cancelPoll()
        let id = UUID()
        pollID = id
        let sleep = self.sleep
        let task = Task { [weak self] in
            defer { self?.finishPoll(id) }
            for milliseconds in BackgroundPromptHealth.refreshDelayMilliseconds {
                do {
                    try await sleep(.milliseconds(milliseconds))
                } catch {
                    return
                }
                guard self?.pollID == id, whileWaiting(), self?.pollID == id else { return }
            }
            timedOut()
        }
        pollTask = task
        return task
    }

    func cancelPoll() {
        pollTask?.cancel()
        pollID = nil
        pollTask = nil
    }

    private func finishPoll(_ id: UUID) {
        guard pollID == id else { return }
        pollID = nil
        pollTask = nil
    }

    private func storedDate(_ key: String) -> Date? {
        let value = defaults.double(forKey: key)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}
