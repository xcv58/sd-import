import Foundation
import SDImportCore
import XCTest
@testable import SDImportCommerce

@MainActor
final class PurchaseManagerOrchestrationTests: XCTestCase {
    private let purchaseDate = Date(timeIntervalSince1970: 1_750_000_000)

    func testRefreshUnlocksBeforeSlowProductMetadataReturns() async {
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { _ in
                try await Task.sleep(for: .seconds(1))
                return nil
            },
            currentEntitlement: { identifier in
                identifier == AppDistribution.lifetimeProductIdentifier
                    ? .entitled(purchaseDate: self.purchaseDate)
                    : .notEntitled
            },
            latestEntitlement: { _ in .notEntitled },
            sync: {},
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(100),
            restoreSyncTimeout: .milliseconds(100)
        ))

        let refresh = Task { @MainActor in
            await manager.refreshStoreState()
        }
        for _ in 0..<20 where !manager.hasLifetimeUnlock {
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertTrue(manager.hasLifetimeUnlock)
        await refresh.value
        XCTAssertTrue(manager.hasLifetimeUnlock)
        XCTAssertEqual(manager.accessState.purchaseStatus, .purchased)
    }

    func testRefreshFallsBackToLatestTransactionBeforeLoadingProduct() async {
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { _ in
                StoreProductSnapshot(
                    product: nil,
                    displayName: "SD Import Unlimited",
                    displayPrice: "$9.99",
                    isFamilyShareable: true
                )
            },
            currentEntitlement: { _ in .notEntitled },
            latestEntitlement: { identifier in
                identifier == AppDistribution.lifetimeProductIdentifier
                    ? .entitled(purchaseDate: self.purchaseDate)
                    : .notEntitled
            },
            sync: {},
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(50)
        ))

        await manager.refreshStoreState()

        XCTAssertTrue(manager.hasLifetimeUnlock)
        XCTAssertEqual(manager.accessState.purchaseStatus, .purchased)
        XCTAssertEqual(manager.productDisplayPrice, "$9.99")
        XCTAssertTrue(manager.isFamilyShareable)
    }

    func testRefreshDoesNotRegrantRevokedEntitlementFromStaleLatestTransaction() async {
        let recorder = StorefrontCallRecorder()
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { _ in
                StoreProductSnapshot(
                    product: nil,
                    displayName: "SD Import Unlimited",
                    displayPrice: "$9.99",
                    isFamilyShareable: true
                )
            },
            currentEntitlement: { identifier in
                guard identifier == AppDistribution.lifetimeProductIdentifier else {
                    return .notEntitled
                }
                recorder.currentEntitlementCalls += 1
                return recorder.currentEntitlementCalls == 1
                    ? .entitled(purchaseDate: self.purchaseDate)
                    : .notEntitled
            },
            latestEntitlement: { identifier in
                guard identifier == AppDistribution.lifetimeProductIdentifier else {
                    return .notEntitled
                }
                recorder.latestEntitlementCalls += 1
                return .entitled(purchaseDate: self.purchaseDate)
            },
            sync: {},
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(50)
        ))

        await manager.refreshStoreState()
        XCTAssertTrue(manager.hasLifetimeUnlock)

        await manager.refreshStoreState()

        XCTAssertFalse(manager.hasLifetimeUnlock)
        XCTAssertEqual(manager.accessState.purchaseStatus, .available)
        XCTAssertEqual(recorder.latestEntitlementCalls, 0)
    }

    func testRefreshDoesNotRegrantRevokedTrialFromStaleLatestTransaction() async {
        let recorder = StorefrontCallRecorder()
        let manager = makeManager(
            storefront: PurchaseStorefront(
                loadProduct: { _ in
                    StoreProductSnapshot(
                        product: nil,
                        displayName: "Product",
                        displayPrice: "$0.00",
                        isFamilyShareable: false
                    )
                },
                currentEntitlement: { identifier in
                    guard identifier == AppDistribution.trialProductIdentifier else {
                        return .notEntitled
                    }
                    recorder.currentTrialEntitlementCalls += 1
                    return recorder.currentTrialEntitlementCalls == 1
                        ? .entitled(purchaseDate: self.purchaseDate)
                        : .notEntitled
                },
                latestEntitlement: { identifier in
                    guard identifier == AppDistribution.trialProductIdentifier else {
                        return .notEntitled
                    }
                    recorder.latestTrialEntitlementCalls += 1
                    return .entitled(purchaseDate: self.purchaseDate)
                },
                sync: {},
                entitlementLookupTimeout: .milliseconds(50),
                productLoadTimeout: .milliseconds(50),
                restoreSyncTimeout: .milliseconds(50)
            ),
            nowProvider: { self.purchaseDate.addingTimeInterval(1) }
        )

        await manager.refreshStoreState()
        XCTAssertTrue(manager.hasActiveTrial)

        await manager.refreshStoreState()

        XCTAssertFalse(manager.hasUsedTrial)
        XCTAssertFalse(manager.canStartImport)
        XCTAssertEqual(manager.accessState.purchaseStatus, .available)
        XCTAssertEqual(recorder.latestTrialEntitlementCalls, 0)
    }

    func testTrialVerificationFailureDoesNotOverrideVerifiedLifetime() async {
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { _ in nil },
            currentEntitlement: { identifier in
                identifier == AppDistribution.lifetimeProductIdentifier
                    ? .entitled(purchaseDate: self.purchaseDate)
                    : .verificationFailed
            },
            latestEntitlement: { identifier in
                identifier == AppDistribution.trialProductIdentifier
                    ? .verificationFailed
                    : .notEntitled
            },
            sync: {},
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(50)
        ))

        await manager.refreshStoreState()

        XCTAssertTrue(manager.hasLifetimeUnlock)
        XCTAssertTrue(manager.canStartImport)
        XCTAssertEqual(manager.accessState.purchaseStatus, .purchased)
    }

    func testLifetimeVerificationFailureDoesNotOverrideVerifiedTrial() async {
        let manager = makeManager(
            storefront: PurchaseStorefront(
                loadProduct: { _ in nil },
                currentEntitlement: { identifier in
                    identifier == AppDistribution.lifetimeProductIdentifier
                        ? .verificationFailed
                        : .notEntitled
                },
                latestEntitlement: { identifier in
                    identifier == AppDistribution.lifetimeProductIdentifier
                        ? .verificationFailed
                        : .entitled(purchaseDate: self.purchaseDate)
                },
                sync: {},
                entitlementLookupTimeout: .milliseconds(50),
                productLoadTimeout: .milliseconds(50),
                restoreSyncTimeout: .milliseconds(50)
            ),
            nowProvider: { self.purchaseDate.addingTimeInterval(1) }
        )

        await manager.refreshStoreState()

        XCTAssertFalse(manager.hasLifetimeUnlock)
        XCTAssertTrue(manager.hasActiveTrial)
        XCTAssertTrue(manager.canStartImport)
        XCTAssertEqual(manager.accessState.purchaseStatus, .available)
    }

    func testRestoreUsesExistingEntitlementWithoutAuthenticatedSync() async {
        let recorder = StorefrontCallRecorder()
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { _ in nil },
            currentEntitlement: { identifier in
                identifier == AppDistribution.lifetimeProductIdentifier
                    ? .entitled(purchaseDate: self.purchaseDate)
                    : .notEntitled
            },
            latestEntitlement: { _ in .notEntitled },
            sync: {
                recorder.syncCalls += 1
            },
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(50)
        ))

        await manager.restorePurchases()

        XCTAssertTrue(manager.hasLifetimeUnlock)
        XCTAssertEqual(manager.accessState.purchaseStatus, .purchased)
        XCTAssertEqual(recorder.syncCalls, 0)
    }

    func testRestoreSyncsLifetimePurchaseWhenExpiredTrialAlreadyExists() async {
        let recorder = StorefrontCallRecorder()
        let manager = makeManager(
            storefront: PurchaseStorefront(
                loadProduct: { _ in nil },
                currentEntitlement: { identifier in
                    if identifier == AppDistribution.trialProductIdentifier {
                        return .entitled(purchaseDate: self.purchaseDate)
                    }
                    return recorder.syncCalls > 0
                        ? .entitled(purchaseDate: self.purchaseDate)
                        : .notEntitled
                },
                latestEntitlement: { _ in .notEntitled },
                sync: { recorder.syncCalls += 1 },
                entitlementLookupTimeout: .milliseconds(50),
                productLoadTimeout: .milliseconds(50),
                restoreSyncTimeout: .milliseconds(50)
            ),
            nowProvider: {
                self.purchaseDate.addingTimeInterval(AppDistribution.trialDuration)
            }
        )

        await manager.restorePurchases()

        XCTAssertEqual(recorder.syncCalls, 1)
        XCTAssertTrue(manager.hasLifetimeUnlock)
        XCTAssertEqual(manager.accessState.purchaseStatus, .purchased)
    }

    func testRestoreSyncTimeoutReturnsControlWithRetryMessage() async {
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { _ in nil },
            currentEntitlement: { _ in .notEntitled },
            latestEntitlement: { _ in .notEntitled },
            sync: {
                try await Task.sleep(for: .seconds(10))
            },
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(20)
        ))

        await manager.restorePurchases()

        XCTAssertFalse(manager.hasLifetimeUnlock)
        XCTAssertEqual(
            manager.accessState.purchaseStatus,
            .failed("The App Store did not finish restoring purchases. Your purchase is safe; try again.")
        )
        XCTAssertFalse(manager.isPerformingStoreOperation)
    }

    func testRestoreVerificationFailureNeverUnlocksOrStartsSync() async {
        let recorder = StorefrontCallRecorder()
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { _ in nil },
            currentEntitlement: { _ in .verificationFailed },
            latestEntitlement: { identifier in
                identifier == AppDistribution.lifetimeProductIdentifier
                    ? .entitled(purchaseDate: self.purchaseDate)
                    : .notEntitled
            },
            sync: {
                recorder.syncCalls += 1
            },
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(50)
        ))

        await manager.restorePurchases()

        XCTAssertFalse(manager.hasLifetimeUnlock)
        XCTAssertEqual(manager.accessState.purchaseStatus, .verificationFailed)
        XCTAssertEqual(recorder.syncCalls, 0)
    }

    func testProductTimeoutDoesNotLeavePurchaseLoadingForever() async {
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { _ in
                try await Task.sleep(for: .seconds(10))
                return nil
            },
            currentEntitlement: { _ in .notEntitled },
            latestEntitlement: { _ in .notEntitled },
            sync: {},
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(20),
            restoreSyncTimeout: .milliseconds(50)
        ))

        await manager.refreshStoreState()

        XCTAssertFalse(manager.hasLifetimeUnlock)
        XCTAssertEqual(
            manager.accessState.purchaseStatus,
            .failed("Purchase information is taking longer than expected. Try again.")
        )
        XCTAssertFalse(manager.isPerformingStoreOperation)
    }

    func testMissingLifetimeProductDoesNotHideAvailableTrial() async {
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { identifier in
                guard identifier == AppDistribution.trialProductIdentifier else { return nil }
                return StoreProductSnapshot(
                    product: nil,
                    displayName: "14-Day Trial",
                    displayPrice: "$0.00",
                    isFamilyShareable: false
                )
            },
            currentEntitlement: { _ in .notEntitled },
            latestEntitlement: { _ in .notEntitled },
            sync: {},
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(50)
        ))

        await manager.refreshStoreState()

        XCTAssertTrue(manager.isTrialProductAvailable)
        XCTAssertNil(manager.trialProductError)
        XCTAssertNotNil(manager.lifetimeProductError)
        XCTAssertEqual(manager.accessState.purchaseStatus, .available)
    }

    func testMissingTrialProductDoesNotHideAvailableLifetimePurchase() async {
        let manager = makeManager(storefront: PurchaseStorefront(
            loadProduct: { identifier in
                guard identifier == AppDistribution.lifetimeProductIdentifier else { return nil }
                return StoreProductSnapshot(
                    product: nil,
                    displayName: "SD Import Unlimited",
                    displayPrice: "$9.99",
                    isFamilyShareable: true
                )
            },
            currentEntitlement: { _ in .notEntitled },
            latestEntitlement: { _ in .notEntitled },
            sync: {},
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(50)
        ))

        await manager.refreshStoreState()

        XCTAssertEqual(manager.productDisplayPrice, "$9.99")
        XCTAssertNil(manager.lifetimeProductError)
        XCTAssertFalse(manager.isTrialProductAvailable)
        XCTAssertNotNil(manager.trialProductError)
        XCTAssertEqual(manager.accessState.purchaseStatus, .available)
    }

    func testVerifiedTrialUsesTransactionDateAndExpiresAfterFourteenDays() async {
        let now = purchaseDate.addingTimeInterval(AppDistribution.trialDuration - 1)
        let manager = makeManager(
            storefront: PurchaseStorefront(
                loadProduct: { _ in nil },
                currentEntitlement: { identifier in
                    identifier == AppDistribution.trialProductIdentifier
                        ? .entitled(purchaseDate: self.purchaseDate)
                        : .notEntitled
                },
                latestEntitlement: { _ in .notEntitled },
                sync: {},
                entitlementLookupTimeout: .milliseconds(50),
                productLoadTimeout: .milliseconds(50),
                restoreSyncTimeout: .milliseconds(50)
            ),
            nowProvider: { now }
        )

        await manager.refreshStoreState()

        XCTAssertTrue(manager.hasUsedTrial)
        XCTAssertTrue(manager.hasActiveTrial)
        XCTAssertTrue(manager.canStartImport)
        XCTAssertEqual(
            manager.trialEndDate,
            purchaseDate.addingTimeInterval(AppDistribution.trialDuration)
        )

        let expired = makeManager(
            storefront: PurchaseStorefront(
                loadProduct: { _ in nil },
                currentEntitlement: { identifier in
                    identifier == AppDistribution.trialProductIdentifier
                        ? .entitled(purchaseDate: self.purchaseDate)
                        : .notEntitled
                },
                latestEntitlement: { _ in .notEntitled },
                sync: {},
                entitlementLookupTimeout: .milliseconds(50),
                productLoadTimeout: .milliseconds(50),
                restoreSyncTimeout: .milliseconds(50)
            ),
            nowProvider: {
                self.purchaseDate.addingTimeInterval(AppDistribution.trialDuration)
            }
        )
        await expired.refreshStoreState()
        XCTAssertTrue(expired.hasUsedTrial)
        XCTAssertFalse(expired.hasActiveTrial)
        XCTAssertFalse(expired.canStartImport)
    }

    func testLegacyFreeImportDefaultDoesNotStartOrBlockTrial() {
        let suiteName = "PurchaseManagerOrchestrationTests.legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(1, forKey: "SDImport.purchase.completedFreeImports")
        let manager = PurchaseManager(
            defaults: defaults,
            distribution: .macAppStore,
            startsStoreTask: false,
            storefront: emptyStorefront()
        )

        XCTAssertFalse(manager.hasUsedTrial)
        XCTAssertFalse(manager.canStartImport)
    }

    private func makeManager(
        storefront: PurchaseStorefront,
        nowProvider: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> PurchaseManager {
        let suiteName = "PurchaseManagerOrchestrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PurchaseManager(
            defaults: defaults,
            distribution: .macAppStore,
            startsStoreTask: false,
            storefront: storefront,
            nowProvider: nowProvider
        )
    }

    private func emptyStorefront() -> PurchaseStorefront {
        PurchaseStorefront(
            loadProduct: { _ in nil },
            currentEntitlement: { _ in .notEntitled },
            latestEntitlement: { _ in .notEntitled },
            sync: {},
            entitlementLookupTimeout: .milliseconds(50),
            productLoadTimeout: .milliseconds(50),
            restoreSyncTimeout: .milliseconds(50)
        )
    }
}

@MainActor
private final class StorefrontCallRecorder {
    var syncCalls = 0
    var currentEntitlementCalls = 0
    var latestEntitlementCalls = 0
    var currentTrialEntitlementCalls = 0
    var latestTrialEntitlementCalls = 0
}
