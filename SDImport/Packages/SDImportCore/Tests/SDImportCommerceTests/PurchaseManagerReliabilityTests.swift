import Foundation
import SDImportCore
import StoreKit
import XCTest
@testable import SDImportCommerce

@MainActor
final class PurchaseManagerReliabilityTests: XCTestCase {
    private let purchaseDate = Date(timeIntervalSince1970: 1_750_000_000)

    func testUnverifiedTrialDoesNotBlockProductMetadataOrRestore() async {
        let state = StorefrontState()
        let manager = makeManager(state: state, current: { identifier in
            identifier == AppDistribution.trialProductIdentifier ? .verificationFailed : .notEntitled
        })

        await manager.refreshStoreState()

        XCTAssertTrue(state.loadedProducts.contains(AppDistribution.lifetimeProductIdentifier))
        XCTAssertEqual(manager.productDisplayPrice, "$9.99")
        XCTAssertTrue(manager.isTrialProductAvailable)
        XCTAssertEqual(manager.accessState.purchaseStatus, .verificationFailed)
        XCTAssertFalse(manager.canStartImport)

        await manager.restorePurchases()

        XCTAssertEqual(state.syncCalls, 1)
        XCTAssertEqual(manager.accessState.purchaseStatus, .verificationFailed)
        XCTAssertFalse(manager.canStartImport)
        XCTAssertFalse(manager.isPerformingStoreOperation)
    }

    func testRestoreCanRecoverFromTrialVerificationFailure() async {
        let state = StorefrontState()
        let manager = makeManager(state: state, current: { identifier in
            if state.syncCalls > 0 {
                return identifier == AppDistribution.lifetimeProductIdentifier
                    ? .entitled(purchaseDate: self.purchaseDate) : .notEntitled
            }
            return identifier == AppDistribution.trialProductIdentifier
                ? .verificationFailed : .notEntitled
        })

        await manager.restorePurchases()

        XCTAssertEqual(state.syncCalls, 1)
        XCTAssertTrue(manager.hasLifetimeUnlock)
        XCTAssertTrue(manager.canStartImport)
        XCTAssertEqual(manager.accessState.purchaseStatus, .purchased)
        XCTAssertFalse(manager.isPerformingStoreOperation)
    }

    func testActiveTrialKeepsRestoreBusyUntilSyncFinishes() async {
        await assertRestoreStaysBusy(trialAgeInDays: 1)
    }

    func testExpiredTrialKeepsRestoreBusyUntilSyncFinishes() async {
        await assertRestoreStaysBusy(trialAgeInDays: 15)
    }

    func testRestoreRejectsOtherStoreOperationsWhileSyncIsInFlight() async {
        let state = StorefrontState()
        state.holdSync = true
        let manager = makeManager(state: state, current: { _ in .notEntitled })
        let restore = Task { await manager.restorePurchases() }
        let started = await waitUntil { state.syncCalls == 1 }
        XCTAssertTrue(started)

        let secondRestore = Task {
            await manager.restorePurchases()
            state.completedOverlappingOperations += 1
        }
        await manager.purchase()
        await manager.startTrial()
        await manager.refreshStoreState()
        let rejected = await waitUntil {
            state.completedOverlappingOperations == 1 || state.syncCalls > 1
        }
        XCTAssertTrue(rejected)
        state.finishSyncs()
        await restore.value
        await secondRestore.value

        XCTAssertTrue(state.loadedProducts.isEmpty, "Overlapping actions must not start product requests")
        XCTAssertEqual(state.syncCalls, 1)
        XCTAssertFalse(manager.isPerformingStoreOperation)
    }

