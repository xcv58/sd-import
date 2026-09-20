import Foundation
import Testing
@testable import SDImportCore

@Suite("Import access policy")
struct ImportAccessPolicyTests {
    private let trialStart = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("direct builds remain unlimited")
    func directBuildIsUnlimited() {
        let state = ImportAccessState()
        #expect(state.canStartImport(distribution: .direct, at: trialStart))
    }

    @Test("App Store builds are locked before trial or purchase")
    func appStoreStartsLocked() {
        let state = ImportAccessState()
        #expect(!state.canStartImport(distribution: .macAppStore, at: trialStart))
        #expect(state.trialStartDate == nil)
    }

    @Test("verified trial unlocks imports for exactly 14 days")
    func trialWindow() {
        var state = ImportAccessState()
        state.apply(.trialStarted(trialStart))

        let justBeforeEnd = trialStart.addingTimeInterval(AppDistribution.trialDuration - 0.001)
        let exactEnd = trialStart.addingTimeInterval(AppDistribution.trialDuration)
        #expect(state.isTrialActive(at: justBeforeEnd))
        #expect(state.canStartImport(distribution: .macAppStore, at: justBeforeEnd))
        #expect(!state.isTrialActive(at: exactEnd))
        #expect(!state.canStartImport(distribution: .macAppStore, at: exactEnd))
        #expect(state.trialEndDate == exactEnd)
    }

    @Test("lifetime purchase remains unlocked after trial expiration")
    func lifetimeOverridesTrialExpiration() {
        var state = ImportAccessState(trialStartDate: trialStart)
        state.apply(.purchased)

        let afterTrial = trialStart.addingTimeInterval(AppDistribution.trialDuration + 1)
        #expect(state.canStartImport(distribution: .macAppStore, at: afterTrial))
        #expect(state.purchaseStatus == .purchased)
    }

    @Test("revoking trial removes trial access")
    func trialRevocation() {
        var state = ImportAccessState(trialStartDate: trialStart)
        state.apply(.trialRevoked)

        #expect(state.trialStartDate == nil)
        #expect(!state.canStartImport(distribution: .macAppStore, at: trialStart))
    }

    @Test("verified purchase and restore unlock while revocation removes lifetime entitlement")
    func entitlementLifecycle() {
        var state = ImportAccessState()
        state.apply(.purchased)
        #expect(state.canStartImport(distribution: .macAppStore, at: trialStart))
        #expect(state.purchaseStatus == .purchased)

        state.apply(.revoked)
        #expect(!state.canStartImport(distribution: .macAppStore, at: trialStart))

        state.apply(.restored)
        #expect(state.canStartImport(distribution: .macAppStore, at: trialStart))
    }

    @Test("pending cancellation and verification failures never unlock")
    func nonSuccessOutcomesDoNotUnlock() {
        for outcome in [
            ImportPurchaseOutcome.pending,
            .cancelled,
            .verificationFailed,
            .failed("Store unavailable")
        ] {
            var state = ImportAccessState()
            state.apply(outcome)
            #expect(!state.hasLifetimeUnlock)
            #expect(!state.canStartImport(distribution: .macAppStore, at: trialStart))
        }
    }
}
