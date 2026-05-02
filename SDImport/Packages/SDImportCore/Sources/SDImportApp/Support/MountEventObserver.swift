import AppKit
import Foundation
import SDImportCore

@MainActor
final class MountEventObserver {
    private let detector = VolumeDetector()
    private var debouncer = MountDebouncer()
    private var token: NSObjectProtocol?
    private var distributedToken: NSObjectProtocol?
    private let handler: (MountedVolume) -> Void

    init(handler: @escaping (MountedVolume) -> Void) {
        self.handler = handler
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

        distributedToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(MountHandoff.notificationName),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let path = notification.userInfo?[MountHandoff.pathKey] as? String else {
                return
            }
            let name = notification.userInfo?[MountHandoff.nameKey] as? String
            Task { @MainActor in
                self?.handleHandoff(path: path, name: name)
            }
        }
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
        let volume = detector.mountedVolume(from: mountURL)
        guard detector.isLikelyImportVolume(volume), debouncer.shouldAccept(volume) else {
            return
        }
        handler(volume)
    }

    private func handleHandoff(path: String, name: String?) {
        let mountURL = URL(fileURLWithPath: path, isDirectory: true)
        var volume = detector.mountedVolume(from: mountURL)
        if let name, !name.isEmpty {
            volume = MountedVolume(
                id: volume.id,
                name: name,
                mountURL: volume.mountURL,
                volumeUUID: volume.volumeUUID,
                isRemovable: volume.isRemovable
            )
        }
        guard detector.isLikelyImportVolume(volume), debouncer.shouldAccept(volume) else {
            return
        }
        handler(volume)
    }
}
