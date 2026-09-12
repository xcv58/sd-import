import Foundation
import SDImportCore
#if SDIMPORT_DIRECT
import Sparkle
#endif
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
#if SDIMPORT_DIRECT
    private let updaterController: SPUStandardUpdaterController?
#endif

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
#if SDIMPORT_DIRECT
            updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
#endif
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
#if SDIMPORT_DIRECT
            updater?.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
#endif
        }
    }

    init(bundle: Bundle = .main) {
#if SDIMPORT_DIRECT
        let controller: SPUStandardUpdaterController?
        if Self.isConfigured(in: bundle) {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            controller = nil
        }

        updaterController = controller
        automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
        automaticallyDownloadsUpdates = controller?.updater.automaticallyDownloadsUpdates ?? false
#else
        automaticallyChecksForUpdates = false
        automaticallyDownloadsUpdates = false
#endif
    }

#if SDIMPORT_DIRECT
    var updater: SPUUpdater? {
        updaterController?.updater
    }
#endif

    var isAvailable: Bool {
#if SDIMPORT_DIRECT
        updater != nil
#else
        false
#endif
    }

    var canCheckForUpdates: Bool {
#if SDIMPORT_DIRECT
        updater?.canCheckForUpdates ?? false
#else
        false
#endif
    }

    func checkForUpdates() {
#if SDIMPORT_DIRECT
        updater?.checkForUpdates()
#endif
    }

#if SDIMPORT_DIRECT
    private static func isConfigured(in bundle: Bundle) -> Bool {
        guard
            let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        let trimmedPublicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: feedURL)?.scheme == "https" && Data(base64Encoded: trimmedPublicKey) != nil
    }
#endif
}

struct CheckForUpdatesView: View {
    @ObservedObject private var updater: AppUpdater

    init(updater: AppUpdater) {
        self.updater = updater
    }

    var body: some View {
        if updater.isAvailable {
            Button(L10n.tr("Check for Updates..."), action: updater.checkForUpdates)
                .disabled(!updater.canCheckForUpdates)
        } else {
            Button(L10n.tr("Check for Updates...")) {}
                .disabled(true)
        }
    }
}

struct UpdaterSettingsView: View {
    @ObservedObject private var appUpdater: AppUpdater
    private let leadingInset: CGFloat

    init(appUpdater: AppUpdater, leadingInset: CGFloat = 0) {
        self.appUpdater = appUpdater
        self.leadingInset = leadingInset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appUpdater.isAvailable {
                Toggle(
                    L10n.tr("Automatically check for updates"),
                    isOn: $appUpdater.automaticallyChecksForUpdates
                )

                Toggle(
                    L10n.tr("Automatically download updates"),
                    isOn: $appUpdater.automaticallyDownloadsUpdates
                )
                .disabled(!appUpdater.automaticallyChecksForUpdates)
            } else {
                Text(
                    AppDistribution.current == .macAppStore
                        ? L10n.tr("Updates are delivered by the App Store.")
                        : L10n.tr("Updates are not configured for this build.")
                )
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, leadingInset)
    }
}
