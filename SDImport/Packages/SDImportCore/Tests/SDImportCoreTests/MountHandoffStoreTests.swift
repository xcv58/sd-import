import Foundation
import Testing

@testable import SDImportCore

@Suite("Mount handoff store")
struct MountHandoffStoreTests {
    private let targetApplicationPath = "/Applications/SD Import.app"

    @Test("pending mount survives startup delays longer than the old notification retry")
    func eventSurvivesDelayedStartup() throws {
        let directory = try temporaryDirectory()
        let writer = MountHandoffStore(directoryURL: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = try writer.enqueue(
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath,
            now: start
        )

        let reader = MountHandoffStore(directoryURL: directory)
        let claims = try reader.claimPendingEvents(
            targetApplicationPath: targetApplicationPath,
            now: start.addingTimeInterval(120)
        )

        #expect(claims.map(\.event) == [event])
    }

    @Test("handoffs written before event sequencing remain readable")
    func legacyEventDecodes() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "createdAt": "2026-07-25T20:00:00Z",
              "mountPath": "/Volumes/CARD",
              "volumeName": "CARD",
              "agentBuild": "43",
              "targetApplicationPath": "/Applications/SD Import.app"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let event = try decoder.decode(MountHandoffEvent.self, from: data)

        #expect(event.agentSequence == 0)
        #expect(event.targetApplicationPath == targetApplicationPath)
        #expect(event.origin == .backgroundAgent)
        #expect(event.mountedVolume == nil)
    }