    func testPurchaseStaysBusyWhileLoadingProductsAndRejectsOtherOperations() async {
        let state = StorefrontState()
        state.holdProducts = true
        let manager = makeManager(state: state, current: { _ in .notEntitled })
        let purchase = Task { await manager.purchase() }
        let started = await waitUntil { state.productContinuations.count == 2 }
        XCTAssertTrue(started)
        XCTAssertTrue(manager.isPerformingStoreOperation)

        let secondPurchase = Task {
            await manager.purchase()
            state.completedOverlappingOperations += 1
        }
        let trial = Task {
            await manager.startTrial()
            state.completedOverlappingOperations += 1
        }
        let restore = Task {
            await manager.restorePurchases()
            state.completedOverlappingOperations += 1
        }
        let rejected = await waitUntil {
            state.completedOverlappingOperations == 3 || state.loadedProducts.count > 2 || state.syncCalls > 0
        }
        XCTAssertTrue(rejected)
        state.finishProductLoads()
        await purchase.value
        await secondPurchase.value
        await trial.value
        await restore.value

        XCTAssertEqual(state.loadedProducts.count, 2)
        XCTAssertEqual(state.syncCalls, 0)
        XCTAssertFalse(manager.isPerformingStoreOperation)
    }

    func testOlderLifetimeResultCannotUndoRevocation() async {
        await assertOlderPositiveIsIgnored(product: .lifetime, source: .current, initiallyEntitled: true)
    }

    func testOlderTrialResultCannotUndoRevocation() async {
        await assertOlderPositiveIsIgnored(product: .trial, source: .current, initiallyEntitled: true)
    }

    func testOlderLifetimeResultCannotUndoNewerMissingResult() async {
        await assertOlderPositiveIsIgnored(product: .lifetime, source: .current, initiallyEntitled: false)
    }

    func testOlderTrialResultCannotUndoNewerMissingResult() async {
        await assertOlderPositiveIsIgnored(product: .trial, source: .current, initiallyEntitled: false)
    }

    func testOlderLatestLifetimeTransactionCannotUndoNewerMissingResult() async {
        await assertOlderPositiveIsIgnored(product: .lifetime, source: .latest, initiallyEntitled: false)
    }

    func testOlderLatestTrialTransactionCannotUndoNewerMissingResult() async {
        await assertOlderPositiveIsIgnored(product: .trial, source: .latest, initiallyEntitled: false)
    }

    func testOlderNegativeLifetimeResultCannotRemoveNewerVerifiedAccess() async {
        await assertNewerVerifiedAccessIsPreserved(product: .lifetime)
    }

    func testOlderNegativeTrialResultCannotRemoveNewerVerifiedAccess() async {
        await assertNewerVerifiedAccessIsPreserved(product: .trial)
    }

    func testFailedNewerLifetimeCheckDoesNotSuppressRevocation() async {
        await assertOlderResultSurvivesFailedNewerCheck(product: .lifetime)
    }

    func testFailedNewerTrialCheckDoesNotSuppressRevocation() async {
        await assertOlderResultSurvivesFailedNewerCheck(product: .trial)
    }

    func testTimedOutNewerLifetimeCheckDoesNotSuppressRevocation() async {
        await assertOlderResultSurvivesFailedNewerCheck(product: .lifetime, newerTimesOut: true)
    }

    func testTimedOutNewerTrialCheckDoesNotSuppressRevocation() async {
        await assertOlderResultSurvivesFailedNewerCheck(product: .trial, newerTimesOut: true)
    }

    func testFailedNewerLifetimeCheckDoesNotSuppressVerifiedGrant() async {
        await assertOlderResultSurvivesFailedNewerCheck(product: .lifetime, revoking: false)
    }

    func testFailedNewerTrialCheckDoesNotSuppressVerifiedGrant() async {
        await assertOlderResultSurvivesFailedNewerCheck(product: .trial, revoking: false)
    }

    func testOlderLifetimeGrantDoesNotInvalidateNewerPendingCheck() async {
        await assertNewerCheckAppliesAfterOlderGrant(product: .lifetime)
    }

    func testOlderTrialGrantDoesNotInvalidateNewerPendingCheck() async {
        await assertNewerCheckAppliesAfterOlderGrant(product: .trial)
    }

