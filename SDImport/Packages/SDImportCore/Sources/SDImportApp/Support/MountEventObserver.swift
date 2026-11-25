import AppKit
import Foundation
import SDImportCore

@MainActor
final class MountEventObserver {
    private let detector = VolumeDetector()
    private let mountPrivacyPolicy: MountPrivacyPolicy
    private var token: NSObjectProtocol?
    private var unmountToken: NSObjectProtocol?
    private var distributedToken: NSObjectProtocol?
    private let handler: (MountedVolume) -> MountEventHandlingDisposition
    private let volumeMountedHandler: (MountedVolume) -> Void
    private let volumeUnmountedHandler: (URL) -> Void
    private let unmountHandler: (URL) -> Void
    private let errorHandler: (String, UInt64?) -> Void
    private let handoffAcknowledgedHandler: (MountHandoffEvent) -> Void
    private let shouldHandleDirectMount: () -> Bool
    private let shouldHandleHandoff: (MountHandoffEvent) -> Bool
    private let handoffStore: MountHandoffStore?
    private let targetApplicationPath: String
    private let applicationBuild: String
    private var deliveryController = MountHandoffDeliveryController()
#if DEBUG
    private(set) var runtimeQAPromptVolume: MountedVolume?
#endif

    init(
        applicationURL: URL = Bundle.main.bundleURL,
        distribution: AppDistribution = .current,
        handler: @escaping (MountedVolume) -> MountEventHandlingDisposition,
        volumeMountedHandler: @escaping (MountedVolume) -> Void = { _ in },
        volumeUnmountedHandler: @escaping (URL) -> Void = { _ in },
        unmountHandler: @escaping (URL) -> Void = { _ in },
        shouldHandleDirectMount: @escaping () -> Bool,
        shouldHandleHandoff: @escaping (MountHandoffEvent) -> Bool,
        handoffAcknowledgedHandler: @escaping (MountHandoffEvent) -> Void = { _ in },
        errorHandler: @escaping (String, UInt64?) -> Void = { _, _ in }
    ) {
        mountPrivacyPolicy = distribution.mountPrivacyPolicy
        self.handler = handler
        self.volumeMountedHandler = volumeMountedHandler
        self.volumeUnmountedHandler = volumeUnmountedHandler
        self.unmountHandler = unmountHandler
        self.shouldHandleDirectMount = shouldHandleDirectMount
        self.shouldHandleHandoff = shouldHandleHandoff
        self.handoffAcknowledgedHandler = handoffAcknowledgedHandler
        self.errorHandler = errorHandler
        targetApplicationPath = applicationURL.standardizedFileURL.path
        applicationBuild = Bundle(url: applicationURL)?
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        handoffStore = try? MountHandoffStore.defaultStore()
    }

