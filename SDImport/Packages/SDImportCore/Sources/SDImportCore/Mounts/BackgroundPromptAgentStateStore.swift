import Darwin
import Foundation

public struct BackgroundPromptAgentState: Codable, Equatable, Sendable {
    public let agentBuild: String
    public let agentBundlePath: String?
    public let launchedAt: Date
    public let launchedAtEpoch: TimeInterval?
    public let lastHandoffAt: Date?
    public let lastError: String?
    public let lastIssuedSequence: UInt64
    public let lastErrorSequence: UInt64?
    public let lastSuccessfulSequence: UInt64?

    public init(
        agentBuild: String,
        agentBundlePath: String? = nil,
        launchedAt: Date,
        launchedAtEpoch: TimeInterval? = nil,
        lastHandoffAt: Date? = nil,
        lastError: String? = nil,
        lastIssuedSequence: UInt64 = 0,
        lastErrorSequence: UInt64? = nil,
        lastSuccessfulSequence: UInt64? = nil
    ) {
        self.agentBuild = agentBuild
        self.agentBundlePath = agentBundlePath
        self.launchedAt = launchedAt
        self.launchedAtEpoch = launchedAtEpoch
        self.lastHandoffAt = lastHandoffAt
        self.lastError = lastError
        self.lastIssuedSequence = lastIssuedSequence
        self.lastErrorSequence = lastErrorSequence
        self.lastSuccessfulSequence = lastSuccessfulSequence
    }

    private enum CodingKeys: String, CodingKey {
        case agentBuild
        case agentBundlePath
        case launchedAt
        case launchedAtEpoch
        case lastHandoffAt
        case lastError
        case lastIssuedSequence
        case lastErrorSequence
        case lastSuccessfulSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentBuild = try container.decode(String.self, forKey: .agentBuild)
        agentBundlePath = try container.decodeIfPresent(String.self, forKey: .agentBundlePath)
        launchedAt = try container.decode(Date.self, forKey: .launchedAt)
        launchedAtEpoch = try container.decodeIfPresent(TimeInterval.self, forKey: .launchedAtEpoch)
        lastHandoffAt = try container.decodeIfPresent(Date.self, forKey: .lastHandoffAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastIssuedSequence = try container.decodeIfPresent(UInt64.self, forKey: .lastIssuedSequence) ?? 0
        lastErrorSequence = try container.decodeIfPresent(UInt64.self, forKey: .lastErrorSequence)
        lastSuccessfulSequence = try container.decodeIfPresent(UInt64.self, forKey: .lastSuccessfulSequence)
    }
}

public struct BackgroundPromptAgentAuthorization: Codable, Equatable, Sendable {
    public let agentBuild: String
    public let agentBundlePath: String
    public let authorizedAt: Date

    public init(agentBuild: String, agentBundlePath: String, authorizedAt: Date = Date()) {
        self.agentBuild = agentBuild
        self.agentBundlePath = agentBundlePath
        self.authorizedAt = authorizedAt
    }
}

public struct BackgroundPromptAgentStateStore {
    public enum StoreError: Error, Equatable {
        case staleAgentIdentity
        case sequenceExhausted
    }

    public let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultStore(fileManager: FileManager = .default) throws -> Self {
        let supportURL = try AppGroupContainer.sharedSupportDirectory(fileManager: fileManager)
        return Self(
            fileURL: supportURL
                .appendingPathComponent("Background Prompt", isDirectory: true)
                .appendingPathComponent("agent-state.json", isDirectory: false),
            fileManager: fileManager
        )
    }

    public func load() throws -> BackgroundPromptAgentState? {
        try loadUnlocked()
    }