    func testOrdinaryLookupTimeoutPreservesPreviouslyVerifiedAccess() async {
        let state = StorefrontState()
        let manager = makeManager(
            state: state,
            current: { identifier in
                guard identifier == AppDistribution.lifetimeProductIdentifier else { return .notEntitled }
                if state.delayCurrentLookup {
                    try? await Task.sleep(for: .seconds(1))
                    return .notEntitled
                }
                return .entitled(purchaseDate: self.purchaseDate)
            },
            lookupTimeout: .milliseconds(20)
        )
        await manager.refreshStoreState()
        XCTAssertTrue(manager.hasLifetimeUnlock)

        state.delayCurrentLookup = true
        let result = await manager.refreshLifetimeEntitlement(restored: false)

        XCTAssertEqual(result, .notFound)
        XCTAssertTrue(manager.hasLifetimeUnlock)
        XCTAssertTrue(manager.canStartImport)
    }

    private func assertRestoreStaysBusy(
        trialAgeInDays: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = StorefrontState()
        state.holdSync = true
        let manager = makeManager(
            state: state,
            current: { identifier in
                identifier == AppDistribution.trialProductIdentifier
                    ? .entitled(purchaseDate: self.purchaseDate) : .notEntitled
            },
            now: purchaseDate.addingTimeInterval(Double(trialAgeInDays) * 86_400)
        )
        let restore = Task { await manager.restorePurchases() }
        let started = await waitUntil { state.syncCalls == 1 }
        XCTAssertTrue(started, file: file, line: line)
        XCTAssertTrue(manager.isPerformingStoreOperation, file: file, line: line)
        XCTAssertEqual(manager.statusMessage, "Loading purchase information…", file: file, line: line)

        let secondRestore = Task {
            await manager.restorePurchases()
            state.completedOverlappingOperations += 1
        }
        let rejected = await waitUntil {
            state.completedOverlappingOperations == 1 || state.syncCalls > 1
        }
        XCTAssertTrue(rejected, file: file, line: line)
        state.finishSyncs()
        await restore.value
        await secondRestore.value

        XCTAssertEqual(state.syncCalls, 1, file: file, line: line)
        XCTAssertFalse(manager.isPerformingStoreOperation, file: file, line: line)
        XCTAssertNil(manager.statusMessage, file: file, line: line)
    }

    private func assertOlderPositiveIsIgnored(
        product: EntitlementProduct,
        source: LookupSource,
        initiallyEntitled: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = StorefrontState()
        state.currentResult = initiallyEntitled ? .entitled(purchaseDate: purchaseDate) : .notEntitled
        let manager = makeOrderedLookupManager(state: state, product: product)
        await manager.refreshStoreState()
        XCTAssertEqual(manager.canStartImport, initiallyEntitled, file: file, line: line)

        state.heldLookupSource = source
        let older = Task { await manager.refreshStoreState() }
        let started = await waitUntil { state.lookupContinuation != nil }
        XCTAssertTrue(started, file: file, line: line)
        state.heldLookupSource = nil
        state.currentResult = .notEntitled
        await manager.refreshStoreState()
        XCTAssertFalse(manager.canStartImport, file: file, line: line)

        state.finishLookup(with: .entitled(purchaseDate: purchaseDate))
        await older.value

        XCTAssertFalse(manager.hasLifetimeUnlock, file: file, line: line)
        XCTAssertFalse(manager.hasUsedTrial, file: file, line: line)
        XCTAssertFalse(manager.canStartImport, "An outdated response must not regrant access", file: file, line: line)
        XCTAssertFalse(manager.isPerformingStoreOperation, file: file, line: line)
    }

