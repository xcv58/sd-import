import Foundation

public struct MountDebouncer: Sendable {
    private let interval: TimeInterval
    private var lastSeenBySource: [String: Date] = [:]
    private var sourceKeyByMountPath: [String: String] = [:]

    public init(interval: TimeInterval = 5) {
        self.interval = interval
    }

    public mutating func shouldAccept(_ volume: MountedVolume, now: Date = Date()) -> Bool {
        guard !hasRecentlyAccepted(volume, now: now) else {
            return false
        }

        recordAccepted(volume, now: now)
        return true
    }

    public func hasRecentlyAccepted(_ volume: MountedVolume, now: Date = Date()) -> Bool {
        let key = sourceKey(for: volume)
        guard let lastSeen = lastSeenBySource[key] else {
            return false
        }
        return now.timeIntervalSince(lastSeen) < interval
    }

    public mutating func recordAccepted(_ volume: MountedVolume, now: Date = Date()) {
        let key = sourceKey(for: volume)
        lastSeenBySource[key] = now
        sourceKeyByMountPath[volume.mountURL.standardizedFileURL.path] = key
    }

    public mutating func forget(mountURL: URL) {
        let mountPath = mountURL.standardizedFileURL.path
        if let key = sourceKeyByMountPath.removeValue(forKey: mountPath) {
            if !sourceKeyByMountPath.values.contains(key) {
                lastSeenBySource.removeValue(forKey: key)
            }
        }
    }

    private func sourceKey(for volume: MountedVolume) -> String {
        if let deviceIdentifier = volume.deviceGroupIdentifier, !deviceIdentifier.isEmpty {
            return "device:\(deviceIdentifier)"
        } else if let wholeDiskIdentifier = volume.wholeDiskIdentifier, !wholeDiskIdentifier.isEmpty {
            return "disk:\(wholeDiskIdentifier)"
        } else {
            return "volume:\(volume.mountURL.standardizedFileURL.path)"
        }
    }
}