    @Test("acknowledging a mount prevents duplicate delivery")
    func acknowledgementRemovesEvent() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        try store.enqueue(
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath
        )
        let claim = try #require(
            store.claimPendingEvents(targetApplicationPath: targetApplicationPath).first
        )

        try store.acknowledge(claim)
        try store.acknowledge(claim)

        #expect(
            try store.claimPendingEvents(targetApplicationPath: targetApplicationPath).isEmpty
        )
    }

    @Test("releasing a claim leaves it available for the authoritative consumer")
    func releasedClaimRemainsPending() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        try store.enqueue(
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath
        )
        let firstClaim = try #require(
            store.claimPendingEvents(targetApplicationPath: targetApplicationPath).first
        )

        store.release(firstClaim)

        let secondClaim = try #require(
            store.claimPendingEvents(targetApplicationPath: targetApplicationPath).first
        )
        #expect(secondClaim.event.id == firstClaim.event.id)
        try store.acknowledge(secondClaim)
    }

    @Test("a handoff released before helper repair is consumable in the same session")
    func releasedHandoffCanBeRetriedAfterRepair() throws {
        let directory = try temporaryDirectory()
        let handoffStore = MountHandoffStore(
            directoryURL: directory.appendingPathComponent("handoffs")
        )
        let stateStore = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let agentPath = "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        let identity = BackgroundPromptRepairIdentity(
            appBuild: "44",
            applicationPath: targetApplicationPath,
            agentBundlePath: agentPath
        )
        try handoffStore.enqueue(
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            agentBuild: "43",
            agentSequence: 1,
            targetApplicationPath: targetApplicationPath
        )
        let preRepairClaim = try #require(
            handoffStore.claimPendingEvents(targetApplicationPath: targetApplicationPath).first
        )
        handoffStore.release(preRepairClaim)

        try stateStore.authorize(agentBuild: "44", agentBundlePath: agentPath)
        try stateStore.recordLaunch(agentBuild: "44", agentBundlePath: agentPath)
        let liveState = try stateStore.load()
        #expect(
            BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
                identity: identity,
                serviceStatus: .enabled,
                liveAgentState: liveState
            )
        )

        let postRepairClaim = try #require(
            handoffStore.claimPendingEvents(targetApplicationPath: targetApplicationPath).first
        )
        #expect(postRepairClaim.event.id == preRepairClaim.event.id)
        try handoffStore.acknowledge(postRepairClaim)
    }

    @Test("reusing an event identifier remains a single pending delivery")
    func duplicateIdentifierIsIdempotent() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for _ in 0..<2 {
            try store.enqueue(
                mountPath: "/Volumes/CARD",
                volumeName: "CARD",
                agentBuild: "44",
                targetApplicationPath: targetApplicationPath,
                now: now,
                id: id
            )
        }

        #expect(
            try store.claimPendingEvents(
                targetApplicationPath: targetApplicationPath,
                now: now
            ).count == 1
        )
    }

    @Test("same-path foreground mount occurrences remain distinct while busy")
    func samePathForegroundOccurrencesRemainDistinct() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        let volume = MountedVolume(
            id: "card",
            name: "CARD",
            mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
            volumeUUID: "card-uuid",
            isRemovable: true
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for offset in [0.0, 2.0] {
            try store.enqueue(
                mountPath: volume.mountURL.path,
                volumeName: volume.name,
                agentBuild: "44",
                targetApplicationPath: targetApplicationPath,
                origin: .foregroundApplication,
                mountedVolume: volume,
                now: start.addingTimeInterval(offset)
            )
        }

        let firstClaims = try store.claimPendingEvents(targetApplicationPath: targetApplicationPath)
        #expect(firstClaims.count == 2)
        #expect(Set(firstClaims.map(\.id)).count == 2)
        firstClaims.forEach(store.release)

        let retriedClaims = try store.claimPendingEvents(targetApplicationPath: targetApplicationPath)
        #expect(retriedClaims.count == 2)
        retriedClaims.forEach(store.release)
    }

    @Test("helper producer persists every same-origin mount occurrence")
    func helperProducerPersistsEveryOccurrence() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        let recorder = MountHandoffOccurrenceRecorder(store: store)
        let volume = MountedVolume(
            id: "card",
            name: "CARD",
            mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
            volumeUUID: "card-uuid",
            isRemovable: true
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try recorder.persistBackgroundAgentOccurrence(
            volume: volume,
            agentBuild: "44",
            agentSequence: 1,
            targetApplicationPath: targetApplicationPath,
            now: start
        )
        let second = try recorder.persistBackgroundAgentOccurrence(
            volume: volume,
            agentBuild: "44",
            agentSequence: 2,
            targetApplicationPath: targetApplicationPath,
            now: start.addingTimeInterval(1)
        )

        let claims = try store.claimPendingEvents(targetApplicationPath: targetApplicationPath)
        #expect(claims.map(\.event.id) == [first.id, second.id])
        #expect(claims.map(\.event.agentSequence) == [1, 2])
        #expect(claims.allSatisfy { $0.event.origin == .backgroundAgent })
        claims.forEach(store.release)
    }

    @Test("UUID-bearing handoffs require a positive current-volume match")
    func handoffVolumeIdentityRequiresPositiveMatch() {
        #expect(
            MountHandoffVolumeIdentity.matchesCurrentVolume(
                expectedUUID: " CARD-UUID ",
                currentUUID: "card-uuid"
            )
        )
        #expect(
            !MountHandoffVolumeIdentity.matchesCurrentVolume(
                expectedUUID: "card-a",
                currentUUID: "card-b"
            )
        )
        #expect(
            !MountHandoffVolumeIdentity.matchesCurrentVolume(
                expectedUUID: "card-a",
                currentUUID: nil
            )
        )
        #expect(
            MountHandoffVolumeIdentity.matchesCurrentVolume(
                expectedUUID: nil,
                currentUUID: nil
            )
        )
    }

    @Test("card swap during media probe fails completion revalidation")
    func probeCompletionRejectsSamePathCardSwap() {
        let mountURL = URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true)
        let cardA = MountedVolume(
            id: "card-a",
            name: "CARD",
            mountURL: mountURL,
            volumeUUID: "card-a-uuid",
            isRemovable: true
        )
        let cardB = MountedVolume(
            id: "card-b",
            name: "CARD",
            mountURL: mountURL,
            volumeUUID: "card-b-uuid",
            isRemovable: true
        )
        let event = MountHandoffEvent(
            mountPath: mountURL.path,
            volumeName: cardA.name,
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath,
            mountedVolume: cardA
        )
        var currentlyMounted = cardA

        let beforeSwap = MountHandoffProbeCompletionValidator.currentVolumeForDelivery(
            event: event,
            detectCurrentVolume: { currentlyMounted }
        )
        currentlyMounted = cardB
        let afterSwap = MountHandoffProbeCompletionValidator.currentVolumeForDelivery(
            event: event,
            detectCurrentVolume: { currentlyMounted }
        )

        #expect(beforeSwap == cardA)
        #expect(afterSwap == nil)
    }

    @Test("deduplication requires a cross-origin matching volume occurrence")
    func deduplicationRequiresPositiveCrossOriginCorrelation() {
        let volume = MountedVolume(
            id: "card",
            name: "CARD",
            mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
            volumeUUID: "card-uuid",
            isRemovable: true
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let foreground = MountHandoffEvent(
            createdAt: start,
            mountPath: volume.mountURL.path,
            volumeName: volume.name,
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath,
            origin: .foregroundApplication,
            mountedVolume: volume
        )
        let sameOrigin = MountHandoffEvent(
            createdAt: start.addingTimeInterval(1),
            mountPath: volume.mountURL.path,
            volumeName: volume.name,
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath,
            origin: .foregroundApplication,
            mountedVolume: volume
        )
        let agent = MountHandoffEvent(
            createdAt: start.addingTimeInterval(1),
            mountPath: volume.mountURL.path,
            volumeName: volume.name,
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath,
            origin: .backgroundAgent,
            mountedVolume: volume
        )
        let secondAgent = MountHandoffEvent(
            createdAt: start.addingTimeInterval(2),
            mountPath: volume.mountURL.path,
            volumeName: volume.name,
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath,
            origin: .backgroundAgent,
            mountedVolume: volume
        )
        var deduplicator = MountHandoffDeduplicator(correlationInterval: 10)

        deduplicator.recordAccepted(foreground)
        let sameOriginWasDuplicate = deduplicator.consumeCorrelatedDuplicate(sameOrigin)
        let firstAgentWasDuplicate = deduplicator.consumeCorrelatedDuplicate(agent)
        let secondAgentWasDuplicate = deduplicator.consumeCorrelatedDuplicate(secondAgent)

        #expect(!sameOriginWasDuplicate)
        #expect(firstAgentWasDuplicate)
        #expect(!secondAgentWasDuplicate)

        let controller = MountHandoffDeliveryController(
            deduplicator: MountHandoffDeduplicator(correlationInterval: 10)
        )
        var handlerCallCount = 0
        #expect(
            controller.evaluate(event: foreground, volume: volume) { _ in
                handlerCallCount += 1
                return .accepted
            } == .accepted
        )
        #expect(
            controller.evaluate(event: sameOrigin, volume: volume) { _ in
                handlerCallCount += 1
                return .deferred
            } == .deferred
        )
        #expect(
            controller.evaluate(event: agent, volume: volume) { _ in
                handlerCallCount += 1
                return .deferred
            } == .accepted
        )
        #expect(
            controller.evaluate(event: secondAgent, volume: volume) { _ in
                handlerCallCount += 1
                return .deferred
            } == .deferred
        )
        #expect(handlerCallCount == 3)
    }

    @Test("delivery controller permits a handler to consume another handoff")
    func deliveryControllerPermitsReentrantDelivery() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let volume = MountedVolume(
            id: "reentrant-volume",
            name: "Untitled",
            mountURL: URL(fileURLWithPath: "/Volumes/Untitled", isDirectory: true),
            volumeUUID: "REENTRANT-UUID",
            isRemovable: true,
            isInternal: false,
            isDiskImage: false
        )
        let foreground = MountHandoffEvent(
            createdAt: start,
            mountPath: volume.mountURL.path,
            volumeName: volume.name,
            agentBuild: "4",
            targetApplicationPath: targetApplicationPath,
            origin: .foregroundApplication,
            mountedVolume: volume
        )
        let agent = MountHandoffEvent(
            createdAt: start.addingTimeInterval(1),
            mountPath: volume.mountURL.path,
            volumeName: volume.name,
            agentBuild: "4",
            targetApplicationPath: targetApplicationPath,
            origin: .backgroundAgent,
            mountedVolume: volume
        )
        let controller = MountHandoffDeliveryController(
            deduplicator: MountHandoffDeduplicator(correlationInterval: 10)
        )
        var nestedHandlerCallCount = 0

        let disposition = controller.evaluate(event: foreground, volume: volume) { _ in
            let nestedDisposition = controller.evaluate(event: agent, volume: volume) { _ in
                nestedHandlerCallCount += 1
                return .deferred
            }
            #expect(nestedDisposition == .deferred)
            return .accepted
        }

        #expect(disposition == .accepted)
        #expect(nestedHandlerCallCount == 1)
        #expect(
            controller.evaluate(event: agent, volume: volume) { _ in
                Issue.record("correlated helper delivery should be consumed")
                return .deferred
            } == .accepted
        )
    }

    @Test("old valid handoffs survive while corrupt records are discarded")
    func oldValidHandoffsSurviveAndCorruptRecordsAreDiscarded() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try store.enqueue(
            mountPath: "/Volumes/OLD",
            volumeName: "OLD",
            agentBuild: "43",
            targetApplicationPath: targetApplicationPath,
            now: start
        )
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("corrupt.json"))

        let claims = try store.claimPendingEvents(
            targetApplicationPath: targetApplicationPath,
            now: start.addingTimeInterval(24 * 60 * 60)
        )

        #expect(claims.count == 1)
        #expect(claims.first?.event.mountPath == "/Volumes/OLD")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        if let claim = claims.first {
            try store.acknowledge(claim)
        }
    }

    @Test("explicit cleanup age can discard abandoned handoffs")
    func explicitCleanupAgeDiscardsOldHandoff() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try store.enqueue(
            mountPath: "/Volumes/OLD",
            volumeName: "OLD",
            agentBuild: "43",
            targetApplicationPath: targetApplicationPath,
            now: start
        )

        let claims = try store.claimPendingEvents(
            targetApplicationPath: targetApplicationPath,
            now: start.addingTimeInterval(601),
            maximumAge: 600
        )

        #expect(claims.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("only the exact target application can claim a handoff")
    func exactTargetAndAtomicClaim() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        try store.enqueue(
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath
        )

        #expect(
            try store.claimPendingEvents(
                targetApplicationPath: "/Users/tester/Downloads/SD Import.app"
            ).isEmpty
        )
        let firstConsumer = try store.claimPendingEvents(
            targetApplicationPath: targetApplicationPath
        )
        let secondConsumer = try store.claimPendingEvents(
            targetApplicationPath: targetApplicationPath
        )

        #expect(firstConsumer.count == 1)
        #expect(secondConsumer.isEmpty)
    }

    @Test("symlinked and resolved application paths identify the same handoff target")
    func symlinkedApplicationPathMatchesResolvedTarget() throws {
        let root = try temporaryDirectory()
        let applicationURL = root.appendingPathComponent("SD Import.app", isDirectory: true)
        let symlinkURL = root.appendingPathComponent("Installed SD Import.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: applicationURL
        )

        let store = MountHandoffStore(
            directoryURL: root.appendingPathComponent("Mount Handoffs", isDirectory: true)
        )
        try store.enqueue(
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            agentBuild: "44",
            targetApplicationPath: symlinkURL.path
        )

        let claims = try store.claimPendingEvents(targetApplicationPath: applicationURL.path)
        #expect(claims.count == 1)
        if let claim = claims.first {
            try store.acknowledge(claim)
        }
    }

    @Test("mismatched filenames and duplicate payloads cannot loop")
    func mismatchedFilenameIsDiscarded() throws {
        let directory = try temporaryDirectory()
        let store = MountHandoffStore(directoryURL: directory)
        let event = try store.enqueue(
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            agentBuild: "44",
            targetApplicationPath: targetApplicationPath,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(event).write(to: directory.appendingPathComponent("other.json"))

        let claims = try store.claimPendingEvents(
            targetApplicationPath: targetApplicationPath,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(claims.map(\.event) == [event])
        try store.acknowledge(try #require(claims.first))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("agent resolves the exact containing application bundle")
    func resolvesContainingApplication() {
        let agentURL = URL(
            fileURLWithPath: "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app",
            isDirectory: true
        )

        #expect(
            MountHandoff.containingApplicationURL(for: agentURL)?.path
                == "/Applications/SD Import.app"
        )
        #expect(
            MountHandoff.containingApplicationURL(
                for: URL(fileURLWithPath: "/tmp/SDImportAgent", isDirectory: false)
            ) == nil
        )
    }
}
