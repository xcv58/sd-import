import Combine
import Foundation
import SDImportCore
import StoreKit

enum StoreEntitlementLookup: Sendable {
    case entitled
    case notEntitled
    case verificationFailed
}

struct StoreProductSnapshot: Sendable {
    let product: Product?
    let displayName: String
    let displayPrice: String
    let isFamilyShareable: Bool
}

struct PurchaseStorefront: Sendable {
    let loadProduct: @MainActor @Sendable (String) async throws -> StoreProductSnapshot?
    let currentEntitlement: @MainActor @Sendable (String) async -> StoreEntitlementLookup
    let latestEntitlement: @MainActor @Sendable (String) async -> StoreEntitlementLookup
    let sync: @MainActor @Sendable () async throws -> Void
    let entitlementLookupTimeout: Duration
    let productLoadTimeout: Duration
    let restoreSyncTimeout: Duration

    static let live = PurchaseStorefront(
        loadProduct: { identifier in
            guard let product = try await Product.products(for: [identifier]).first else {
                return nil
            }
            return StoreProductSnapshot(
                product: product,
                displayName: product.displayName,
                displayPrice: product.displayPrice,
                isFamilyShareable: product.isFamilyShareable
            )
        },
        currentEntitlement: { identifier in
            var foundEntitlement = false
            var encounteredVerificationFailure = false
            for await verification in Transaction.currentEntitlements {
                guard case .verified(let transaction) = verification else {
                    encounteredVerificationFailure = true
                    continue
                }
                if transaction.productID == identifier, transaction.revocationDate == nil {
                    foundEntitlement = true
                }
            }
            if foundEntitlement {
                return .entitled
            }
            return encounteredVerificationFailure ? .verificationFailed : .notEntitled
        },
        latestEntitlement: { identifier in
            guard let verification = await Transaction.latest(for: identifier) else {
                return .notEntitled
            }
            guard case .verified(let transaction) = verification else {
                return .verificationFailed
            }
            guard transaction.productID == identifier, transaction.revocationDate == nil else {
                return .notEntitled
            }
            return .entitled
        },
        sync: {
            try await AppStore.sync()
        },
        entitlementLookupTimeout: .seconds(5),
        productLoadTimeout: .seconds(15),
        restoreSyncTimeout: .seconds(60)
    )
}

@MainActor
public final class PurchaseManager: ObservableObject {
    private enum DefaultsKey {
        static let completedFreeImports = "SDImport.purchase.completedFreeImports"
    }

    @Published public private(set) var accessState: ImportAccessState
    @Published public var isShowingPurchase = false
    @Published public private(set) var productDisplayName = "SD Import Unlimited"
    @Published public private(set) var productDisplayPrice: String?
    @Published public private(set) var isFamilyShareable = false

    private let defaults: UserDefaults
    private let distribution: AppDistribution
    private let storefront: PurchaseStorefront
    private var product: Product?
    private var updatesTask: Task<Void, Never>?
    private var initialStoreRefreshTask: Task<Void, Never>?
    private var entitlementRevision: UInt64 = 0

    public convenience init(
        defaults: UserDefaults = .standard,
        distribution: AppDistribution = .current,
        startsStoreTask: Bool = true
    ) {
        self.init(
            defaults: defaults,
            distribution: distribution,
            startsStoreTask: startsStoreTask,
            storefront: .live
        )
    }

    init(
        defaults: UserDefaults,
        distribution: AppDistribution,
        startsStoreTask: Bool,
        storefront: PurchaseStorefront
    ) {
        self.defaults = defaults
        self.distribution = distribution
        self.storefront = storefront
        accessState = ImportAccessState(
            completedFreeImports: defaults.integer(forKey: DefaultsKey.completedFreeImports)
        )
        let isHostedTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if distribution == .macAppStore, startsStoreTask, !isHostedTest {
            startObservingTransactions()
        }
    }

    deinit {
        updatesTask?.cancel()
        initialStoreRefreshTask?.cancel()
    }

    public var isMacAppStoreEdition: Bool {
        distribution == .macAppStore
    }

    public var canStartImport: Bool {
        accessState.canStartImport(distribution: distribution)
    }

    public var hasLifetimeUnlock: Bool {
        accessState.hasLifetimeUnlock
    }

    public var isPerformingStoreOperation: Bool {
        switch accessState.purchaseStatus {
        case .loading, .purchasing:
            true
        default:
            false
        }
    }

    public var allowanceSummary: String {
        if accessState.hasLifetimeUnlock {
            return L10n.tr("Lifetime access unlocked")
        }
        if accessState.remainingFreeImports(distribution: distribution) == 1 {
            return L10n.tr("Your first completed import is free")
        }
        return L10n.tr("The free import has been used")
    }

