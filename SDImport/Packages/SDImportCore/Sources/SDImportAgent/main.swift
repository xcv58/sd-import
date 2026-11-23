import AppKit
import Foundation
import OSLog
import SDImportCore

private let agentLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.xcv58.SDImport.Agent",
    category: "BackgroundPrompt"
)

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
    private static var mainBundleIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "SDImportMainBundleIdentifier") as? String
            ?? "com.xcv58.SDImport"
    }

    private let detector = VolumeDetector()
    private let mountPrivacyPolicy = AppDistribution.current.mountPrivacyPolicy
    private var token: NSObjectProtocol?
    private var unmountToken: NSObjectProtocol?
    private var mediaProbes: [String: (id: UUID, volume: MountedVolume)] = [:]
    private lazy var coldLaunchRetry = BackgroundPromptColdLaunchRetry(
        findApplication: { appURL in
            let runningApplications = NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.mainBundleIdentifier
            )
            guard let app = Self.mainApplication(at: appURL, among: runningApplications) else { return nil }
            return .init(isFinishedLaunching: app.isFinishedLaunching) {
                let requested = app.activate(options: [.activateAllWindows])
                agentLogger.info("Requested activation for unfinished main app launch: \(requested)")
            }
        },
        currentVolume: { [detector] mountURL in
            detector.currentMountedVolume(from: mountURL, includeCapacity: false)
        },
        isAuthorized: { [weak self] in
            guard let self else { return false }
            return (try? BackgroundPromptAgentStateStore.defaultStore().isAuthorized(
                agentBuild: self.agentBuild,
                agentBundlePath: self.agentBundlePath
            )) == true
        }
    )

    private var agentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    private var agentBundlePath: String {
        Bundle.main.bundleURL.standardizedFileURL.path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try BackgroundPromptAgentStateStore.defaultStore().recordLaunch(
                agentBuild: agentBuild,
                agentBundlePath: agentBundlePath
            )
        } catch {
            agentLogger.error("Could not record background helper launch")
        }

        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mountURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
                return
            }
            // Both callbacks run on .main. Handle them in delivery order.
            MainActor.assumeIsolated {
                self?.handleMountURL(mountURL)
            }
        }

        unmountToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mountURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
                return
            }
            MainActor.assumeIsolated {
                self?.handleUnmountURL(mountURL)
            }
        }
#if DEBUG
        if
            let mountURL = BackgroundPromptRuntimeQA.injectedMountURL(),
            let mountedVolume = detector.currentMountedVolume(from: mountURL, includeCapacity: false),
            let appURL = containingMainApplicationURL
        {
            do {
                try BackgroundPromptRuntimeQA.markHelperLifecycleActive(
                    targetApplicationURL: appURL
                )
            } catch {
                try? BackgroundPromptAgentStateStore.defaultStore().recordError(
                    agentBuild: agentBuild,
                    agentBundlePath: agentBundlePath,
                    message: "Could not mark the helper runtime QA lifecycle as active"
                )
                agentLogger.error("Could not mark the helper runtime QA lifecycle as active")
                return
            }
            handleImportableVolume(
                BackgroundPromptRuntimeQA.injectedPostDetectionVolume(at: mountURL),
                activationVolume: mountedVolume
            )
        }
