import Combine
import Foundation
import SDImportCore
import StoreKit

enum StoreEntitlementLookup: Sendable {
    case entitled(purchaseDate: Date)
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
            var purchaseDate: Date?
            var encounteredVerificationFailure = false
            for await verification in Transaction.currentEntitlements {
                switch verification {
                case .verified(let transaction):
                    if transaction.productID == identifier, transaction.revocationDate == nil {
                        purchaseDate = transaction.purchaseDate
                    }
                case .unverified(let transaction, _):
                    if transaction.productID == identifier {
                        encounteredVerificationFailure = true
                    }
                }
            }
            if let purchaseDate {
                return .entitled(purchaseDate: purchaseDate)
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
            return .entitled(purchaseDate: transaction.purchaseDate)
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
    @Published public private(set) var accessState = ImportAccessState()
    @Published public var isShowingPurchase = false
    @Published public private(set) var productDisplayName = "SD Import Unlimited"
    @Published public private(set) var productDisplayPrice: String?
    @Published public private(set) var isFamilyShareable = false
    @Published public private(set) var isTrialProductAvailable = false
    @Published public private(set) var lifetimeProductError: String?
    @Published public private(set) var trialProductError: String?

    private let distribution: AppDistribution
    private let storefront: PurchaseStorefront
    private let nowProvider: @MainActor @Sendable () -> Date
    private var lifetimeProduct: Product?
    private var trialProduct: Product?
    private var updatesTask: Task<Void, Never>?
    private var initialStoreRefreshTask: Task<Void, Never>?
    private var trialExpirationTask: Task<Void, Never>?
    private var lifetimeEntitlementRevision: UInt64 = 0
    private var trialEntitlementRevision: UInt64 = 0

    public convenience init(
        defaults: UserDefaults = .standard,
        distribution: AppDistribution = .current,
        startsStoreTask: Bool = true
    ) {
        self.init(
            defaults: defaults,
            distribution: distribution,
            startsStoreTask: startsStoreTask,
            storefront: .live,
            nowProvider: Date.init
        )
    }

    init(
        defaults: UserDefaults,
        distribution: AppDistribution,
        startsStoreTask: Bool,
        storefront: PurchaseStorefront,
        nowProvider: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        // Trial state comes exclusively from verified StoreKit transactions.
        // Keep this argument source-compatible with existing callers.
        _ = defaults
        self.distribution = distribution
        self.storefront = storefront
        self.nowProvider = nowProvider
        let isHostedTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if distribution == .macAppStore, startsStoreTask, !isHostedTest {
            startObservingTransactions()
        }
    }

    deinit {
        updatesTask?.cancel()
        initialStoreRefreshTask?.cancel()
        trialExpirationTask?.cancel()
    }

    public var isMacAppStoreEdition: Bool {
        distribution == .macAppStore
    }

    public var canStartImport: Bool {
        accessState.canStartImport(distribution: distribution, at: nowProvider())
    }

    public var hasLifetimeUnlock: Bool {
        accessState.hasLifetimeUnlock
    }

    public var hasActiveTrial: Bool {
        accessState.isTrialActive(at: nowProvider())
    }

    public var hasUsedTrial: Bool {
        accessState.trialStartDate != nil
    }

    public var trialEndDate: Date? {
        accessState.trialEndDate
    }

    public var isPerformingStoreOperation: Bool {
        switch accessState.purchaseStatus {
        case .loading, .purchasing, .startingTrial:
            true
        default:
            false
        }
    }

    public var allowanceSummary: String {
        if accessState.hasLifetimeUnlock {
            return L10n.tr("Lifetime access unlocked")
        }
        if let trialEndDate = accessState.trialEndDate {
            if accessState.isTrialActive(at: nowProvider()) {
                let formatter = DateFormatter()
                formatter.locale = L10n.presentationLocale
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return L10n.tr("Trial active until \(formatter.string(from: trialEndDate))")
            }
            return L10n.tr("Your 14-day trial has ended")
        }
        return L10n.tr("14-day trial available")
    }

    public var statusMessage: String? {
        switch accessState.purchaseStatus {
        case .idle, .available, .purchased:
            return nil
        case .loading:
            return L10n.tr("Loading purchase information…")
        case .purchasing:
            return L10n.tr("Completing purchase…")
        case .startingTrial:
            return L10n.tr("Starting trial…")
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

    public func interfaceLanguageDidChange(from previous: AppLanguage, to selected: AppLanguage) {
        guard case .failed(let message) = accessState.purchaseStatus else { return }
        let localized = L10n.relocalizedStaticMessage(message, from: previous, to: selected)
        if localized != message {
            accessState.apply(.failed(localized))
        }
    }

    public func purchase() async {
        guard distribution == .macAppStore else { return }
        if lifetimeProduct == nil {
            await loadProducts()
        }
        guard let lifetimeProduct else {
            lifetimeProductError = lifetimeProductError
                ?? L10n.tr("Purchase information is temporarily unavailable.")
            return
        }
        accessState.beginPurchase()
        do {
            switch try await lifetimeProduct.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification,
                      transaction.productID == AppDistribution.lifetimeProductIdentifier else {
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

    public func startTrial() async {
        guard distribution == .macAppStore, !hasUsedTrial else { return }
        if trialProduct == nil {
            await loadProducts()
        }
        guard let trialProduct else {
            trialProductError = trialProductError
                ?? L10n.tr("Purchase information is temporarily unavailable.")
            return
        }
        accessState.beginTrial()
        do {
            switch try await trialProduct.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification,
                      transaction.productID == AppDistribution.trialProductIdentifier else {
                    accessState.apply(.verificationFailed)
                    return
                }
                applyVerifiedTrialEntitlement(purchaseDate: transaction.purchaseDate)
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
        guard distribution == .macAppStore else { return }
        accessState.beginLoading()
        let existing = await resolveExistingEntitlements(restored: true)
        if existing.foundLifetime {
            return
        }
        guard accessState.purchaseStatus != .verificationFailed || existing.foundTrial else { return }

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
            let restored = await resolveExistingEntitlements(restored: true)
            if restored.foundLifetime || restored.foundTrial {
                return
            }
            guard accessState.purchaseStatus != .verificationFailed, attempt < 4 else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        accessState.apply(.failed(L10n.tr("No restorable purchase was found for this App Store account.")))
    }

    public func refreshStoreState() async {
        accessState.beginLoading()
        _ = await resolveExistingEntitlements(restored: false)
        guard accessState.purchaseStatus != .verificationFailed else { return }
        await loadProducts()
    }

    public func startObservingTransactions() {
        guard distribution == .macAppStore, updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled, let self else { return }
                guard case .verified(let transaction) = verification else {
                    accessState.apply(.verificationFailed)
                    continue
                }
                switch transaction.productID {
                case AppDistribution.lifetimeProductIdentifier:
                    if transaction.revocationDate == nil {
                        applyVerifiedLifetimeEntitlement(restored: false)
                    } else {
                        await refreshLifetimeEntitlement(restored: false)
                    }
                    await transaction.finish()
                case AppDistribution.trialProductIdentifier:
                    if transaction.revocationDate == nil {
                        applyVerifiedTrialEntitlement(purchaseDate: transaction.purchaseDate)
                    } else {
                        await refreshTrialEntitlement()
                    }
                    await transaction.finish()
                default:
                    continue
                }
            }
        }
        initialStoreRefreshTask = Task { [weak self] in
            await self?.refreshStoreState()
        }
    }

    private func loadProducts() async {
        let productLoader = storefront.loadProduct
        async let lifetimeOutcome = performWithTimeout(storefront.productLoadTimeout) {
            try await productLoader(AppDistribution.lifetimeProductIdentifier)
        }
        async let trialOutcome = performWithTimeout(storefront.productLoadTimeout) {
            try await productLoader(AppDistribution.trialProductIdentifier)
        }
        let (lifetime, trial) = await (lifetimeOutcome, trialOutcome)

        lifetimeProductError = nil
        trialProductError = nil
        var anyAvailable = false
        var failureMessage: String?
        var timedOut = false

        switch lifetime {
        case .success(let snapshot):
            lifetimeProduct = snapshot?.product
            productDisplayName = snapshot?.displayName ?? "SD Import Unlimited"
            productDisplayPrice = snapshot?.displayPrice
            isFamilyShareable = snapshot?.isFamilyShareable ?? false
            anyAvailable = snapshot != nil
            if snapshot == nil {
                lifetimeProductError = L10n.tr("Purchase information is temporarily unavailable.")
            }
        case .cancelled:
            break
        case .failed(let message):
            lifetimeProduct = nil
            productDisplayPrice = nil
            isFamilyShareable = false
            lifetimeProductError = message
            failureMessage = message
        case .timedOut:
            lifetimeProduct = nil
            productDisplayPrice = nil
            isFamilyShareable = false
            lifetimeProductError = L10n.tr("Purchase information is taking longer than expected. Try again.")
            timedOut = true
        }

        switch trial {
        case .success(let snapshot):
            trialProduct = snapshot?.product
            isTrialProductAvailable = snapshot != nil
            anyAvailable = anyAvailable || snapshot != nil
            if snapshot == nil {
                trialProductError = L10n.tr("Purchase information is temporarily unavailable.")
            }
        case .cancelled:
            break
        case .failed(let message):
            trialProduct = nil
            isTrialProductAvailable = false
            trialProductError = message
            failureMessage = failureMessage ?? message
        case .timedOut:
            trialProduct = nil
            isTrialProductAvailable = false
            trialProductError = L10n.tr("Purchase information is taking longer than expected. Try again.")
            timedOut = true
        }

        if anyAvailable {
            applyProductAvailability(isAvailable: true)
        } else if let failureMessage {
            applyProductLoadFailure(failureMessage)
        } else if timedOut {
            applyProductLoadFailure(L10n.tr("Purchase information is taking longer than expected. Try again."))
        } else {
            applyProductAvailability(isAvailable: false)
        }
    }

    @discardableResult
    func refreshLifetimeEntitlement(
        restored: Bool,
        settleWhenMissing: Bool = true
    ) async -> EntitlementRefreshResult {
        let startingRevision = lifetimeEntitlementRevision
        let lookup = await entitlementLookup(
            storefront.currentEntitlement,
            productIdentifier: AppDistribution.lifetimeProductIdentifier
        )
        switch lookup {
        case .success(.entitled):
            applyVerifiedLifetimeEntitlement(restored: restored)
            return .found
        case .success(.verificationFailed):
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.verificationFailed)
            }
            return .verificationFailed
        case .success(.notEntitled):
            if accessState.hasLifetimeUnlock, lifetimeEntitlementRevision == startingRevision {
                lifetimeEntitlementRevision &+= 1
                accessState.apply(.revoked)
            } else if settleWhenMissing, lifetimeProduct != nil || trialProduct != nil {
                accessState.apply(.productAvailable)
            }
        case .cancelled:
            if !accessState.hasLifetimeUnlock { accessState.apply(.cancelled) }
        case .failed(let message):
            if !accessState.hasLifetimeUnlock { accessState.apply(.failed(message)) }
        case .timedOut:
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.failed(
                    L10n.tr("The App Store did not finish checking purchases. Try Restore Purchases.")
                ))
            }
        }
        return .notFound
    }

    @discardableResult
    private func refreshTrialEntitlement(
        settleWhenMissing: Bool = true
    ) async -> EntitlementRefreshResult {
        let startingRevision = trialEntitlementRevision
        let lookup = await entitlementLookup(
            storefront.currentEntitlement,
            productIdentifier: AppDistribution.trialProductIdentifier
        )
        switch lookup {
        case .success(.entitled(let purchaseDate)):
            applyVerifiedTrialEntitlement(purchaseDate: purchaseDate)
            return .found
        case .success(.verificationFailed):
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.verificationFailed)
            }
            return .verificationFailed
        case .success(.notEntitled):
            if accessState.trialStartDate != nil, trialEntitlementRevision == startingRevision {
                trialEntitlementRevision &+= 1
                accessState.apply(.trialRevoked)
                scheduleTrialExpiration()
            } else if settleWhenMissing, lifetimeProduct != nil || trialProduct != nil {
                accessState.apply(.productAvailable)
            }
        case .cancelled:
            if !canStartImport { accessState.apply(.cancelled) }
        case .failed(let message):
            if !canStartImport { accessState.apply(.failed(message)) }
        case .timedOut:
            if !canStartImport {
                accessState.apply(.failed(
                    L10n.tr("The App Store did not finish checking purchases. Try Restore Purchases.")
                ))
            }
        }
        return .notFound
    }

    private func refreshLatestLifetimeTransaction(restored: Bool) async -> EntitlementRefreshResult {
        let lookup = await entitlementLookup(
            storefront.latestEntitlement,
            productIdentifier: AppDistribution.lifetimeProductIdentifier
        )
        switch lookup {
        case .success(.entitled):
            applyVerifiedLifetimeEntitlement(restored: restored)
            return .found
        case .success(.verificationFailed):
            accessState.apply(.verificationFailed)
            return .verificationFailed
        case .success(.notEntitled):
            break
        case .cancelled:
            if !accessState.hasLifetimeUnlock { accessState.apply(.cancelled) }
        case .failed(let message):
            if !accessState.hasLifetimeUnlock { accessState.apply(.failed(message)) }
        case .timedOut:
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.failed(
                    L10n.tr("The App Store did not finish checking purchases. Try Restore Purchases.")
                ))
            }
        }
        return .notFound
    }

    private func refreshLatestTrialTransaction() async -> EntitlementRefreshResult {
        let lookup = await entitlementLookup(
            storefront.latestEntitlement,
            productIdentifier: AppDistribution.trialProductIdentifier
        )
        switch lookup {
        case .success(.entitled(let purchaseDate)):
            applyVerifiedTrialEntitlement(purchaseDate: purchaseDate)
            return .found
        case .success(.verificationFailed):
            if !accessState.hasLifetimeUnlock {
                accessState.apply(.verificationFailed)
            }
            return .verificationFailed
        case .success(.notEntitled):
            break
        case .cancelled:
            if !canStartImport { accessState.apply(.cancelled) }
        case .failed(let message):
            if !canStartImport { accessState.apply(.failed(message)) }
        case .timedOut:
            if !canStartImport {
                accessState.apply(.failed(
                    L10n.tr("The App Store did not finish checking purchases. Try Restore Purchases.")
                ))
            }
        }
        return .notFound
    }

    enum EntitlementRefreshResult: Equatable {
        case found
        case notFound
        case verificationFailed
    }

    private struct EntitlementResolution {
        let foundLifetime: Bool
        let foundTrial: Bool
    }

    private func resolveExistingEntitlements(restored: Bool) async -> EntitlementResolution {
        let hadLifetimeUnlock = accessState.hasLifetimeUnlock
        let currentLifetime = await refreshLifetimeEntitlement(
            restored: restored,
            settleWhenMissing: false
        )
        var foundLifetime = currentLifetime == .found
        if !foundLifetime,
           currentLifetime != .verificationFailed,
           !(hadLifetimeUnlock && !accessState.hasLifetimeUnlock) {
            foundLifetime = await refreshLatestLifetimeTransaction(restored: restored) == .found
        }

        let hadTrial = accessState.trialStartDate != nil
        let currentTrial = await refreshTrialEntitlement(settleWhenMissing: false)
        var foundTrial = currentTrial == .found
        if !foundTrial,
           currentTrial != .verificationFailed,
           !(hadTrial && accessState.trialStartDate == nil) {
            foundTrial = await refreshLatestTrialTransaction() == .found
        }
        return EntitlementResolution(foundLifetime: foundLifetime, foundTrial: foundTrial)
    }

    private func entitlementLookup(
        _ lookup: @escaping @MainActor @Sendable (String) async -> StoreEntitlementLookup,
        productIdentifier: String
    ) async -> TimedOperationOutcome<StoreEntitlementLookup> {
        await performWithTimeout(storefront.entitlementLookupTimeout) {
            await lookup(productIdentifier)
        }
    }

    private func applyVerifiedLifetimeEntitlement(restored: Bool) {
        lifetimeEntitlementRevision &+= 1
        accessState.apply(restored ? .restored : .purchased)
    }

    private func applyVerifiedTrialEntitlement(purchaseDate: Date) {
        trialEntitlementRevision &+= 1
        accessState.apply(.trialStarted(purchaseDate))
        scheduleTrialExpiration()
    }

    private func scheduleTrialExpiration() {
        trialExpirationTask?.cancel()
        guard let endDate = accessState.trialEndDate else { return }
        let delay = endDate.timeIntervalSinceNow
        guard delay > 0 else {
            objectWillChange.send()
            return
        }
        trialExpirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                self?.objectWillChange.send()
            } catch {
                // A refreshed or revoked entitlement replaces this timer.
            }
        }
    }

    private func applyProductAvailability(isAvailable: Bool) {
        switch accessState.purchaseStatus {
        case .verificationFailed, .failed, .cancelled, .pending:
            return
        default:
            accessState.apply(
                accessState.hasLifetimeUnlock
                    ? .purchased
                    : (isAvailable || hasActiveTrial ? .productAvailable : .productUnavailable)
            )
        }
    }

    private func applyProductLoadFailure(_ message: String) {
        if accessState.hasLifetimeUnlock {
            accessState.apply(.purchased)
        } else if hasActiveTrial {
            accessState.apply(.productAvailable)
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
