import Foundation
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: ObservableObject {
    private let updaterController: SPUStandardUpdaterController?

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            updater?.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    init(bundle: Bundle = .main) {
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
    }

    var updater: SPUUpdater? {
        updaterController?.updater
    }

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
}

struct CheckForUpdatesView: View {
    private let updater: SPUUpdater?

    init(updater: SPUUpdater?) {
        self.updater = updater
    }

    var body: some View {
        if let updater {
            EnabledCheckForUpdatesView(updater: updater)
        } else {
            Button("Check for Updates...") {}
                .disabled(true)
        }
    }
}

private struct EnabledCheckForUpdatesView: View {
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var body: some View {
        Button("Check for Updates...", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
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
            if appUpdater.updater != nil {
                Toggle(
                    "Automatically check for updates",
                    isOn: $appUpdater.automaticallyChecksForUpdates
                )

                Toggle(
                    "Automatically download updates",
                    isOn: $appUpdater.automaticallyDownloadsUpdates
                )
                .disabled(!appUpdater.automaticallyChecksForUpdates)
            } else {
                Text("Updates are not configured for this build.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, leadingInset)
    }
}