#endif
    }

    private func handleUnmountURL(_ mountURL: URL) {
        let path = mountURL.standardizedFileURL.path
        let current = detector.currentMountedVolume(from: mountURL, includeCapacity: false)
        if let probe = mediaProbes[path], current?.hasVerifiedMediaContinuity(with: probe.volume) != true {
            mediaProbes.removeValue(forKey: path)
        }
        coldLaunchRetry.removeVolume(at: mountURL, preserving: current)
    }

    private func handleMountURL(_ mountURL: URL) {
        mediaProbes.removeValue(forKey: mountURL.standardizedFileURL.path)
        coldLaunchRetry.removeVolume(at: mountURL)
        let volume = detector.mountedVolume(
            from: mountURL,
            includeCapacity: mountPrivacyPolicy.includesCapacityBeforeConsent
        )
        guard detector.isLikelyImportVolume(volume) else {
            return
        }
        if !mountPrivacyPolicy.probesMediaBeforeConsent {
            handleImportableVolume(volume)
            return
        }
        let probeID = UUID()
        mediaProbes[volume.mountPath] = (probeID, volume)
        Task.detached(priority: .utility) { [weak self] in
            let containsMedia = VolumeDetector().containsImportableMedia(at: mountURL)
            await MainActor.run {
                self?.completeMediaProbe(probeID, volume: volume, containsMedia: containsMedia)
            }
        }
    }

    private func completeMediaProbe(_ probeID: UUID, volume: MountedVolume, containsMedia: Bool) {
        guard mediaProbes[volume.mountPath]?.id == probeID else { return }
        mediaProbes.removeValue(forKey: volume.mountPath)
        guard containsMedia,
              let current = MountHandoffProbeCompletionValidator.currentVolumeForDelivery(
                event: nil,
                observedVolume: volume,
                detectCurrentVolume: { detector.currentMountedVolume(from: volume.mountURL) }
              ) else { return }
        handleImportableVolume(current)
    }

    private func handleImportableVolume(_ volume: MountedVolume, activationVolume: MountedVolume? = nil) {
        guard let appURL = containingMainApplicationURL else {
            try? BackgroundPromptAgentStateStore.defaultStore().recordError(
                agentBuild: agentBuild,
                agentBundlePath: agentBundlePath,
                message: "Could not locate the containing SD Import application"
            )
            agentLogger.error("Could not locate the containing SD Import application")
            return
        }

        guard
            let stateStore = try? BackgroundPromptAgentStateStore.defaultStore(),
            let eventSequence = try? stateStore.issueEventSequence(
                agentBuild: agentBuild,
                agentBundlePath: agentBundlePath
            )
        else {
            agentLogger.error("Ignoring mount event from a stale or unavailable background helper")
            return
        }
        let event: MountHandoffEvent?
        do {
            event = try MountHandoffOccurrenceRecorder(
                store: MountHandoffStore.defaultStore()
            ).persistBackgroundAgentOccurrence(
                volume: volume,
                agentBuild: agentBuild,
                agentSequence: eventSequence,
                targetApplicationPath: appURL.path
            )
        } catch {
            event = nil
            try? BackgroundPromptAgentStateStore.defaultStore().recordError(
                agentBuild: agentBuild,
                agentBundlePath: agentBundlePath,
                message: "Could not persist a mounted-card event",
                eventSequence: eventSequence
            )
            agentLogger.error("Could not persist mounted-card handoff")
        }
        if event != nil {
            do {
                try BackgroundPromptAgentStateStore.defaultStore().recordHandoff(
                    agentBuild: agentBuild,
                    agentBundlePath: agentBundlePath,
                    eventSequence: eventSequence
                )
            } catch {
                agentLogger.error("Could not record background helper activity")
            }
        }

        activateOrLaunchMainApp(
            at: appURL,
            eventSequence: eventSequence,
            pendingVolume: event == nil ? nil : (activationVolume ?? volume)
        )
        if mountPrivacyPolicy.usesDistributedNotificationHandoff {
            post(volume, eventID: event?.id, targetApplicationPath: appURL.path)
        }
    }

    private func activateOrLaunchMainApp(
        at appURL: URL,
        eventSequence: UInt64,
        pendingVolume: MountedVolume?
    ) {
        let currentAgentBuild = agentBuild
        let currentAgentBundlePath = agentBundlePath
        let standardizedAppURL = appURL.standardizedFileURL
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.mainBundleIdentifier
        )
        let runningApp = Self.mainApplication(at: standardizedAppURL, among: runningApplications)
        if let pendingVolume, runningApp?.isFinishedLaunching != true {
            coldLaunchRetry.track(pendingVolume, at: standardizedAppURL, startsNewLaunch: runningApp == nil)
        }
        if let runningApp {
            runningApp.activate(options: [.activateAllWindows])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = !runningApplications.isEmpty
#if DEBUG
        if BackgroundPromptRuntimeQA.injectedMountURL() != nil {
            configuration.arguments = [
                BackgroundPromptRuntimeQA.consumeHandoffArgument,
                "-ApplePersistenceIgnoreState",
                "YES",
            ]
        }
#endif
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if error != nil {
                try? BackgroundPromptAgentStateStore.defaultStore().recordError(
                    agentBuild: currentAgentBuild,
                    agentBundlePath: currentAgentBundlePath,
                    message: "Could not launch the containing SD Import application",
                    eventSequence: eventSequence
                )
                agentLogger.error("Could not launch the containing SD Import application")
            }
        }
    }

    private static func mainApplication(
        at appURL: URL,
        among runningApplications: [NSRunningApplication]
    ) -> NSRunningApplication? {
        runningApplications.first { $0.bundleURL?.standardizedFileURL == appURL }
    }

    private func post(
        _ volume: MountedVolume,
        eventID: UUID?,
        targetApplicationPath: String
    ) {
        var userInfo: [String: Any] = [
            MountHandoff.pathKey: volume.mountURL.path,
            MountHandoff.nameKey: volume.name,
            MountHandoff.targetApplicationPathKey: targetApplicationPath
        ]
        if let eventID {
            userInfo[MountHandoff.eventIDKey] = eventID.uuidString
        }

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(MountHandoff.notificationName),
            object: targetApplicationPath,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    private var containingMainApplicationURL: URL? {
        guard
            let appURL = MountHandoff.containingApplicationURL(for: Bundle.main.bundleURL),
            Bundle(url: appURL)?.bundleIdentifier == Self.mainBundleIdentifier
        else {
            return nil
        }
        return appURL.standardizedFileURL
    }
}
