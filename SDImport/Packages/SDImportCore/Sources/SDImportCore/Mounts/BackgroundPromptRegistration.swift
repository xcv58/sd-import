import Foundation

public enum BackgroundPromptServiceStatus: String, Codable, CaseIterable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

public enum BackgroundPromptReconciliationAction: Equatable, Sendable {
    case none
    case register
    case unregister
    case requestApproval
    case reportMissingHelper
}

public struct BackgroundPromptRepairIdentity: Codable, Equatable, Sendable {
    public let appBuild: String
    public let applicationPath: String
    public let agentBundlePath: String

    public init(appBuild: String, applicationPath: String, agentBundlePath: String) {
        self.appBuild = appBuild
        self.applicationPath = Self.normalizedPath(applicationPath)
        self.agentBundlePath = Self.normalizedPath(agentBundlePath)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

public struct BackgroundPromptApplicationOwnership: Equatable, Sendable {
    public let currentApplicationPath: String
    public let authoritativeApplicationPath: String?

    public init(currentApplicationPath: String, authoritativeApplicationPath: String?) {
        self.currentApplicationPath = Self.normalizedPath(currentApplicationPath)
        self.authoritativeApplicationPath = authoritativeApplicationPath.map(Self.normalizedPath)
    }

    public var isCurrentApplicationAuthoritative: Bool {
        currentApplicationPath == authoritativeApplicationPath
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

public enum BackgroundPromptApplicationOwnershipPolicy {
    public static func ownership(
        currentApplicationPath: String,
        candidateApplicationPaths: [String],
        systemApplicationsPath: String = "/Applications",
        userApplicationsPath: String
    ) -> BackgroundPromptApplicationOwnership {
        let currentPath = normalizedPath(currentApplicationPath)
        let systemPath = normalizedPath(systemApplicationsPath)
        let userPath = normalizedPath(userApplicationsPath)
        let candidates = Set(candidateApplicationPaths.map(normalizedPath) + [currentPath])
        let installedCandidates = candidates.filter {
            isDescendant($0, of: systemPath) || isDescendant($0, of: userPath)
        }
        let authoritativePath = installedCandidates.sorted {
            rank($0, systemRoot: systemPath, userRoot: userPath)
                < rank($1, systemRoot: systemPath, userRoot: userPath)
        }.first
        return BackgroundPromptApplicationOwnership(
            currentApplicationPath: currentPath,
            authoritativeApplicationPath: authoritativePath
        )
    }

    public static func ownsRegistration(
        identity: BackgroundPromptRepairIdentity,
        serviceStatus: BackgroundPromptServiceStatus,
        liveAgentState: BackgroundPromptAgentState?,
        minimumLaunchAt: Date? = nil
    ) -> Bool {
        guard serviceStatus == .enabled, let liveAgentState else {
            return false
        }
        if let minimumLaunchAt {
            guard let launchedAtEpoch = liveAgentState.launchedAtEpoch,
                  launchedAtEpoch >= minimumLaunchAt.timeIntervalSince1970 else {
                return false
            }
        }
        let liveIdentity = BackgroundPromptRepairIdentity(
            appBuild: liveAgentState.agentBuild,
            applicationPath: identity.applicationPath,
            agentBundlePath: liveAgentState.agentBundlePath ?? ""
        )
        let buildsMatch = liveIdentity.appBuild == "dev"
            || identity.appBuild == "dev"
            || liveIdentity.appBuild == identity.appBuild
        return buildsMatch && liveIdentity.agentBundlePath == identity.agentBundlePath
    }

    private static func rank(
        _ path: String,
        systemRoot: String,
        userRoot: String
    ) -> (Int, Int, String) {
        let rootRank = isDescendant(path, of: systemRoot) ? 0 : 1
        let nameRank = URL(fileURLWithPath: path).lastPathComponent == "SD Import.app" ? 0 : 1
        return (rootRank, nameRank, path.lowercased())
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        path.range(of: root + "/", options: [.anchored, .caseInsensitive]) != nil
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

public enum BackgroundPromptRegistrationPolicy {
    public static let notFoundRepairRetryInterval: TimeInterval = 5 * 60

    public static func allowsNotFoundRegistration(
        lastAttemptAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let lastAttemptAt else {
            return true
        }
        return now.timeIntervalSince(lastAttemptAt) >= notFoundRepairRetryInterval
    }

    public static func shouldAttemptMissingRegistration(
        desiredEnabled: Bool,
        serviceStatus: BackgroundPromptServiceStatus,
        lastAttemptAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard desiredEnabled,
              serviceStatus == .notFound || serviceStatus == .notRegistered else {
            return false
        }
        return allowsNotFoundRegistration(lastAttemptAt: lastAttemptAt, now: now)
    }

    public static func action(
        desiredEnabled: Bool,
        serviceStatus: BackgroundPromptServiceStatus,
        embeddedHelperExists: Bool = true,
        allowNotFoundRegistration: Bool = true
    ) -> BackgroundPromptReconciliationAction {
        if desiredEnabled {
            switch serviceStatus {
            case .notRegistered:
                return .register
            case .enabled:
                return .none
            case .requiresApproval:
                return .requestApproval
            case .notFound:
                guard embeddedHelperExists else {
                    return .reportMissingHelper
                }
                return allowNotFoundRegistration ? .register : .none
            case .unknown:
                return .none
            }
        }

        switch serviceStatus {
        case .enabled, .requiresApproval:
            return .unregister
        case .notRegistered, .notFound, .unknown:
            return .none
        }
    }

    public static func agentMismatch(
        state: BackgroundPromptAgentState?,
        expectedIdentity: BackgroundPromptRepairIdentity,
        lastRepairIdentity: BackgroundPromptRepairIdentity?
    ) -> Bool {
        guard let state else {
            return lastRepairIdentity != expectedIdentity
        }
        if
            state.agentBuild != "dev",
            expectedIdentity.appBuild != "dev",
            state.agentBuild != expectedIdentity.appBuild
        {
            return true
        }
        guard let agentBundlePath = state.agentBundlePath else {
            return true
        }
        return BackgroundPromptRepairIdentity(
            appBuild: state.agentBuild,
            applicationPath: expectedIdentity.applicationPath,
            agentBundlePath: agentBundlePath
        ).agentBundlePath != expectedIdentity.agentBundlePath
    }

    public static func shouldRefreshHelper(
        desiredEnabled: Bool,
        serviceStatus: BackgroundPromptServiceStatus,
        embeddedHelperExists: Bool = true,
        state: BackgroundPromptAgentState?,
        expectedIdentity: BackgroundPromptRepairIdentity,
        lastRepairIdentity: BackgroundPromptRepairIdentity?,
        lastNotFoundRepairAttemptAt: Date? = nil,
        now: Date = Date()
    ) -> Bool {
        guard
            desiredEnabled,
            embeddedHelperExists
        else {
            return false
        }
        if serviceStatus == .notFound {
            return allowsNotFoundRegistration(
                lastAttemptAt: lastNotFoundRepairAttemptAt,
                now: now
            )
        }
        guard lastRepairIdentity != expectedIdentity else {
            return false
        }
        return serviceStatus == .enabled
            && agentMismatch(
                state: state,
                expectedIdentity: expectedIdentity,
                lastRepairIdentity: lastRepairIdentity
            )
    }
}

public enum BackgroundPromptDeliveryPolicy {
    public static func canObserveDirectMount(
        desiredEnabled: Bool,
        hasCompletedOnboarding: Bool,
        isAuthoritativeApplication: Bool
    ) -> Bool {
        desiredEnabled && hasCompletedOnboarding && isAuthoritativeApplication
    }

    public static func canCommitPrompt(
        desiredEnabled: Bool,
        hasCompletedOnboarding: Bool,
        isWorking: Bool,
        hasPendingPrompt: Bool
    ) -> Bool {
        desiredEnabled && hasCompletedOnboarding && !isWorking && !hasPendingPrompt
    }
}

public enum BackgroundPromptRepairOperation: Equatable, Sendable {
    case unregister
    case register
}

public enum BackgroundPromptRepairSequence {
    public static func operations(
        for status: BackgroundPromptServiceStatus
    ) -> [BackgroundPromptRepairOperation] {
        switch status {
        case .enabled, .requiresApproval:
            return [.unregister, .register]
        case .notRegistered, .notFound, .unknown:
            return [.register]
        }
    }

    public static func execute(
        _ operations: [BackgroundPromptRepairOperation],
        isolation: isolated (any Actor)? = #isolation,
        now: () -> Date = Date.init,
        unregister: () async throws -> Void,
        register: (Date) throws -> Void
    ) async throws {
        for operation in operations {
            switch operation {
            case .unregister:
                try await unregister()
            case .register:
                // A launch during unregister still belongs to the outgoing helper.
                try register(now())
            }
        }
    }
}
