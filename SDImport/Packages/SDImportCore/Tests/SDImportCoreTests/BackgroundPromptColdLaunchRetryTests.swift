import Foundation
import Testing

@testable import SDImportCore

@Suite("Background prompt cold launch retry", .timeLimit(.minutes(1)))
@MainActor
struct BackgroundPromptColdLaunchRetryTests {
    private let appURL = URL(fileURLWithPath: "/Applications/SD Card Import.app")

    @Test("An inconclusive mount read leaves the second attempt available")
    func transientMountRead() async throws {
        let card = volume(named: "Card A")
        var reads = 0
        var activations = 0
        let retry = BackgroundPromptColdLaunchRetry(
            findApplication: { _ in
                .init(isFinishedLaunching: false) { activations += 1 }
            },
            currentVolume: { _ in
                reads += 1
                return reads == 1 ? nil : card
            },
            isAuthorized: { true },
            sleep: { _ in }
        )

        retry.track(card, at: appURL, startsNewLaunch: true)
        let task = try #require(retry.task)
        await task.value

        #expect(reads == 2)
        #expect(activations == 1)
    }

    @Test("A fresh launch renews retries for saved mounts", arguments: [true, false])
    func newLaunchRestartsRetryWindow(hasSavedSecondEvent: Bool) async throws {
        let first = volume(named: "Card A")
        let second = volume(named: "Card B")
        let third = volume(named: "Card C")
        let live = hasSavedSecondEvent ? third : first
        let delays = AsyncStream<PendingDelay>.makeStream()
        var delayIterator = delays.stream.makeAsyncIterator()
        let application = SimulatedApplication()
        let retry = BackgroundPromptColdLaunchRetry(
            findApplication: { _ in
                guard application.isVisible else { return nil }
                return .init(isFinishedLaunching: application.activations > 0) { application.activations += 1 }
            },
            currentVolume: { url in url == live.mountURL ? live : nil },
            isAuthorized: { true },
            sleep: { duration in
                await withCheckedContinuation { continuation in
                    delays.continuation.yield(PendingDelay(duration: duration, continuation: continuation))
                }
            }
        )

        retry.track(nil, at: appURL, startsNewLaunch: true)
        #expect(retry.task == nil)
        retry.track(first, at: appURL, startsNewLaunch: true)
        let originalTask = try #require(retry.task)
        let firstDelay = try #require(await delayIterator.next())
        #expect(firstDelay.duration == .seconds(1))
        firstDelay.continuation.resume()
        let originalLastDelay = try #require(await delayIterator.next())
        #expect(originalLastDelay.duration == .seconds(2))

        retry.track(hasSavedSecondEvent ? second : nil, at: appURL, startsNewLaunch: true)
        originalLastDelay.continuation.resume()
        await originalTask.value
        try #require(originalTask.isCancelled)
        let currentTask = try #require(retry.task)
        let newFirstDelay = try #require(await delayIterator.next())
        #expect(newFirstDelay.duration == .seconds(1))

        application.isVisible = true
        retry.track(third, at: appURL, startsNewLaunch: false)
        newFirstDelay.continuation.resume()
        let newLastDelay = try #require(await delayIterator.next())
        #expect(newLastDelay.duration == .seconds(2))
        #expect(application.activations == 1)
        newLastDelay.continuation.resume()
        await currentTask.value

        #expect(application.activations == 1)
        #expect(retry.task == nil)
    }

    @Test("A former helper cannot activate after another copy takes ownership", arguments: [true, false])
    func rechecksAuthorization(hasAuthorizationFile: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("agent-state.json")
        let store = BackgroundPromptAgentStateStore(fileURL: stateURL)
        let agentPath = "/Applications/SD Card Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        if hasAuthorizationFile {
            try store.authorize(agentBuild: "39", agentBundlePath: agentPath)
        }
        try store.recordLaunch(agentBuild: "39", agentBundlePath: agentPath)
        let sequence = try store.issueEventSequence(agentBuild: "39", agentBundlePath: agentPath)
        #expect(try store.canHandleMountEvents(agentBuild: "39", agentBundlePath: agentPath))
        let card = volume(named: "Card A")
        var activations = 0
        let retry = BackgroundPromptColdLaunchRetry(
            findApplication: { _ in
                .init(isFinishedLaunching: false) { activations += 1 }
            },
            currentVolume: { _ in card },
            isAuthorized: {
                (try? store.canHandleMountEvents(agentBuild: "39", agentBundlePath: agentPath)) == true
            },
            sleep: { _ in
                let updatedStore = BackgroundPromptAgentStateStore(fileURL: stateURL)
                if hasAuthorizationFile {
                    try updatedStore.authorize(agentBuild: "40", agentBundlePath: agentPath)
                } else {
                    try updatedStore.recordLaunch(agentBuild: "40", agentBundlePath: agentPath)
                }
            }
        )

