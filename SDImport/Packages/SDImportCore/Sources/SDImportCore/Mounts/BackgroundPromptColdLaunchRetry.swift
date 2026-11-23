import Foundation

@MainActor
public final class BackgroundPromptColdLaunchRetry {
    public struct Application {
        public let isFinishedLaunching: Bool
        public let activate: @MainActor () -> Void

        public init(isFinishedLaunching: Bool, activate: @escaping @MainActor () -> Void) {
            self.isFinishedLaunching = isFinishedLaunching
            self.activate = activate
        }
    }

    private let findApplication: @MainActor (URL) -> Application?
    private let currentVolume: @MainActor (URL) -> MountedVolume?
    private let isAuthorized: @MainActor () -> Bool
    private let sleep: BackgroundPromptRetryScheduler.Sleep
    private var volumes: [String: MountedVolume] = [:]
    private(set) var task: Task<Void, Never>?

    public init(
        findApplication: @escaping @MainActor (URL) -> Application?,
        currentVolume: @escaping @MainActor (URL) -> MountedVolume?,
        isAuthorized: @escaping @MainActor () -> Bool,
        sleep: @escaping BackgroundPromptRetryScheduler.Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.findApplication = findApplication
        self.currentVolume = currentVolume
        self.isAuthorized = isAuthorized
        self.sleep = sleep
    }

    public func track(_ volume: MountedVolume, at appURL: URL, startsNewLaunch: Bool) {
        volumes[volume.mountPath] = volume
        guard task == nil || startsNewLaunch else { return }
        task?.cancel()

        // Launch Services may create the process before it finishes starting.
        // A new open request gets the full retry window.
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    self.volumes.removeAll()
                    self.task = nil
                }
            }

            for delay in [Duration.seconds(1), .seconds(2)] {
                do {
                    try await self.sleep(delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let application = self.findApplication(appURL) else { continue }
                guard !application.isFinishedLaunching else { return }
                guard self.volumes.values.contains(where: { volume in
                    MountHandoffProbeCompletionValidator.currentVolumeForDelivery(
                        event: nil,
                        observedVolume: volume,
                        detectCurrentVolume: { self.currentVolume(volume.mountURL) }
                    ) != nil
                }) else { continue }
                guard self.isAuthorized() else { return }
                application.activate()
            }
        }
    }

    public func removeVolume(at mountURL: URL, preserving current: MountedVolume? = nil) {
        let path = mountURL.standardizedFileURL.path
        if let current, let tracked = volumes[path], current.hasVerifiedMediaContinuity(with: tracked) {
            return
        }
        volumes.removeValue(forKey: path)
        if volumes.isEmpty {
            task?.cancel()
            task = nil
        }
    }
}