    func start() {
        guard token == nil else {
            return
        }

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

        unmountToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mountURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
                return
            }
            Task { @MainActor in
                self?.handleUnmountURL(mountURL)
            }
        }

        if mountPrivacyPolicy.usesDistributedNotificationHandoff {
            distributedToken = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(MountHandoff.notificationName),
                object: targetApplicationPath,
                queue: .main
            ) { [weak self] notification in
                guard let path = notification.userInfo?[MountHandoff.pathKey] as? String else {
                    return
                }
                guard
                    let targetPath = notification.userInfo?[MountHandoff.targetApplicationPathKey] as? String,
                    URL(fileURLWithPath: targetPath).standardizedFileURL.path == self?.targetApplicationPath
                else {
                    return
                }
                let eventID = (notification.userInfo?[MountHandoff.eventIDKey] as? String)
                    .flatMap(UUID.init(uuidString:))
                Task { @MainActor in
                    self?.handleNotification(path: path, eventID: eventID)
                }
            }
        }

        consumePendingHandoffs()
    }

    func stop() {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let distributedToken {
            DistributedNotificationCenter.default().removeObserver(distributedToken)
        }
        if let unmountToken {
            NSWorkspace.shared.notificationCenter.removeObserver(unmountToken)
        }
        token = nil
        unmountToken = nil
        distributedToken = nil
    }

    private func handleMountURL(_ mountURL: URL) {
        guard shouldHandleDirectMount() else {
            return
        }
        guard let volume = detector.currentMountedVolume(
            from: mountURL,
            includeCapacity: mountPrivacyPolicy.includesCapacityBeforeConsent
        ), detector.isLikelyImportVolume(volume) else {
            return
        }
        volumeMountedHandler(volume)
        guard let handoffStore else {
            errorHandler(L10n.tr("The background prompt mailbox is unavailable"), nil)
            return
        }
        do {
            let event = try handoffStore.enqueue(
                mountPath: volume.mountURL.path,
                volumeName: volume.name,
                agentBuild: applicationBuild,
                targetApplicationPath: targetApplicationPath,
                origin: .foregroundApplication,
                mountedVolume: volume
            )
            if let claim = try handoffStore.claimEvent(
                id: event.id,
                targetApplicationPath: targetApplicationPath
            ) {
                process(claim)
            }
        } catch {
            errorHandler(L10n.tr("Could not persist a foreground mounted-card event"), nil)
        }
    }

    private func handleUnmountURL(_ mountURL: URL) {
        volumeUnmountedHandler(mountURL)
        let currentVolume = detector.currentMountedVolume(
            from: mountURL,
            includeCapacity: mountPrivacyPolicy.includesCapacityBeforeConsent
        )
        if let currentVolume = deliveryController.reconcileUnmount(at: mountURL, currentVolume: currentVolume) {
            volumeMountedHandler(currentVolume)
            return
        }
#if DEBUG
        if runtimeQAPromptVolume?.mountPath == mountURL.standardizedFileURL.path {
            runtimeQAPromptVolume = nil
        }
#endif
        unmountHandler(mountURL)
    }

    private func handleNotification(path: String, eventID: UUID?) {
        guard let eventID else {
            guard shouldHandleDirectMount() else {
                return
            }
            handleHandoff(path: path)
            return
        }

        do {
            guard let handoffStore else {
                errorHandler(L10n.tr("The background prompt mailbox is unavailable"), nil)
                return
            }
            guard let claim = try handoffStore.claimEvent(
                id: eventID,
                targetApplicationPath: targetApplicationPath
            ) else {
                return
            }
            process(claim)
        } catch {
            errorHandler(L10n.tr("Could not claim a background prompt event"), nil)
        }
    }

    func consumePendingHandoffs() {
        guard let handoffStore else {
            errorHandler(L10n.tr("The background prompt mailbox is unavailable"), nil)
            return
        }

        do {
            for claim in try handoffStore.claimPendingEvents(
                targetApplicationPath: targetApplicationPath
            ) {
                process(claim)
            }
        } catch {
            errorHandler(L10n.tr("Could not read pending background prompt events"), nil)
        }
    }

    private func process(_ claim: MountHandoffClaim) {
        guard shouldHandleHandoff(claim.event) else {
            handoffStore?.release(claim)
            return
        }
        handleHandoff(
            path: claim.event.mountPath,
            claim: claim,
            event: claim.event
        )
    }

    private func handleHandoff(
        path: String,
        claim: MountHandoffClaim? = nil,
        event: MountHandoffEvent? = nil
    ) {
        let mountURL = URL(fileURLWithPath: path, isDirectory: true)
        guard let volume = MountHandoffProbeCompletionValidator.currentVolumeForDelivery(
            event: event,
            detectCurrentVolume: { self.currentImportVolume(at: mountURL, event: event) }
        ) else {
            finish(claim)
            return
        }
        if !mountPrivacyPolicy.probesMediaBeforeConsent {
            switch handleImportableVolume(volume, event: event) {
            case .accepted:
                finish(claim)
            case .deferred:
                if let claim {
                    handoffStore?.release(claim)
                }
            }
            return
        }
        probeForMediaThenHandle(volume, claim: claim, event: event)
    }

    private func probeForMediaThenHandle(
        _ volume: MountedVolume,
        claim: MountHandoffClaim? = nil,
        event: MountHandoffEvent? = nil
    ) {
        let mountURL = volume.mountURL
        Task.detached(priority: .utility) { [weak self] in
            let containsMedia = VolumeDetector().containsImportableMedia(at: mountURL)
            await MainActor.run {
                guard let self else {
                    return
                }
                guard containsMedia else {
                    self.finish(claim)
                    return
                }
                guard let currentVolume = MountHandoffProbeCompletionValidator
                    .currentVolumeForDelivery(
                        event: event,
                        observedVolume: volume,
                        detectCurrentVolume: {
                            self.currentImportVolume(at: mountURL, event: event)
                        }
                    )
                else {
                    self.finish(claim)
                    return
                }

                switch self.handleImportableVolume(currentVolume, event: event) {
                case .accepted:
                    self.finish(claim)
                case .deferred:
                    if let claim {
                        self.handoffStore?.release(claim)
                    }
                }
            }
        }
    }

    private func currentImportVolume(at mountURL: URL, event: MountHandoffEvent?) -> MountedVolume? {
        guard let volume = detector.currentMountedVolume(
            from: mountURL,
            includeCapacity: mountPrivacyPolicy.includesCapacityBeforeConsent
        ) else { return nil }
        if detector.isLikelyImportVolume(volume) { return volume }

#if DEBUG
        // The existing helper lifecycle QA uses a mounted disk image to test
        // delivery after classification. It still needs a live mount root.
        if event?.mountedVolume == BackgroundPromptRuntimeQA.injectedPostDetectionVolume(at: mountURL),
           BackgroundPromptRuntimeQA.consumesInjectedHandoff() || BackgroundPromptRuntimeQA.helperLifecycleIsActive() {
            let fixture = MountedVolume(
                id: volume.id,
                name: volume.name,
                mountURL: volume.mountURL,
                volumeUUID: volume.volumeUUID,
                isRemovable: true,
                wholeDiskIdentifier: volume.wholeDiskIdentifier,
                deviceGroupIdentifier: volume.deviceGroupIdentifier,
                deviceVendorName: volume.deviceVendorName,
                deviceProductName: volume.deviceProductName,
                mediaRegistryID: volume.mediaRegistryID
            )
            runtimeQAPromptVolume = fixture
            return fixture
        }
#endif
        return nil
    }

    private func finish(_ claim: MountHandoffClaim?) {
        guard let claim else {
            return
        }
        do {
            try handoffStore?.acknowledge(claim)
            handoffAcknowledgedHandler(claim.event)
        } catch {
            errorHandler(L10n.tr("Could not acknowledge a background prompt event"), claim.event.agentSequence)
        }
    }

    private func handleImportableVolume(
        _ volume: MountedVolume,
        event: MountHandoffEvent?
    ) -> MountEventHandlingDisposition {
        if let event {
            return deliveryController.evaluate(event: event, volume: volume, handler: handler)
        } else {
            return deliveryController.evaluate(volume: volume, handler: handler)
        }
    }
}
