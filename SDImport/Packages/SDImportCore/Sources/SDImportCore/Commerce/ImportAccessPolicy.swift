import Foundation

public enum ImportPurchaseStatus: Equatable, Sendable {
    case idle
    case loading
    case available
    case purchasing
    case startingTrial
    case pending
    case purchased
    case cancelled
    case verificationFailed
    case unavailable
    case failed(String)
}

public enum ImportPurchaseOutcome: Equatable, Sendable {
    case productAvailable
    case productUnavailable
    case purchased
    case restored
    case trialStarted(Date)
    case trialRevoked
    case pending
    case cancelled
    case verificationFailed
    case revoked
    case failed(String)
}

public struct ImportAccessState: Equatable, Sendable {
    public private(set) var hasLifetimeUnlock: Bool
    public private(set) var trialStartDate: Date?
    public private(set) var purchaseStatus: ImportPurchaseStatus

    public init(
        hasLifetimeUnlock: Bool = false,
        trialStartDate: Date? = nil,
        purchaseStatus: ImportPurchaseStatus = .idle
    ) {
        self.hasLifetimeUnlock = hasLifetimeUnlock
        self.trialStartDate = trialStartDate
        self.purchaseStatus = purchaseStatus
    }

    public var trialEndDate: Date? {
        trialStartDate?.addingTimeInterval(AppDistribution.trialDuration)
    }

    public func isTrialActive(at date: Date = Date()) -> Bool {
        guard let trialEndDate else { return false }
        return date < trialEndDate
    }

    public func canStartImport(
        distribution: AppDistribution,
        at date: Date = Date()
    ) -> Bool {
        distribution == .direct || hasLifetimeUnlock || isTrialActive(at: date)
    }

    public mutating func beginLoading() {
        purchaseStatus = .loading
    }

    public mutating func beginPurchase() {
        purchaseStatus = .purchasing
    }

    public mutating func beginTrial() {
        purchaseStatus = .startingTrial
    }

    public mutating func apply(_ outcome: ImportPurchaseOutcome) {
        switch outcome {
        case .productAvailable:
            purchaseStatus = hasLifetimeUnlock ? .purchased : .available
        case .productUnavailable:
            purchaseStatus = .unavailable
        case .purchased, .restored:
            hasLifetimeUnlock = true
            purchaseStatus = .purchased
        case .trialStarted(let startDate):
            trialStartDate = startDate
            if !hasLifetimeUnlock {
                purchaseStatus = .available
            }
        case .trialRevoked:
            trialStartDate = nil
            if !hasLifetimeUnlock {
                purchaseStatus = .available
            }
        case .pending:
            purchaseStatus = .pending
        case .cancelled:
            purchaseStatus = .cancelled
        case .verificationFailed:
            purchaseStatus = .verificationFailed
        case .revoked:
            hasLifetimeUnlock = false
            purchaseStatus = .available
        case .failed(let message):
            purchaseStatus = .failed(message)
        }
    }

}
