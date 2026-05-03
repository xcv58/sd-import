import AppKit
import Foundation
import SDImportCore

@main
@MainActor
struct SDImportAgent {
    private static var delegate: AgentDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AgentDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
private final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let detector = VolumeDetector()
    private var debouncer = MountDebouncer()
    private var token: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mountURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
                return
            }
            Task { @MainActor in
                self?.handleMountURL(mountURL)
            }
        }
    }

    private func handleMountURL(_ mountURL: URL) {
        let volume = detector.mountedVolume(from: mountURL)
        guard detector.isLikelyImportVolume(volume) else {
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard VolumeDetector().containsImportableMedia(at: mountURL) else {
                return
            }
            await MainActor.run {
                self?.handleImportableVolume(volume)
            }
        }
    }

    private func handleImportableVolume(_ volume: MountedVolume) {
        guard debouncer.shouldAccept(volume) else {
            return
        }
        guard isMainAppRunning else {
            launchMainApp()
            post(volume)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [volume] in
                self.post(volume)
            }
            return
        }

        post(volume)
    }

    private var isMainAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.xcv58.SDImport").isEmpty
    }

    private func launchMainApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.xcv58.SDImport") else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private func post(_ volume: MountedVolume) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(MountHandoff.notificationName),
            object: nil,
            userInfo: [
                MountHandoff.pathKey: volume.mountURL.path,
                MountHandoff.nameKey: volume.name
            ],
            deliverImmediately: true
        )
    }
}