    public func authorize(
        agentBuild: String,
        agentBundlePath: String,
        now: Date = Date()
    ) throws {
        try withExclusiveLock {
            let authorization = BackgroundPromptAgentAuthorization(
                agentBuild: agentBuild,
                agentBundlePath: agentBundlePath,
                authorizedAt: now
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(authorization).write(to: authorizationURL, options: [.atomic])
        }
    }

    public func loadAuthorization() throws -> BackgroundPromptAgentAuthorization? {
        try loadAuthorizationUnlocked()
    }

    public func isAuthorized(agentBuild: String, agentBundlePath: String) throws -> Bool {
        guard let authorization = try loadAuthorizationUnlocked() else {
            return true
        }
        return authorization.agentBuild == agentBuild
            && authorization.agentBundlePath == agentBundlePath
    }

    @discardableResult
    public func issueEventSequence(
        agentBuild: String,
        agentBundlePath: String,
        now: Date = Date()
    ) throws -> UInt64 {
        try withExclusiveLock {
            guard try isAuthorized(agentBuild: agentBuild, agentBundlePath: agentBundlePath) else {
                throw StoreError.staleAgentIdentity
            }
            let existing = try? loadUnlocked()
            if let existing, !matches(existing, agentBuild: agentBuild, agentBundlePath: agentBundlePath) {
                throw StoreError.staleAgentIdentity
            }
            let nextSequence = try Self.nextSequence(after: existing?.lastIssuedSequence ?? 0)
            let sameAgent = existing?.agentBuild == agentBuild
                && existing?.agentBundlePath == agentBundlePath
            try saveUnlocked(
                BackgroundPromptAgentState(
                    agentBuild: agentBuild,
                    agentBundlePath: agentBundlePath,
                    launchedAt: sameAgent ? existing?.launchedAt ?? now : now,
                    launchedAtEpoch: sameAgent ? existing?.launchedAtEpoch : nil,
                    lastHandoffAt: sameAgent ? existing?.lastHandoffAt : nil,
                    lastError: sameAgent ? existing?.lastError : nil,
                    lastIssuedSequence: nextSequence,
                    lastErrorSequence: sameAgent ? existing?.lastErrorSequence : nil,
                    lastSuccessfulSequence: sameAgent ? existing?.lastSuccessfulSequence : nil
                )
            )
            return nextSequence
        }
    }

    /// Reserves a causal barrier for an app-side diagnostic that is not tied to
    /// one particular helper handoff. Future helper events receive a newer value.
    @discardableResult
    public func reserveDiagnosticSequence(
        agentBuild: String,
        agentBundlePath: String,
        now: Date = Date()
    ) throws -> UInt64 {
        try issueEventSequence(
            agentBuild: agentBuild,
            agentBundlePath: agentBundlePath,
            now: now
        )
    }

    private func loadUnlocked() throws -> BackgroundPromptAgentState? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackgroundPromptAgentState.self, from: Data(contentsOf: fileURL))
    }

    public func recordLaunch(
        agentBuild: String,
        agentBundlePath: String,
        now: Date = Date()
    ) throws {
        try withExclusiveLock {
            guard try isAuthorized(agentBuild: agentBuild, agentBundlePath: agentBundlePath) else {
                throw StoreError.staleAgentIdentity
            }
            let existing = try? loadUnlocked()
            let sameAgent = existing?.agentBuild == agentBuild
                && existing?.agentBundlePath == agentBundlePath
            try saveUnlocked(
                BackgroundPromptAgentState(
                    agentBuild: agentBuild,
                    agentBundlePath: agentBundlePath,
                    launchedAt: now,
                    launchedAtEpoch: now.timeIntervalSince1970,
                    lastHandoffAt: sameAgent ? existing?.lastHandoffAt : nil,
                    lastError: sameAgent ? existing?.lastError : nil,
                    lastIssuedSequence: existing?.lastIssuedSequence ?? 0,
                    lastErrorSequence: sameAgent ? existing?.lastErrorSequence : nil,
                    lastSuccessfulSequence: sameAgent ? existing?.lastSuccessfulSequence : nil
                )
            )
        }
    }

    public func recordHandoff(
        agentBuild: String,
        agentBundlePath: String,
        eventSequence: UInt64,
        now: Date = Date()
    ) throws {
        try withExclusiveLock {
            guard try isAuthorized(agentBuild: agentBuild, agentBundlePath: agentBundlePath) else {
                return
            }
            let existing = try? loadUnlocked()
            if let existing, !matches(existing, agentBuild: agentBuild, agentBundlePath: agentBundlePath) {
                return
            }
            let sameAgent = existing?.agentBuild == agentBuild
                && existing?.agentBundlePath == agentBundlePath
            try saveUnlocked(
                BackgroundPromptAgentState(
                    agentBuild: agentBuild,
                    agentBundlePath: agentBundlePath,
                    launchedAt: sameAgent ? existing?.launchedAt ?? now : now,
                    launchedAtEpoch: sameAgent ? existing?.launchedAtEpoch : nil,
                    lastHandoffAt: now,
                    lastError: sameAgent ? existing?.lastError : nil,
                    lastIssuedSequence: max(existing?.lastIssuedSequence ?? 0, eventSequence),
                    lastErrorSequence: sameAgent ? existing?.lastErrorSequence : nil,
                    lastSuccessfulSequence: sameAgent ? existing?.lastSuccessfulSequence : nil
                )
            )
        }
    }

