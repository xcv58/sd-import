import Foundation
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater {
    private let updaterController: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        guard Self.isConfigured(in: bundle) else {
            updaterController = nil
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
    private let updater: SPUUpdater?
    private let leadingInset: CGFloat

    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool

    init(updater: SPUUpdater?, leadingInset: CGFloat = 0) {
        self.updater = updater
        self.leadingInset = leadingInset
        self.automaticallyChecksForUpdates = updater?.automaticallyChecksForUpdates ?? false
        self.automaticallyDownloadsUpdates = updater?.automaticallyDownloadsUpdates ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let updater {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    .onChange(of: automaticallyChecksForUpdates) {
                        updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
                    }

                Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                    .disabled(!automaticallyChecksForUpdates)
                    .onChange(of: automaticallyDownloadsUpdates) {
                        updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
                    }
            } else {
                Text("Updates are not configured for this build.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, leadingInset)
    }
}
