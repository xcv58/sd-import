import Foundation

public enum BackgroundPromptHealth {
    public static let refreshDelayMilliseconds: [Int64] = [500, 1_000, 2_000, 4_000, 8_000]
    public static let missingLaunchError =
        L10n.tr("The background helper is registered but has not reported a successful launch.")

    public static func effectiveError(
        appError: String?,
        agentState: BackgroundPromptAgentState?
    ) -> String? {
        if let appError, !appError.isEmpty {
            return appError
        }
        if let agentError = agentState?.lastError, !agentError.isEmpty {
            return L10n.storedMessage(agentError)
        }
        return nil
    }

    public static func appErrorAfterRefresh(
        existingError: String?,
        agentState: BackgroundPromptAgentState?
    ) -> String? {
        if existingError == missingLaunchError, agentState != nil {
            return nil
        }
        return existingError
    }

    public static func shouldClearRuntimeAppError(
        errorSequence: UInt64?,
        successfulSequence: UInt64
    ) -> Bool {
        guard let errorSequence else {
            return false
        }
        return successfulSequence >= errorSequence
    }

    public static func shouldRecordRuntimeAppError(
        existingSequence: UInt64?,
        candidateSequence: UInt64
    ) -> Bool {
        existingSequence.map { candidateSequence >= $0 } ?? true
    }

    public static func shouldPreferAgentError(
        appErrorSequence: UInt64?,
        agentErrorSequence: UInt64?
    ) -> Bool {
        guard let agentErrorSequence else {
            return false
        }
        return appErrorSequence.map { agentErrorSequence > $0 } ?? true
    }

    public static func ownershipTimeoutError(
        state: BackgroundPromptAgentState?,
        expectedIdentity: BackgroundPromptRepairIdentity
    ) -> String {
        guard let state else {
            return missingLaunchError
        }
        let matchingState = BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
            identity: expectedIdentity,
            serviceStatus: .enabled,
            liveAgentState: state
        )
        return matchingState
            ? L10n.tr("The background helper did not become ready in time.")
            : L10n.tr("The registered background helper is still reporting from an older or different app copy.")
    }
}

public struct BackgroundPromptHealthRefreshGeneration: Sendable {
    private var value = 0

    public init() {}

    public mutating func begin() -> Int {
        value += 1
        return value
    }

    public mutating func invalidate() {
        value += 1
    }

    public func isCurrent(_ generation: Int) -> Bool {
        generation == value
    }
}
