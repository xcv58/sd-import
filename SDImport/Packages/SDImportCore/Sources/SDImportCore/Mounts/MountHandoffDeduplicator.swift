import Foundation

public enum MountEventHandlingDisposition: Equatable, Sendable {
    case accepted
    case deferred
}

public enum MountHandoffVolumeIdentity {
    /// A queued UUID-bearing occurrence is safe to deliver only when the
    /// currently mounted volume exposes the same UUID. Legacy UUID-less
    /// occurrences remain eligible for the normal volume-safety checks.
    public static func matchesCurrentVolume(
        expectedUUID: String?,
        currentUUID: String?
    ) -> Bool {
        guard let expectedUUID = normalized(expectedUUID) else {
            return true
        }
        guard let currentUUID = normalized(currentUUID) else {
            return false
        }
        return expectedUUID == currentUUID
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}

public enum MountHandoffProbeCompletionValidator {
    /// Re-reads the mounted volume after an asynchronous media probe so a
    /// same-path card replacement cannot commit the queued occurrence.
    public static func currentVolumeForDelivery(
        event: MountHandoffEvent?,
        detectCurrentVolume: () -> MountedVolume
    ) -> MountedVolume? {
        let currentVolume = detectCurrentVolume()
        guard MountHandoffVolumeIdentity.matchesCurrentVolume(
            expectedUUID: event?.mountedVolume?.volumeUUID,
            currentUUID: currentVolume.volumeUUID
        ) else {
            return nil
        }
        return currentVolume
    }
}

/// Suppresses repeated deliveries for an accepted, continuously mounted volume.
/// The accepted identity remains active until the observer receives an unmount.
public struct MountHandoffDeduplicator: Sendable {
    private struct AcceptedEvent: Sendable {
        let mountPath: String
        let volumeUUID: String?
    }

    private let capacity: Int
    private var acceptedEvents: [AcceptedEvent] = []

    public init(correlationInterval: TimeInterval = 10, capacity: Int = 128) {
        _ = correlationInterval
        self.capacity = max(1, capacity)
    }

    public func consumeCorrelatedDuplicate(_ event: MountHandoffEvent) -> Bool {
        let identity = acceptedIdentity(for: event)
        return contains(identity)
    }

    public func consumeCorrelatedDuplicate(_ volume: MountedVolume) -> Bool {
        contains(acceptedIdentity(for: volume))
    }

    private func contains(_ identity: AcceptedEvent) -> Bool {
        return acceptedEvents.contains { accepted in
            if let acceptedUUID = accepted.volumeUUID, let eventUUID = identity.volumeUUID {
                return acceptedUUID == eventUUID
            }
            return accepted.mountPath == identity.mountPath
        }
    }

    public mutating func recordAccepted(_ event: MountHandoffEvent) {
        let identity = acceptedIdentity(for: event)
        recordAccepted(identity)
    }

    public mutating func recordAccepted(_ volume: MountedVolume) {
        recordAccepted(acceptedIdentity(for: volume))
    }

    private mutating func recordAccepted(_ identity: AcceptedEvent) {
        guard !acceptedEvents.contains(where: { accepted in
            if let acceptedUUID = accepted.volumeUUID, let eventUUID = identity.volumeUUID {
                return acceptedUUID == eventUUID
            }
            return accepted.mountPath == identity.mountPath
        }) else {
            return
        }
        acceptedEvents.append(identity)
        if acceptedEvents.count > capacity {
            acceptedEvents.removeFirst(acceptedEvents.count - capacity)
        }
    }

    public mutating func forget(mountURL: URL) {
        let mountPath = mountURL.standardizedFileURL.path
        acceptedEvents.removeAll { $0.mountPath == mountPath }
    }

    private func acceptedIdentity(for event: MountHandoffEvent) -> AcceptedEvent {
        AcceptedEvent(
            mountPath: URL(fileURLWithPath: event.mountPath, isDirectory: true).standardizedFileURL.path,
            volumeUUID: normalizedVolumeUUID(for: event)
        )
    }

    private func acceptedIdentity(for volume: MountedVolume) -> AcceptedEvent {
        AcceptedEvent(
            mountPath: volume.mountURL.standardizedFileURL.path,
            volumeUUID: normalizedVolumeUUID(volume.volumeUUID)
        )
    }

    private func normalizedVolumeUUID(for event: MountHandoffEvent) -> String? {
        normalizedVolumeUUID(event.mountedVolume?.volumeUUID)
    }

    private func normalizedVolumeUUID(_ volumeUUID: String?) -> String? {
        guard let value = volumeUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}

/// Coordinates correlated foreground/helper deliveries.
///
/// This is intentionally a reference type. `evaluate` invokes application code,
/// and that handler can synchronously consume another queued handoff. Keeping the
/// controller as a value type would hold an exclusive `inout` access across the
/// handler and abort if delivery re-entered before the outer call returned.
public final class MountHandoffDeliveryController {
    private var deduplicator: MountHandoffDeduplicator

    public init(deduplicator: MountHandoffDeduplicator = MountHandoffDeduplicator()) {
        self.deduplicator = deduplicator
    }

    public func evaluate(
        event: MountHandoffEvent,
        volume: MountedVolume,
        handler: (MountedVolume) -> MountEventHandlingDisposition
    ) -> MountEventHandlingDisposition {
        _ = event
        return evaluate(volume: volume, handler: handler)
    }

    public func evaluate(
        volume: MountedVolume,
        handler: (MountedVolume) -> MountEventHandlingDisposition
    ) -> MountEventHandlingDisposition {
        guard !deduplicator.consumeCorrelatedDuplicate(volume) else {
            return .accepted
        }
        let disposition = handler(volume)
        if disposition == .accepted {
            deduplicator.recordAccepted(volume)
        }
        return disposition
    }

    public func forget(mountURL: URL) {
        deduplicator.forget(mountURL: mountURL)
    }
}
