import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import SDImportForMac

@MainActor
final class StoreKitIntegrationTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "SDImport")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
    }

    func testLocalConfigurationDefinesLifetimeAndTrialProducts() async throws {
        let products = try await requireRuntimeProducts()
        let product = try XCTUnwrap(products[StoreKitTestPurchaseDriver.lifetimeProductIdentifier])
        let trial = try XCTUnwrap(products[StoreKitTestPurchaseDriver.trialProductIdentifier])

        XCTAssertEqual(product.id, "media.jenny.sdimport.unlimited")
        XCTAssertEqual(product.type, .nonConsumable)
        XCTAssertEqual(product.displayName, "SD Import Unlimited")
        XCTAssertTrue(product.isFamilyShareable)
        XCTAssertEqual(trial.id, "media.jenny.sdimport.trial14")
        XCTAssertEqual(trial.type, .nonConsumable)
        XCTAssertEqual(trial.displayName, "14-Day Trial")
        XCTAssertFalse(trial.isFamilyShareable)

        let manager = makeManager(label: "metadata", observesTransactions: false)
        await manager.refreshStoreState()
        XCTAssertTrue(manager.isFamilyShareable)
        XCTAssertTrue(manager.isTrialProductAvailable)
    }

    func testTrialPurchaseUnlocksWithoutLifetimePurchase() async throws {
        let trial = makeManager(label: "trial")
        await trial.refreshStoreState()

        await trial.startTrial()

        XCTAssertTrue(trial.hasUsedTrial)
        XCTAssertTrue(trial.hasActiveTrial)
        XCTAssertFalse(trial.hasLifetimeUnlock)
    }

    func testPurchaseAndRefundLifecycle() async throws {
        let purchased = makeManager(label: "purchase")
        await purchased.refreshStoreState()
        XCTAssertNotNil(purchased.productDisplayPrice)

        await purchased.purchase()
        XCTAssertTrue(purchased.hasLifetimeUnlock)
        XCTAssertEqual(purchased.purchaseStatus, .purchased)

        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.refundTransaction(identifier: transaction.identifier)
        let refunded = await waitForState(
            purchased,
            matching: { !$0.hasLifetimeUnlock }
        )
        XCTAssertNotNil(refunded)
    }

    func testRestoreLifecycle() async throws {
        let restorablePurchase = makeManager(label: "restorable-purchase")
        await restorablePurchase.refreshStoreState()
        await restorablePurchase.purchase()
        XCTAssertTrue(restorablePurchase.hasLifetimeUnlock)

        let restored = makeManager(label: "restore", observesTransactions: false)
        await restored.restorePurchases()
        XCTAssertTrue(restored.hasLifetimeUnlock)
        XCTAssertEqual(restored.purchaseStatus, .purchased)
    }

    func testPendingPurchaseNeverUnlocks() async throws {
        session.askToBuyEnabled = true
        let pending = makeManager(label: "pending")
        await pending.refreshStoreState()
        await pending.purchase()
        XCTAssertFalse(pending.hasLifetimeUnlock)
        XCTAssertEqual(pending.purchaseStatus, .pending)
    }

    func testVerificationFailureNeverUnlocks() async throws {
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        try await session.setSimulatedError(
            .verification(.invalidSignature),
            forAPI: .verification
        )
        let unverified = makeManager(label: "verification")
        await unverified.refreshStoreState()
        await unverified.purchase()
        XCTAssertFalse(unverified.hasLifetimeUnlock)
        XCTAssertEqual(unverified.purchaseStatus, .verificationFailed)
    }

    func testRestoreTrustsAnAlreadyVerifiedCachedEntitlement() async throws {
        let restorablePurchase = makeManager(label: "cached-restore-purchase")
        await restorablePurchase.refreshStoreState()
        await restorablePurchase.purchase()
        XCTAssertTrue(restorablePurchase.hasLifetimeUnlock)

        try await session.setSimulatedError(
            .verification(.invalidSignature),
            forAPI: .verification
        )
        let restored = makeManager(
            label: "cached-restore",
            observesTransactions: false
        )
        await restored.restorePurchases()
        XCTAssertTrue(restored.hasLifetimeUnlock)
        XCTAssertEqual(restored.purchaseStatus, .purchased)
    }

    private func requireRuntimeProducts() async throws -> [String: Product] {
        let products = try await Product.products(
            for: [
                StoreKitTestPurchaseDriver.lifetimeProductIdentifier,
                StoreKitTestPurchaseDriver.trialProductIdentifier
            ]
        )
        return Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
    }

    private func makeManager(
        label: String,
        observesTransactions: Bool = true
    ) -> StoreKitTestPurchaseDriver {
        let suiteName = "StoreKitIntegrationTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return StoreKitTestPurchaseDriver(
            defaults: defaults,
            observesTransactions: observesTransactions
        )
    }

    private func waitForState(
        _ manager: StoreKitTestPurchaseDriver,
        matching predicate: (StoreKitTestPurchaseDriver) -> Bool,
        attempts: Int = 150
    ) async -> StoreKitTestPurchaseDriver? {
        for _ in 0..<attempts {
            await manager.refreshStoreState()
            if predicate(manager) {
                return manager
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

}
