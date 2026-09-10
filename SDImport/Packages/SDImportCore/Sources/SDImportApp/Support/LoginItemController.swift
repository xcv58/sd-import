import AppKit
import Foundation
import SDImportCore
import ServiceManagement

@MainActor
enum LoginItemController {
    static var identifier: String {
        AppDistribution.current == .macAppStore
            ? AppDistribution.appStoreAgentBundleIdentifier
            : "com.xcv58.SDImport.Agent"
    }

    private static var cachedApplicationOwnership: BackgroundPromptApplicationOwnership?

    static var status: BackgroundPromptServiceStatus {
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

    static var embeddedAgentExists: Bool {
        FileManager.default.fileExists(atPath: embeddedAgentURL.path)
    }

    static var applicationOwnership: BackgroundPromptApplicationOwnership {
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

    static func invalidateApplicationOwnershipCache() {
        cachedApplicationOwnership = nil
    }

    static func setEnabled(_ enabled: Bool) async throws {
        try requireAuthoritativeApplication()
        if enabled {
            switch status {
            case .notRegistered:
                try service.register()
            case .notFound:
                guard embeddedAgentExists else {
                    throw LoginItemControllerError.missingEmbeddedHelper
                }
                try service.register()
            case .enabled, .requiresApproval, .unknown:
                break
            }
        } else {
            if status == .enabled || status == .requiresApproval {
                try await unregisterAndWait()
            }
        }
    }

    @discardableResult
    static func reconcile(
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
            try service.register()
        case .unregister:
            try await unregisterAndWait()
        case .none, .requestApproval, .reportMissingHelper:
            break
        }
        return status
    }

    @discardableResult
    @MainActor
    static func repair(
        shouldRegister: @escaping @MainActor () -> Bool = { true }
    ) async throws -> BackgroundPromptServiceStatus {
        try requireAuthoritativeApplication()
        guard embeddedAgentExists else {
            throw LoginItemControllerError.missingEmbeddedHelper
        }

        let operations = BackgroundPromptRepairSequence.operations(for: status)
        for operation in operations {
            switch operation {
            case .unregister:
                try await unregisterAndWait()
            case .register:
                guard shouldRegister(), status != .enabled else {
                    continue
                }
                try requireAuthoritativeApplication()
                try service.register()
            }
        }
        return status
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func openAuthoritativeApplication() {
        guard let path = applicationOwnership.authoritativeApplicationPath else {
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

    private static func requireAuthoritativeApplication() throws {
        let ownership = applicationOwnership
        guard ownership.isCurrentApplicationAuthoritative else {
            if ownership.authoritativeApplicationPath == nil {
                throw LoginItemControllerError.installationRequired
            }
            throw LoginItemControllerError.managedByAnotherCopy
        }
    }

    private static func unregisterAndWait() async throws {
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
            return "The background helper is missing. Reinstall \(AppDistribution.current.displayName) in Applications."
        case .installationRequired:
            return "Move \(AppDistribution.current.displayName) to Applications before enabling background prompts."
        case .managedByAnotherCopy:
            return "Background prompts are managed by the installed copy of \(AppDistribution.current.displayName)."
        }
    }
}
