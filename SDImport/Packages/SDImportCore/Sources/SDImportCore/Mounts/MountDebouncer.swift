import Foundation

public struct MountDebouncer: Sendable {
    private let interval: TimeInterval
    private var lastSeenByPath: [String: Date] = [:]

    public init(interval: TimeInterval = 5) {
        self.interval = interval
    }

    public mutating func shouldAccept(_ volume: MountedVolume, now: Date = Date()) -> Bool {
        let key = volume.mountURL.standardizedFileURL.path
        if let lastSeen = lastSeenByPath[key], now.timeIntervalSince(lastSeen) < interval {
            return false
        }

        lastSeenByPath[key] = now
        return true
    }
}