    private func assertNewerVerifiedAccessIsPreserved(
        product: EntitlementProduct,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = StorefrontState()
        state.currentResult = .entitled(purchaseDate: purchaseDate)
        let manager = makeOrderedLookupManager(state: state, product: product)
        await manager.refreshStoreState()

        state.heldLookupSource = .current
        let older = Task { await manager.refreshStoreState() }
        let started = await waitUntil { state.lookupContinuation != nil }
        XCTAssertTrue(started, file: file, line: line)
        state.heldLookupSource = nil
        await manager.refreshStoreState()
        XCTAssertTrue(manager.canStartImport, file: file, line: line)

        state.finishLookup(with: .notEntitled)
        await older.value

        XCTAssertTrue(manager.canStartImport, file: file, line: line)
    }

    private func assertOlderResultSurvivesFailedNewerCheck(
        product: EntitlementProduct,
        newerTimesOut: Bool = false,
        revoking: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = StorefrontState()
        state.currentResult = revoking ? .entitled(purchaseDate: purchaseDate) : .notEntitled
        let manager = makeOrderedLookupManager(
            state: state,
            product: product,
            lookupTimeout: newerTimesOut ? .milliseconds(200) : .seconds(5)
        )
        await manager.refreshStoreState()
        XCTAssertEqual(manager.canStartImport, revoking, file: file, line: line)

        state.heldLookupSource = .current
        let older = Task { await manager.refreshStoreState() }
        let started = await waitUntil { state.lookupContinuation != nil }
        XCTAssertTrue(started, file: file, line: line)
        state.heldLookupSource = nil
        state.currentResult = .verificationFailed
        state.delayCurrentLookup = newerTimesOut
        let newer = Task { await manager.refreshStoreState() }
        if newerTimesOut {
            let newerStarted = await waitUntil { state.delayedCurrentLookupStarted }
            XCTAssertTrue(newerStarted, file: file, line: line)
        } else {
            await newer.value
        }
        XCTAssertEqual(manager.canStartImport, revoking, "A failed check must preserve existing access", file: file, line: line)

        // Both requests share a deadline duration, so deliver the older valid
        // result while the newer request is pending, then let that request time out.
        state.finishLookup(with: revoking ? .notEntitled : .entitled(purchaseDate: purchaseDate))
        await older.value
        await newer.value
        state.delayCurrentLookup = false

        XCTAssertEqual(manager.canStartImport, !revoking, "A failed newer check must not cancel a valid older result", file: file, line: line)
        XCTAssertFalse(manager.isPerformingStoreOperation, file: file, line: line)
    }

    private func assertNewerCheckAppliesAfterOlderGrant(
        product: EntitlementProduct,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = StorefrontState()
        let manager = makeManager(state: state, current: { identifier in
            guard identifier == product.identifier else { return .notEntitled }
            return await withCheckedContinuation { state.lookupContinuations.append($0) }
        })

        let older = Task { await manager.refreshStoreState() }
        let olderStarted = await waitUntil { state.lookupContinuations.count == 1 }
        XCTAssertTrue(olderStarted, file: file, line: line)
        let newer = Task { await manager.refreshStoreState() }
        let newerStarted = await waitUntil { state.lookupContinuations.count == 2 }
        XCTAssertTrue(newerStarted, file: file, line: line)
        guard olderStarted, newerStarted else {
            let pending = state.lookupContinuations
            state.lookupContinuations.removeAll()
            for continuation in pending { continuation.resume(returning: .notEntitled) }
            await older.value
            await newer.value
            return
        }

        state.lookupContinuations.removeFirst().resume(returning: .entitled(purchaseDate: purchaseDate))
        await older.value
        XCTAssertTrue(manager.canStartImport, file: file, line: line)

        state.lookupContinuations.removeFirst().resume(returning: .notEntitled)
        await newer.value
        XCTAssertFalse(manager.canStartImport, "Committing an older grant must not cancel a newer request", file: file, line: line)
        XCTAssertFalse(manager.isPerformingStoreOperation, file: file, line: line)
    }

