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

/// Coalesces only positively correlated foreground/helper observations of the
/// same mounted volume. Events from the same origin are always distinct.
public struct MountHandoffDeduplicator: Sendable {
    private struct AcceptedEvent: Sendable {
        let origin: MountHandoffOrigin
        let createdAt: Date
        let volumeUUID: String
    }

    private let correlationInterval: TimeInterval
    private let capacity: Int
    private var acceptedEvents: [AcceptedEvent] = []

    public init(correlationInterval: TimeInterval = 10, capacity: Int = 128) {
        self.correlationInterval = correlationInterval
        self.capacity = max(1, capacity)
    }

    public mutating func consumeCorrelatedDuplicate(_ event: MountHandoffEvent) -> Bool {
        guard let volumeUUID = normalizedVolumeUUID(for: event) else {
            return false
        }
        guard let index = acceptedEvents.firstIndex(where: {
            $0.origin != event.origin
                && $0.volumeUUID == volumeUUID
                && abs($0.createdAt.timeIntervalSince(event.createdAt)) <= correlationInterval
        }) else {
            return false
        }
        acceptedEvents.remove(at: index)
        return true
    }

    public mutating func recordAccepted(_ event: MountHandoffEvent) {
        guard let volumeUUID = normalizedVolumeUUID(for: event) else {
            return
        }
        acceptedEvents.append(
            AcceptedEvent(
                origin: event.origin,
                createdAt: event.createdAt,
                volumeUUID: volumeUUID
            )
        )
        if acceptedEvents.count > capacity {
            acceptedEvents.removeFirst(acceptedEvents.count - capacity)
        }
    }

    private func normalizedVolumeUUID(for event: MountHandoffEvent) -> String? {
        guard let value = event.mountedVolume?.volumeUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
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
        guard !deduplicator.consumeCorrelatedDuplicate(event) else {
            return .accepted
        }
        let disposition = handler(volume)
        if disposition == .accepted {
            deduplicator.recordAccepted(event)
        }
        return disposition
    }
}