        retry.track(card, at: appURL, startsNewLaunch: true)
        let task = try #require(retry.task)
        await task.value

        #expect(try !store.canHandleMountEvents(agentBuild: "39", agentBundlePath: agentPath))
        if !hasAuthorizationFile {
            #expect(try store.canHandleMountEvents(agentBuild: "40", agentBundlePath: agentPath))
        }
        #expect(try store.load()?.lastIssuedSequence == sequence)
        #expect(activations == 0)
    }

    @Test("A replacement with a missing UUID cannot reuse a UUID-bearing mount")
    func replacementFailsIdentityCheck() async throws {
        let card = volume(named: "Card A")
        let replacement = volume(named: "Card A", uuid: nil)
        var activations = 0
        let retry = BackgroundPromptColdLaunchRetry(
            findApplication: { _ in
                .init(isFinishedLaunching: false) { activations += 1 }
            },
            currentVolume: { _ in replacement },
            isAuthorized: { true },
            sleep: { _ in }
        )

        #expect(replacement.isSameMount(as: card))
        retry.track(card, at: appURL, startsNewLaunch: true)
        let task = try #require(retry.task)
        await task.value

        #expect(activations == 0)
    }

    @Test("An unmount invalidates an ambiguous or conflicting candidate", arguments: [false, true])
    func unmountInvalidatesPendingOccurrence(hasConflictingMediaID: Bool) async throws {
        let removed = volume(
            named: "Card A",
            uuid: hasConflictingMediaID ? "cloned-uuid" : nil,
            mediaID: hasConflictingMediaID ? 17 : nil
        )
        let atRemovedPath = hasConflictingMediaID
            ? volume(named: "Card A", uuid: "cloned-uuid", mediaID: 18)
            : removed
        let live = volume(named: "Card B")
        var observedPaths: [String] = []
        var activations = 0
        let retry = BackgroundPromptColdLaunchRetry(
            findApplication: { _ in
                .init(isFinishedLaunching: activations > 0) { activations += 1 }
            },
            currentVolume: { url in
                observedPaths.append(url.path)
                return url == removed.mountURL ? atRemovedPath : live
            },
            isAuthorized: { true },
            sleep: { _ in }
        )

        retry.track(removed, at: appURL, startsNewLaunch: true)
        retry.track(live, at: appURL, startsNewLaunch: false)
        retry.removeVolume(at: removed.mountURL, preserving: atRemovedPath)
        let task = try #require(retry.task)
        await task.value

        #expect(observedPaths == [live.mountPath])
        #expect(activations == 1)
    }

    @Test("A delayed unmount leaves the current replacement eligible", arguments: [true, false])
    func delayedUnmountPreservesCurrentMount(hasMediaIDs: Bool) async throws {
        let first = volume(named: "Card", uuid: "card-a", mediaID: hasMediaIDs ? 17 : nil)
        let replacement = volume(named: "Card", uuid: "card-b", mediaID: hasMediaIDs ? 18 : nil)
        var activations = 0
        let retry = BackgroundPromptColdLaunchRetry(
            findApplication: { _ in
                .init(isFinishedLaunching: activations > 0) { activations += 1 }
            },
            currentVolume: { _ in replacement },
            isAuthorized: { true },
            sleep: { _ in }
        )

        retry.track(first, at: appURL, startsNewLaunch: true)
        retry.track(replacement, at: appURL, startsNewLaunch: false)
        retry.removeVolume(at: first.mountURL, preserving: replacement)
        let task = try #require(retry.task)
        await task.value

        #expect(activations == 1)
    }

    private func volume(named name: String, uuid: String? = "filesystem-id", mediaID: UInt64? = nil) -> MountedVolume {
        let url = URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true)
        return MountedVolume(
            id: uuid ?? url.path,
            name: name,
            mountURL: url,
            volumeUUID: uuid,
            isRemovable: true,
            wholeDiskIdentifier: "disk20",
            mediaRegistryID: mediaID
        )
    }
}

@MainActor
private final class SimulatedApplication {
    var isVisible = false
    var activations = 0
}

private struct PendingDelay: Sendable {
    let duration: Duration
    let continuation: CheckedContinuation<Void, Never>
}
