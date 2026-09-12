import AppKit
import Foundation
import SDImportCore

@MainActor
final class MountEventObserver {
    private let detector = VolumeDetector()
    private let mountPrivacyPolicy: MountPrivacyPolicy
    private var debouncer = MountDebouncer()
    private var token: NSObjectProtocol?
    private var distributedToken: NSObjectProtocol?
    private let handler: (MountedVolume) -> MountEventHandlingDisposition
    private let errorHandler: (String, UInt64?) -> Void
    private let handoffAcknowledgedHandler: (MountHandoffEvent) -> Void
    private let shouldHandleDirectMount: () -> Bool
    private let shouldHandleHandoff: (MountHandoffEvent) -> Bool
    private let handoffStore: MountHandoffStore?
    private let targetApplicationPath: String
    private let applicationBuild: String
    private var deliveryController = MountHandoffDeliveryController()

    init(
        applicationURL: URL = Bundle.main.bundleURL,
        distribution: AppDistribution = .current,
        handler: @escaping (MountedVolume) -> MountEventHandlingDisposition,
        shouldHandleDirectMount: @escaping () -> Bool,
        shouldHandleHandoff: @escaping (MountHandoffEvent) -> Bool,
        handoffAcknowledgedHandler: @escaping (MountHandoffEvent) -> Void = { _ in },
        errorHandler: @escaping (String, UInt64?) -> Void = { _, _ in }
    ) {
        mountPrivacyPolicy = distribution.mountPrivacyPolicy
        self.handler = handler
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
                let name = notification.userInfo?[MountHandoff.nameKey] as? String
                let eventID = (notification.userInfo?[MountHandoff.eventIDKey] as? String)
                    .flatMap(UUID.init(uuidString:))
                Task { @MainActor in
                    self?.handleNotification(path: path, name: name, eventID: eventID)
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
        token = nil
        distributedToken = nil
    }

    private func handleMountURL(_ mountURL: URL) {
        guard shouldHandleDirectMount() else {
            return
        }
        let volume = detector.mountedVolume(
            from: mountURL,
            includeCapacity: mountPrivacyPolicy.includesCapacityBeforeConsent
        )
        guard detector.isLikelyImportVolume(volume) else {
            return
        }
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

    private func handleNotification(path: String, name: String?, eventID: UUID?) {
        guard let eventID else {
            guard shouldHandleDirectMount() else {
                return
            }
            handleHandoff(path: path, name: name)
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
            name: claim.event.volumeName,
            claim: claim,
            event: claim.event
        )
    }

    private func handleHandoff(
        path: String,
        name: String?,
        claim: MountHandoffClaim? = nil,
        event: MountHandoffEvent? = nil
    ) {
        let mountURL = URL(fileURLWithPath: path, isDirectory: true)
        let detectedVolume = detector.mountedVolume(
            from: mountURL,
            includeCapacity: mountPrivacyPolicy.includesCapacityBeforeConsent
        )
        if !MountHandoffVolumeIdentity.matchesCurrentVolume(
            expectedUUID: event?.mountedVolume?.volumeUUID,
            currentUUID: detectedVolume.volumeUUID
        ) {
            finish(claim)
            return
        }
        var volume = event?.mountedVolume ?? detectedVolume
        if let name, !name.isEmpty {
            volume = MountedVolume(
                id: volume.id,
                name: name,
                mountURL: volume.mountURL,
                volumeUUID: volume.volumeUUID,
                isRemovable: volume.isRemovable,
                isInternal: volume.isInternal,
                isDiskImage: volume.isDiskImage,
                totalCapacityBytes: volume.totalCapacityBytes,
                availableCapacityBytes: volume.availableCapacityBytes,
                wholeDiskIdentifier: volume.wholeDiskIdentifier,
                deviceGroupIdentifier: volume.deviceGroupIdentifier,
                deviceVendorName: volume.deviceVendorName,
                deviceProductName: volume.deviceProductName
            )
        }
        guard detector.isLikelyImportVolume(volume) else {
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
                        detectCurrentVolume: {
                            self.detector.mountedVolume(from: mountURL)
                        }
                    ),
                    self.detector.isLikelyImportVolume(currentVolume)
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
            guard !debouncer.hasRecentlyAccepted(volume) else {
                return .accepted
            }
        }
        let disposition = handler(volume)
        if disposition == .accepted {
            debouncer.recordAccepted(volume)
        }
        return disposition
    }
}
