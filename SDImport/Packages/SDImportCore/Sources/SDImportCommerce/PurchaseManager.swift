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
    @Published private var activeStoreOperation: StoreOperation?
    @Published private var storeRefreshCount = 0

    private enum StoreOperation {
        case loadingProduct
        case purchasing
        case startingTrial
        case restoring

        var status: ImportPurchaseStatus {
            switch self {
            case .loadingProduct, .restoring: .loading
            case .purchasing: .purchasing
            case .startingTrial: .startingTrial
            }
        }
    }

    private let distribution: AppDistribution
    private let storefront: PurchaseStorefront
    private let nowProvider: @MainActor @Sendable () -> Date
    private var lifetimeProduct: Product?
    private var trialProduct: Product?
    private var updatesTask: Task<Void, Never>?
    private var initialStoreRefreshTask: Task<Void, Never>?
    private var trialExpirationTask: Task<Void, Never>?
    private enum EntitlementProduct: Hashable {
        case lifetime
        case trial

        var identifier: String {
            switch self {
            case .lifetime: AppDistribution.lifetimeProductIdentifier
            case .trial: AppDistribution.trialProductIdentifier
            }
        }
    }

    private struct EntitlementRevisions {
        var requested: UInt64 = 0
        var committed: UInt64 = 0
    }

    private enum EntitlementLookupSource {
        case current(settleWhenMissing: Bool)
        case latest
    }

    private var entitlementRevisions: [EntitlementProduct: EntitlementRevisions] = [:]


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
        activeStoreOperation != nil || storeRefreshCount > 0
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
        switch activeStoreOperation?.status ?? accessState.purchaseStatus {
        case .idle, .available, .purchased:
            return nil
        case .loading:
            return L10n.tr("Loading purchase information…")
        case .purchasing:
            return L10n.tr("Waiting for the App Store to complete your purchase…")
        case .startingTrial:
            return L10n.tr("Waiting for the App Store to activate your free trial…")
        case .pending:
            return L10n.tr("Waiting for App Store approval. Access will unlock after approval.")
        case .cancelled:
            return L10n.tr("App Store request cancelled. You can try again.")
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
        guard distribution == .macAppStore, !isPerformingStoreOperation else { return }
        activeStoreOperation = .loadingProduct
        defer { activeStoreOperation = nil }
        if lifetimeProduct == nil {
            await loadProducts()
        }
        guard let lifetimeProduct else {
            lifetimeProductError = lifetimeProductError
                ?? L10n.tr("Purchase information is temporarily unavailable.")
            return
        }
        activeStoreOperation = .purchasing
        accessState.beginPurchase()
        do {
            switch try await lifetimeProduct.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification,
                      transaction.productID == AppDistribution.lifetimeProductIdentifier else {
                    accessState.apply(.verificationFailed)
                    return
                }
                applyEntitlementDecision(.granted(transaction.purchaseDate), for: .lifetime)
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
        guard distribution == .macAppStore, !hasUsedTrial, !isPerformingStoreOperation else { return }
        activeStoreOperation = .loadingProduct
        defer { activeStoreOperation = nil }
        if trialProduct == nil {
            await loadProducts()
        }
        guard let trialProduct else {
            trialProductError = trialProductError
                ?? L10n.tr("Purchase information is temporarily unavailable.")
            return
        }
        activeStoreOperation = .startingTrial
        accessState.beginTrial()
        do {
            switch try await trialProduct.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification,
                      transaction.productID == AppDistribution.trialProductIdentifier else {
                    accessState.apply(.verificationFailed)
                    return
                }
                applyEntitlementDecision(.granted(transaction.purchaseDate), for: .trial)
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
        guard distribution == .macAppStore, !isPerformingStoreOperation else { return }
        activeStoreOperation = .restoring
        defer { activeStoreOperation = nil }
        accessState.beginLoading()
        let existing = await resolveExistingEntitlements(restored: true)
        if existing.foundLifetime {
            accessState.apply(.restored)
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
            let restored = await resolveExistingEntitlements(restored: true)
            if restored.foundLifetime || restored.foundTrial {
                return
            }
            if restored.verificationFailed { return }
            guard attempt < 4 else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        accessState.apply(.failed(L10n.tr("No restorable purchase was found for this App Store account.")))
    }

    public func refreshStoreState() async {
        guard activeStoreOperation == nil else { return }
        storeRefreshCount += 1
        defer { storeRefreshCount -= 1 }
        accessState.beginLoading()
        _ = await resolveExistingEntitlements(restored: false)
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
                        applyEntitlementDecision(.granted(transaction.purchaseDate), for: .lifetime)
                    } else {
                        await refreshLifetimeEntitlement(restored: false)
                    }
                    await transaction.finish()
                case AppDistribution.trialProductIdentifier:
                    if transaction.revocationDate == nil {
                        applyEntitlementDecision(.granted(transaction.purchaseDate), for: .trial)
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

    enum EntitlementRefreshResult: Equatable {
        case found
        case notFound
        case verificationFailed
        case superseded
    }

    @discardableResult
    func refreshLifetimeEntitlement(restored: Bool) async -> EntitlementRefreshResult {
        await refreshEntitlement(
            .lifetime, from: .current(settleWhenMissing: true), restored: restored,
            revision: nextEntitlementRevision(for: .lifetime)
        )
    }

    @discardableResult
    func refreshTrialEntitlement() async -> EntitlementRefreshResult {
        await refreshEntitlement(
            .trial, from: .current(settleWhenMissing: true), restored: false,
            revision: nextEntitlementRevision(for: .trial)
        )
    }

    private func refreshEntitlement(
        _ product: EntitlementProduct,
        from source: EntitlementLookupSource,
        restored: Bool,
        revision: UInt64
    ) async -> EntitlementRefreshResult {
        guard revision >= entitlementRevisions[product, default: EntitlementRevisions()].committed else {
            return .superseded
        }
        let operation: @MainActor @Sendable (String) async -> StoreEntitlementLookup
        switch source {
        case .current: operation = storefront.currentEntitlement
        case .latest: operation = storefront.latestEntitlement
        }
        let outcome = await performWithTimeout(storefront.entitlementLookupTimeout) {
            await operation(product.identifier)
        }
        guard revision >= entitlementRevisions[product, default: EntitlementRevisions()].committed else {
            return .superseded
        }

        let allowsFailureFeedback = product == .lifetime ? !hasLifetimeUnlock : !canStartImport
        switch outcome {
        case .success(.entitled(let purchaseDate)):
            applyEntitlementDecision(
                .granted(purchaseDate), for: product, restored: restored, revision: revision
            )
            return .found
        case .success(.notEntitled):
            if case .current(let settleWhenMissing) = source {
                let wasEntitled = hasEntitlement(for: product)
                applyEntitlementDecision(.absent, for: product, revision: revision)
                if settleWhenMissing, !wasEntitled, lifetimeProduct != nil || trialProduct != nil {
                    accessState.apply(.productAvailable)
                }
            }
        case .success(.verificationFailed):
            if !hasLifetimeUnlock { accessState.apply(.verificationFailed) }
            return .verificationFailed
        case .cancelled:
            if allowsFailureFeedback { accessState.apply(.cancelled) }
        case .failed(let message):
            if allowsFailureFeedback { accessState.apply(.failed(message)) }
        case .timedOut:
            if allowsFailureFeedback {
                accessState.apply(.failed(
                    L10n.tr("The App Store did not finish checking purchases. Try Restore Purchases.")
                ))
            }
        }
        return .notFound
    }

    private struct EntitlementResolution {
        let foundLifetime: Bool
        let foundTrial: Bool
        let verificationFailed: Bool
    }

    private func resolveExistingEntitlements(restored: Bool) async -> EntitlementResolution {
        let lifetime = await resolveEntitlement(.lifetime, restored: restored)
        let trial = await resolveEntitlement(.trial, restored: restored)
        return EntitlementResolution(
            foundLifetime: hasLifetimeUnlock,
            foundTrial: hasUsedTrial,
            verificationFailed: lifetime == .verificationFailed || trial == .verificationFailed
        )
    }

    private func resolveEntitlement(
        _ product: EntitlementProduct, restored: Bool
    ) async -> EntitlementRefreshResult {
        let wasEntitled = hasEntitlement(for: product)
        let revision = nextEntitlementRevision(for: product)
        let current = await refreshEntitlement(
            product, from: .current(settleWhenMissing: false), restored: restored, revision: revision
        )
        guard current == .notFound, !wasEntitled || hasEntitlement(for: product) else { return current }
        return await refreshEntitlement(product, from: .latest, restored: restored, revision: revision)
    }

    private func hasEntitlement(for product: EntitlementProduct) -> Bool {
        switch product {
        case .lifetime: hasLifetimeUnlock
        case .trial: hasUsedTrial
        }
    }

    private func nextEntitlementRevision(for product: EntitlementProduct) -> UInt64 {
        entitlementRevisions[product, default: EntitlementRevisions()].requested &+= 1
        return entitlementRevisions[product, default: EntitlementRevisions()].requested
    }

    private enum VerifiedEntitlementDecision {
        case granted(Date)
        case absent
    }

    // Only verified grants and authoritative absence advance the committed revision.
    private func applyEntitlementDecision(
        _ decision: VerifiedEntitlementDecision,
        for product: EntitlementProduct,
        restored: Bool = false,
        revision: UInt64? = nil
    ) {
        let committed = revision ?? nextEntitlementRevision(for: product)
        entitlementRevisions[product, default: EntitlementRevisions()].committed = committed
        switch (product, decision) {
        case (.lifetime, .granted):
            accessState.apply(restored ? .restored : .purchased)
        case (.trial, .granted(let purchaseDate)):
            accessState.apply(.trialStarted(purchaseDate))
            scheduleTrialExpiration()
        case (.lifetime, .absent):
            if hasLifetimeUnlock { accessState.apply(.revoked) }
        case (.trial, .absent):
            if hasUsedTrial {
                accessState.apply(.trialRevoked)
                scheduleTrialExpiration()
            }
        }
    }

    private func scheduleTrialExpiration() {
        trialExpirationTask?.cancel()
        guard let endDate = accessState.trialEndDate else { return }
        let delay = endDate.timeIntervalSince(nowProvider())
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