    public func recordSuccessfulDelivery(
        agentBuild: String,
        agentBundlePath: String,
        eventSequence: UInt64
    ) throws {
        try withExclusiveLock {
            guard try isAuthorized(agentBuild: agentBuild, agentBundlePath: agentBundlePath) else {
                return
            }
            guard
                let existing = try loadUnlocked(),
                existing.agentBuild == agentBuild,
                existing.agentBundlePath == agentBundlePath
            else {
                return
            }
            let shouldClearError = existing.lastErrorSequence.map { eventSequence >= $0 } ?? true
            try saveUnlocked(
                BackgroundPromptAgentState(
                    agentBuild: existing.agentBuild,
                    agentBundlePath: existing.agentBundlePath,
                    launchedAt: existing.launchedAt,
                    launchedAtEpoch: existing.launchedAtEpoch,
                    lastHandoffAt: existing.lastHandoffAt,
                    lastError: shouldClearError ? nil : existing.lastError,
                    lastIssuedSequence: max(existing.lastIssuedSequence, eventSequence),
                    lastErrorSequence: shouldClearError ? nil : existing.lastErrorSequence,
                    lastSuccessfulSequence: max(existing.lastSuccessfulSequence ?? 0, eventSequence)
                )
            )
        }
    }

    public func recordError(
        agentBuild: String,
        agentBundlePath: String,
        message: String,
        eventSequence: UInt64? = nil,
        now: Date = Date()
    ) throws {
        try withExclusiveLock {
            guard try isAuthorized(agentBuild: agentBuild, agentBundlePath: agentBundlePath) else {
                return
            }
            let existing = try? loadUnlocked()
            if let existing, !matches(existing, agentBuild: agentBuild, agentBundlePath: agentBundlePath) {
                return
            }
            let sameAgent = existing?.agentBuild == agentBuild
                && existing?.agentBundlePath == agentBundlePath
            let sequence: UInt64
            if let eventSequence {
                sequence = eventSequence
            } else {
                sequence = try Self.nextSequence(after: existing?.lastIssuedSequence ?? 0)
            }
            if
                eventSequence != nil,
                let lastSuccessfulSequence = existing?.lastSuccessfulSequence,
                sequence <= lastSuccessfulSequence
            {
                return
            }
            if
                eventSequence != nil,
                let lastErrorSequence = existing?.lastErrorSequence,
                sequence < lastErrorSequence
            {
                return
            }
            try saveUnlocked(
                BackgroundPromptAgentState(
                    agentBuild: agentBuild,
                    agentBundlePath: agentBundlePath,
                    launchedAt: sameAgent ? existing?.launchedAt ?? now : now,
                    launchedAtEpoch: sameAgent ? existing?.launchedAtEpoch : nil,
                    lastHandoffAt: sameAgent ? existing?.lastHandoffAt : nil,
                    lastError: message,
                    lastIssuedSequence: max(existing?.lastIssuedSequence ?? 0, sequence),
                    lastErrorSequence: sequence,
                    lastSuccessfulSequence: sameAgent ? existing?.lastSuccessfulSequence : nil
                )
            )
        }
    }

    private func saveUnlocked(_ state: BackgroundPromptAgentState) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: [.atomic])
    }

    private static func nextSequence(after value: UInt64) throws -> UInt64 {
        guard value < UInt64.max else {
            throw StoreError.sequenceExhausted
        }
        return value + 1
    }

    private var authorizationURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("authorized-agent.json", isDirectory: false)
    }

    private func loadAuthorizationUnlocked() throws -> BackgroundPromptAgentAuthorization? {
        guard fileManager.fileExists(atPath: authorizationURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            BackgroundPromptAgentAuthorization.self,
            from: Data(contentsOf: authorizationURL)
        )
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try operation()
    }

    private func matches(
        _ state: BackgroundPromptAgentState,
        agentBuild: String,
        agentBundlePath: String
    ) -> Bool {
        state.agentBuild == agentBuild && state.agentBundlePath == agentBundlePath
    }
}
