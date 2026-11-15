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
        allowNotFoundRegistration: Bool
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
