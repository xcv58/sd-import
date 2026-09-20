import SDImportCore
import SDImportCommerce
import SwiftUI

struct PurchaseView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var purchaseManager: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 38))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 6) {
                Text(titleText)
                    .font(.title2.bold())
                Text(subtitleText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(purchaseManager.allowanceSummary, systemImage: "checkmark.circle")

            if purchaseManager.isFamilyShareable {
                Label(L10n.tr("Shareable with Family Sharing"), systemImage: "person.3")
            }

            if !purchaseManager.hasUsedTrial {
                Text(L10n.tr("Start a 14-day trial with unlimited imports. When it ends, importing is locked until you buy lifetime access. The trial does not renew and you will not be charged automatically."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = purchaseManager.statusMessage {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                if !purchaseManager.hasUsedTrial {
                    Button(L10n.tr("Start 14-Day Free Trial")) {
                        Task {
                            if !purchaseManager.isTrialProductAvailable {
                                await purchaseManager.refreshStoreState()
                            }
                            if purchaseManager.isTrialProductAvailable {
                                await purchaseManager.startTrial()
                            }
                            if purchaseManager.hasActiveTrial {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(purchaseManager.isPerformingStoreOperation)
                    .frame(maxWidth: .infinity)

                    if let error = purchaseManager.trialProductError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button(purchaseButtonTitle) {
                    Task {
                        if purchaseManager.productDisplayPrice == nil {
                            await purchaseManager.refreshStoreState()
                        } else {
                            await purchaseManager.purchase()
                        }
                        if purchaseManager.hasLifetimeUnlock {
                            dismiss()
                        }
                    }
                }
                .disabled(purchaseManager.isPerformingStoreOperation)
                .frame(maxWidth: .infinity)

                if let error = purchaseManager.lifetimeProductError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button(L10n.tr("Not Now")) {
                    dismiss()
                }

                Spacer()

                Button(L10n.tr("Restore Purchases")) {
                    Task {
                        await purchaseManager.restorePurchases()
                        if purchaseManager.canStartImport {
                            dismiss()
                        }
                    }
                }
                .disabled(purchaseManager.isPerformingStoreOperation)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private var purchaseButtonTitle: String {
        if let price = purchaseManager.productDisplayPrice {
            return L10n.tr("Buy Lifetime for \(price)")
        }
        return purchaseManager.isPerformingStoreOperation ? L10n.tr("Loading…") : L10n.tr("Try Again")
    }

    private var titleText: String {
        purchaseManager.hasUsedTrial
            ? L10n.tr("Unlock Unlimited Imports")
            : L10n.tr("Try SD Card Import free for 14 days")
    }

    private var subtitleText: String {
        purchaseManager.hasUsedTrial
            ? L10n.tr("Keep previewing every card for free. A one-time purchase unlocks unlimited completed imports.")
            : L10n.tr("Keep previewing every card for free. Start a trial or make a one-time purchase for unlimited completed imports.")
    }
}