    private func makeOrderedLookupManager(
        state: StorefrontState,
        product: EntitlementProduct,
        lookupTimeout: Duration = .seconds(5)
    ) -> PurchaseManager {
        makeManager(
            state: state,
            current: { identifier in
                guard identifier == product.identifier else { return .notEntitled }
                if state.heldLookupSource == .current {
                    return await withCheckedContinuation { state.lookupContinuation = $0 }
                }
                if state.delayCurrentLookup {
                    state.delayedCurrentLookupStarted = true
                    try? await Task.sleep(for: .seconds(1))
                }
                return state.currentResult
            },
            latest: { identifier in
                guard identifier == product.identifier else { return .notEntitled }
                if state.heldLookupSource == .latest {
                    return await withCheckedContinuation { state.lookupContinuation = $0 }
                }
                return .notEntitled
            },
            lookupTimeout: lookupTimeout
        )
    }

    private func makeManager(
        state: StorefrontState,
        current: @escaping @MainActor @Sendable (String) async -> StoreEntitlementLookup,
        latest: @escaping @MainActor @Sendable (String) async -> StoreEntitlementLookup = { _ in .notEntitled },
        lookupTimeout: Duration = .seconds(5),
        now: Date? = nil
    ) -> PurchaseManager {
        PurchaseManager(
            defaults: UserDefaults(suiteName: "PurchaseManagerReliabilityTests.\(UUID().uuidString)")!,
            distribution: .macAppStore,
            startsStoreTask: false,
            storefront: PurchaseStorefront(
                loadProduct: { identifier in
                    state.loadedProducts.append(identifier)
                    if state.holdProducts {
                        return await withCheckedContinuation { state.productContinuations.append($0) }
                    }
                    return StoreProductSnapshot(
                        product: nil,
                        displayName: "Product",
                        displayPrice: "$9.99",
                        isFamilyShareable: identifier == AppDistribution.lifetimeProductIdentifier
                    )
                },
                currentEntitlement: current,
                latestEntitlement: latest,
                sync: {
                    state.syncCalls += 1
                    if state.holdSync {
                        await withCheckedContinuation { state.syncContinuations.append($0) }
                    }
                },
                entitlementLookupTimeout: lookupTimeout,
                productLoadTimeout: .seconds(5),
                restoreSyncTimeout: .seconds(5)
            ),
            nowProvider: { now ?? self.purchaseDate.addingTimeInterval(1) }
        )
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return predicate()
    }
}

private enum EntitlementProduct {
    case lifetime
    case trial

    var identifier: String {
        switch self {
        case .lifetime: AppDistribution.lifetimeProductIdentifier
        case .trial: AppDistribution.trialProductIdentifier
        }
    }
}

private enum LookupSource {
    case current
    case latest
}

@MainActor
private final class StorefrontState {
    var loadedProducts: [String] = []
    var holdProducts = false
    var productContinuations: [CheckedContinuation<StoreProductSnapshot?, Never>] = []
    var syncCalls = 0
    var completedOverlappingOperations = 0
    var holdSync = false
    var syncContinuations: [CheckedContinuation<Void, Never>] = []
    var currentResult: StoreEntitlementLookup = .notEntitled
    var delayCurrentLookup = false
    var delayedCurrentLookupStarted = false
    var heldLookupSource: LookupSource?
    var lookupContinuation: CheckedContinuation<StoreEntitlementLookup, Never>?
    var lookupContinuations: [CheckedContinuation<StoreEntitlementLookup, Never>] = []

    func finishSyncs() {
        holdSync = false
        let continuations = syncContinuations
        syncContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    func finishProductLoads() {
        holdProducts = false
        let continuations = productContinuations
        productContinuations.removeAll()
        for continuation in continuations { continuation.resume(returning: nil) }
    }

    func finishLookup(with result: StoreEntitlementLookup) {
        lookupContinuation?.resume(returning: result)
        lookupContinuation = nil
    }
}