    public var statusMessage: String? {
        switch accessState.purchaseStatus {
        case .idle, .available, .purchased:
            return nil
        case .loading:
            return L10n.tr("Loading purchase information…")
        case .purchasing:
            return L10n.tr("Completing purchase…")
        case .pending:
            return L10n.tr("Purchase is pending approval.")
        case .cancelled:
            return L10n.tr("Purchase cancelled.")
        case .verificationFailed:
            return L10n.tr("The App Store transaction could not be verified.")
        case .unavailable:
            return L10n.tr("Purchase information is temporarily unavailable.")
        case .failed(let message):
            return message
        }
    }

    public func recordSuccessfulImport(_ result: ImportResult) {
        guard
            distribution == .macAppStore,
            !accessState.hasLifetimeUnlock,
            accessState.recordSuccessfulImport(result)
        else {
            return
        }
        defaults.set(
            accessState.completedFreeImports,
            forKey: DefaultsKey.completedFreeImports
        )
    }

    public func purchase() async {
        guard distribution == .macAppStore else {
            return
        }
        if product == nil {
            await loadProduct()
        }
        guard let product else {
            if case .failed = accessState.purchaseStatus {
                return
            }
            accessState.apply(.productUnavailable)
            return
        }
        accessState.beginPurchase()
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    accessState.apply(.verificationFailed)
                    return
                }
                guard transaction.productID == AppDistribution.lifetimeProductIdentifier else {
                    accessState.apply(.verificationFailed)
                    return
                }
                applyVerifiedLifetimeEntitlement(restored: false)
                await transaction.finish()
            case .pending:
                accessState.apply(.pending)
            case .userCancelled:
                accessState.apply(.cancelled)
            @unknown default:
                accessState.apply(.failed(L10n.tr("The App Store returned an unknown purchase result.")))
            }
        } catch StoreKitError.userCancelled {
            accessState.apply(.cancelled)
        } catch {
            accessState.apply(.failed(error.localizedDescription))
        }
    }

    public func restorePurchases() async {
        guard distribution == .macAppStore else {
            return
        }
        accessState.beginLoading()
        if await resolveExistingEntitlement(restored: true) {
            return
        }
        guard accessState.purchaseStatus != .verificationFailed else {
            return
        }

        switch await performWithTimeout(storefront.restoreSyncTimeout, operation: storefront.sync) {
        case .success:
            break
        case .cancelled:
            accessState.apply(.cancelled)
            return
        case .failed(let message):
            accessState.apply(.failed(message))
            return
        case .timedOut:
            accessState.apply(.failed(
                L10n.tr("The App Store did not finish restoring purchases. Your purchase is safe; try again.")
            ))
            return
        }

        for attempt in 0..<5 {
            if await resolveExistingEntitlement(restored: true) {
                return
            }
            guard accessState.purchaseStatus != .verificationFailed, attempt < 4 else {
                break
            }
            // AppStore.sync() can complete just before the restored transaction
            // becomes visible to currentEntitlements.
            try? await Task.sleep(for: .milliseconds(100))
        }
        accessState.apply(.failed(L10n.tr("No restorable purchase was found for this App Store account.")))
    }

    public func refreshStoreState() async {
        accessState.beginLoading()
        if !(await resolveExistingEntitlement(restored: false)) {
            guard accessState.purchaseStatus != .verificationFailed else {
                return
            }
        }
        await loadProduct()
    }

    public func startObservingTransactions() {
        guard distribution == .macAppStore, updatesTask == nil else {
            return
        }
        updatesTask = Task { [weak self] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                guard case .verified(let transaction) = verification else {
                    accessState.apply(.verificationFailed)
                    continue
                }
                guard transaction.productID == AppDistribution.lifetimeProductIdentifier else {
                    continue
                }
                if transaction.revocationDate == nil {
                    // The verified update is already authoritative. Re-querying
                    // currentEntitlements here can briefly return the pre-update
                    // snapshot and incorrectly treat a new purchase as revoked.
                    applyVerifiedLifetimeEntitlement(restored: false)
                } else {
                    // A revocation can coexist with another valid transaction, so
                    // resolve the complete entitlement set before locking access.
                    await refreshEntitlement(restored: false)
                }
                await transaction.finish()
            }
        }
        initialStoreRefreshTask = Task { [weak self] in
            await self?.refreshStoreState()
        }
    }

    private func loadProduct() async {
        let productLoader = storefront.loadProduct
        let productIdentifier = AppDistribution.lifetimeProductIdentifier
        let outcome = await performWithTimeout(
            storefront.productLoadTimeout,
            operation: {
                try await productLoader(productIdentifier)
            }
        )
        switch outcome {
        case .success(let snapshot):
            product = snapshot?.product
            productDisplayName = snapshot?.displayName ?? "SD Import Unlimited"
            productDisplayPrice = snapshot?.displayPrice
            isFamilyShareable = snapshot?.isFamilyShareable ?? false
            applyProductAvailability(isAvailable: snapshot != nil)
        case .cancelled:
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.cancelled)
            }
        case .failed(let message):
            isFamilyShareable = false
            applyProductLoadFailure(message)
        case .timedOut:
            isFamilyShareable = false
            applyProductLoadFailure(L10n.tr("Purchase information is taking longer than expected. Try again."))
        }
    }

    @discardableResult
    func refreshEntitlement(restored: Bool, settleWhenMissing: Bool = true) async -> Bool {
        let startingEntitlementRevision = entitlementRevision
        let currentEntitlement = storefront.currentEntitlement
        let productIdentifier = AppDistribution.lifetimeProductIdentifier
        let lookup = await performWithTimeout(
            storefront.entitlementLookupTimeout,
            operation: {
                await currentEntitlement(productIdentifier)
            }
        )
        switch lookup {
        case .success(.entitled):
            applyVerifiedLifetimeEntitlement(restored: restored)
            return true
        case .success(.verificationFailed):
            accessState.apply(.verificationFailed)
        case .success(.notEntitled):
            if accessState.hasLifetimeUnlock, entitlementRevision == startingEntitlementRevision {
                // A refresh can overlap a purchase while StoreKit still exposes
                // its earlier entitlement snapshot. Only revoke the state that
                // this refresh actually began checking.
                entitlementRevision &+= 1
                accessState.apply(.revoked)
            } else if settleWhenMissing, product != nil {
                accessState.apply(.productAvailable)
            }
        case .cancelled:
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.cancelled)
            }
        case .failed(let message):
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.failed(message))
            }
        case .timedOut:
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.failed(
                    L10n.tr("The App Store did not finish checking purchases. Try Restore Purchases.")
                ))
            }
        }
        return false
    }

    private func applyVerifiedLifetimeEntitlement(restored: Bool) {
        entitlementRevision &+= 1
        accessState.apply(restored ? .restored : .purchased)
    }

    private func refreshLatestLifetimeTransaction(restored: Bool) async -> Bool {
        let latestEntitlement = storefront.latestEntitlement
        let productIdentifier = AppDistribution.lifetimeProductIdentifier
        let lookup = await performWithTimeout(
            storefront.entitlementLookupTimeout,
            operation: {
                await latestEntitlement(productIdentifier)
            }
        )
        switch lookup {
        case .success(.entitled):
            applyVerifiedLifetimeEntitlement(restored: restored)
            return true
        case .success(.verificationFailed):
            accessState.apply(.verificationFailed)
        case .success(.notEntitled):
            break
        case .cancelled:
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.cancelled)
            }
        case .failed(let message):
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.failed(message))
            }
        case .timedOut:
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.failed(
                    L10n.tr("The App Store did not finish checking purchases. Try Restore Purchases.")
                ))
            }
        }
        return false
    }

    private func resolveExistingEntitlement(restored: Bool) async -> Bool {
        let hadLifetimeUnlock = accessState.hasLifetimeUnlock
        if await refreshEntitlement(restored: restored, settleWhenMissing: false) {
            return true
        }
        guard accessState.purchaseStatus != .verificationFailed else {
            return false
        }
        // `currentEntitlements` excludes refunded and revoked products. If it
        // just removed an entitlement this manager had already granted, do not
        // let a temporarily stale `latest(for:)` snapshot grant it again.
        if hadLifetimeUnlock, !accessState.hasLifetimeUnlock {
            return false
        }
        return await refreshLatestLifetimeTransaction(restored: restored)
    }

    private func applyProductAvailability(isAvailable: Bool) {
        switch accessState.purchaseStatus {
        case .verificationFailed, .failed, .cancelled, .pending:
            return
        default:
            accessState.apply(
                accessState.hasLifetimeUnlock
                    ? .purchased
                    : (isAvailable ? .productAvailable : .productUnavailable)
            )
        }
    }

    private func applyProductLoadFailure(_ message: String) {
        if accessState.hasLifetimeUnlock {
            accessState.apply(.purchased)
        } else {
            accessState.apply(.failed(message))
        }
    }

    private enum TimedOperationOutcome<Success: Sendable>: Sendable {
        case success(Success)
        case cancelled
        case failed(String)
        case timedOut
    }

    private func performWithTimeout<Success: Sendable>(
        _ timeout: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Success
    ) async -> TimedOperationOutcome<Success> {
        let (stream, continuation) = AsyncStream<TimedOperationOutcome<Success>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let operationTask = Task { @MainActor in
            do {
                continuation.yield(.success(try await operation()))
            } catch StoreKitError.userCancelled {
                continuation.yield(.cancelled)
            } catch is CancellationError {
                // The timeout path owns the visible result.
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
        }
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(.timedOut)
            } catch {
                // Cancellation means the operation completed first.
            }
        }
        var iterator = stream.makeAsyncIterator()
        let outcome = await iterator.next() ?? .failed(L10n.tr("The App Store operation ended unexpectedly."))
        operationTask.cancel()
        timeoutTask.cancel()
        continuation.finish()
        return outcome
    }
}
