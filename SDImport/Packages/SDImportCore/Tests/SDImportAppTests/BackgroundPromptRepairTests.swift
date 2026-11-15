import Foundation
import SDImportCommerce
import SDImportCore
import Testing

@testable import SDImportApp

@MainActor
struct BackgroundPromptRepairTests {
    @Test("concurrent registration still requires new launch evidence")
    func concurrentRegistrationRejectsOldLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.recordLaunch(offset: -60)
        fixture.service.didUnregister = { [service = fixture.service] in
            service.status = .enabled
        }

        fixture.model.refreshBackgroundPromptHealth()
        #expect(fixture.model.backgroundPromptStatusTitle == L10n.tr("Running"))
        fixture.model.repairBackgroundPrompt()
        let repair = try #require(fixture.model.backgroundPromptOperationTask)
        try await fixture.waitForSleep(.milliseconds(500))

        #expect(fixture.model.isRepairingBackgroundPrompt)
        #expect(fixture.service.registerCalls == 0)
        #expect(fixture.model.backgroundPromptStatusTitle != L10n.tr("Running"))

        try fixture.recordLaunch()
        try await fixture.advance(.milliseconds(500))
        await repair.value
        #expect(!fixture.model.isRepairingBackgroundPrompt)
        #expect(fixture.model.backgroundPromptStatusTitle == L10n.tr("Running"))
    }

    @Test("a newer agent diagnostic preserves the launch timeout and automatic retry")
    func agentErrorDoesNotEraseLaunchTimeout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.recordLaunch(offset: -60)
        fixture.model.hasCompletedOnboarding = true

        fixture.model.refreshBackgroundPromptHealth()
        fixture.model.repairBackgroundPrompt()
        let repair = try #require(fixture.model.backgroundPromptOperationTask)
        try await fixture.advancePollingWindow()
        await repair.value

        let timeout = L10n.tr("The background helper did not become ready in time.")
        #expect(fixture.model.backgroundPromptStatusDetail == timeout)
        try await waitUntil { fixture.service.unregisterCalls == 2 }
        try await fixture.waitForSleep(.milliseconds(500))

        let previousState = try #require(try fixture.store.load())
        let timeoutSequence = try fixture.store.reserveDiagnosticSequence(
            agentBuild: fixture.build,
            agentBundlePath: fixture.agentPath
        )
        let agentError = "Could not persist a mounted-card event"
        try fixture.store.recordError(agentBuild: fixture.build, agentBundlePath: fixture.agentPath, message: agentError)
        let errorState = try #require(try fixture.store.load())
        #expect(errorState.lastErrorSequence ?? 0 > timeoutSequence)
        #expect(errorState.launchedAtEpoch == previousState.launchedAtEpoch)
        fixture.model.refreshBackgroundPromptHealth()
        #expect(fixture.model.backgroundPromptStatusDetail == timeout)

        try await fixture.advancePollingWindow()
        try await waitUntil { await fixture.sleeps.hasRetryDelay() }
        #expect(fixture.model.backgroundPromptStatusDetail == timeout)

        try Data("{".utf8).write(to: fixture.store.fileURL, options: .atomic)
        fixture.model.refreshBackgroundPromptHealth()
        #expect(fixture.model.backgroundPromptStatusDetail == L10n.tr("Could not read background helper diagnostics"))
        try fixture.recordLaunch(offset: -60)
        fixture.model.refreshBackgroundPromptHealth()
        #expect(fixture.model.backgroundPromptStatusDetail == timeout)

        try fixture.recordLaunch()
        fixture.model.refreshBackgroundPromptHealth()
        #expect(fixture.model.backgroundPromptStatusTitle == L10n.tr("Running"))
        try await waitUntil { await !fixture.sleeps.hasRetryDelay() }
    }

    @Test("repair clears previous helper feedback and preserves unrelated status")
    func previousHelperFeedbackClears() async throws {
        let fixture = try Fixture(enabled: false, serviceStatus: .notRegistered)
        defer { fixture.cleanUp() }
        fixture.service.registerError = FixtureError.registrationFailed

        #expect(fixture.model.setAutoPromptEnabled(true))
        await fixture.model.backgroundPromptOperationTask?.value
        let message = L10n.tr("Could not update background prompt: \(FixtureError.registrationFailed.localizedDescription)")
        #expect(fixture.model.statusMessage == message)
        #expect(fixture.model.settingsFeedback?.message == message)

        fixture.service.registerError = nil
        fixture.model.repairBackgroundPrompt()
        let repair = try #require(fixture.model.backgroundPromptOperationTask)
        #expect(fixture.model.isRepairingBackgroundPrompt)
        #expect(fixture.model.statusMessage.isEmpty)
        #expect(fixture.model.settingsFeedback == nil)

        let unrelatedStatus = "An unrelated app message"
        fixture.model.statusMessage = unrelatedStatus
        try await fixture.waitForSleep(.milliseconds(500))
        try fixture.recordLaunch()
        try await fixture.advance(.milliseconds(500))
        await repair.value

        #expect(fixture.model.statusMessage == unrelatedStatus)
        #expect(fixture.model.settingsFeedback == nil)
        #expect(fixture.model.backgroundPromptStatusTitle == L10n.tr("Running"))
        fixture.model.repairBackgroundPrompt()
        #expect(fixture.model.statusMessage == unrelatedStatus)
        try await fixture.waitForSleep(.milliseconds(500))
        try fixture.recordLaunch()
        try await fixture.advance(.milliseconds(500))
        await fixture.model.backgroundPromptOperationTask?.value
    }

    @Test("automatic recovery resumes after a diagnostics failure interrupts its poll")
    func automaticRetryResumesAfterReadFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.hasCompletedOnboarding = true
        try fixture.recordLaunch(offset: -60)
        fixture.model.refreshBackgroundPromptHealth()
        fixture.model.repairBackgroundPrompt()
        let repair = try #require(fixture.model.backgroundPromptOperationTask)
        try await fixture.advancePollingWindow()
        await repair.value

        let firstPoll = Duration.milliseconds(500)
        try await waitUntil { fixture.service.unregisterCalls == 2 }
        try await fixture.waitForSleep(firstPoll)
        #expect(await !fixture.sleeps.hasRetryDelay())

        try Data("{".utf8).write(to: fixture.store.fileURL, options: .atomic)
        fixture.model.refreshBackgroundPromptHealth()
        try await waitUntil { await fixture.sleeps.cancelled.contains(firstPoll) }
        #expect(fixture.model.backgroundPromptStatusDetail == L10n.tr("Could not read background helper diagnostics"))

        // One cooldown elapses while diagnostics are still unreadable.
        try await fixture.advanceRetryDelay()
        try await waitUntil { await fixture.sleeps.hasRetryDelay() }
        #expect(fixture.service.unregisterCalls == 2)

        // No manual refresh is needed after diagnostics become readable.
        try fixture.recordLaunch(offset: -60)
        try await fixture.advanceRetryDelay()
        try await fixture.waitForSleep(firstPoll)
        #expect(fixture.service.unregisterCalls == 3)
        #expect(fixture.model.backgroundPromptStatusDetail == L10n.tr("The background helper did not become ready in time."))

        try fixture.recordLaunch()
        try await fixture.advance(firstPoll)
        try await waitUntil { fixture.model.backgroundPromptStatusTitle == L10n.tr("Running") }
        #expect(await !fixture.sleeps.hasRetryDelay())
    }

    @Test("a second repair timeout reports the current launch record")
    func repeatedRepairUpdatesTimeoutDiagnosis() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.store.recordLaunch(
            agentBuild: fixture.build,
            agentBundlePath: "/Applications/Older Copy.app/Contents/Library/LoginItems/SDImportAgent.app",
            now: Date().addingTimeInterval(-120)
        )
        fixture.model.refreshBackgroundPromptHealth()
        fixture.model.repairBackgroundPrompt()
        let firstRepair = try #require(fixture.model.backgroundPromptOperationTask)
        try await fixture.advancePollingWindow()
        await firstRepair.value
        #expect(fixture.model.backgroundPromptStatusDetail == L10n.tr(
            "The registered background helper is still reporting from an older or different app copy."
        ))

        try fixture.recordLaunch(offset: -60)
        fixture.model.refreshBackgroundPromptHealth()
        fixture.model.repairBackgroundPrompt()
        let secondRepair = try #require(fixture.model.backgroundPromptOperationTask)
        try await fixture.advancePollingWindow()
        await secondRepair.value
        #expect(fixture.model.backgroundPromptStatusDetail == L10n.tr("The background helper did not become ready in time."))
    }

    @Test("an external diagnostics read failure wakes repair during its longest backoff")
    func externalReadFailureInterruptsSleep() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.refreshBackgroundPromptHealth()
        fixture.model.repairBackgroundPrompt()

        for delay in BackgroundPromptHealth.refreshDelayMilliseconds.dropLast() {
            try await fixture.advance(.milliseconds(delay))
        }
        let lastDelay = try #require(BackgroundPromptHealth.refreshDelayMilliseconds.last)
        let pendingDelay = Duration.milliseconds(lastDelay)
        try await fixture.waitForSleep(pendingDelay)

        try Data("{".utf8).write(to: fixture.store.fileURL, options: .atomic)
        // This is also the refresh called by AppModel's foreground mount handler.
        fixture.model.refreshBackgroundPromptHealth()
        try await waitUntil { !fixture.model.isRepairingBackgroundPrompt }
        let cancelled = await fixture.sleeps.cancelled
        #expect(cancelled.contains(pendingDelay))
        #expect(fixture.model.backgroundPromptStatusTitle == L10n.tr("Needs attention"))
        #expect(fixture.model.backgroundPromptStatusDetail == L10n.tr("Could not read background helper diagnostics"))
    }
}

private enum FixtureError: LocalizedError {
    case registrationFailed

    var errorDescription: String? { "Registration unavailable in test" }
}

@MainActor
private final class Fixture {
    let model: AppModel
    let store: BackgroundPromptAgentStateStore
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    let agentPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/LoginItems/SDImportAgent.app", isDirectory: true)
        .standardizedFileURL.path
    let service: TestLoginItem
    let sleeps = TestSleeps()
    private let suiteName = "SDImportAppTests.backgroundPrompt.\(UUID())"
    private let defaults: UserDefaults
    private let directory: URL

    init(enabled: Bool = true, serviceStatus: BackgroundPromptServiceStatus = .enabled) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let store = BackgroundPromptAgentStateStore(fileURL: directory.appendingPathComponent("agent-state.json"))
        self.store = store
        service = TestLoginItem(status: serviceStatus)
        model = AppModel(
            purchaseManager: PurchaseManager(startsStoreTask: false),
            defaults: defaults,
            loginItem: service.controller,
            backgroundPromptStateStore: { store },
            backgroundPromptSleep: { [sleeps] in try await sleeps.sleep(for: $0) },
            startsBootstrap: false
        )
        model.autoPromptEnabled = enabled
    }

    func cleanUp() {
        model.autoPromptEnabled = false
        model.refreshBackgroundPromptHealth()
        service.didUnregister = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        Task { await sleeps.stop() }
    }

    func recordLaunch(offset: TimeInterval = 0) throws {
        try store.recordLaunch(agentBuild: build, agentBundlePath: agentPath, now: Date().addingTimeInterval(offset))
    }

    func waitForSleep(_ duration: Duration) async throws {
        try await waitUntil { await self.sleeps.isWaiting(for: duration) }
    }

    func advance(_ duration: Duration) async throws {
        try await waitForSleep(duration)
        let resumed = await sleeps.resume(duration)
        try #require(resumed)
    }

    func advancePollingWindow() async throws {
        for delay in BackgroundPromptHealth.refreshDelayMilliseconds {
            try await advance(.milliseconds(delay))
        }
    }

    func advanceRetryDelay() async throws {
        try await waitUntil { await self.sleeps.hasRetryDelay() }
        let resumed = await sleeps.resumeRetryDelay()
        try #require(resumed)
    }
}

@MainActor
private final class TestLoginItem {
    var status: BackgroundPromptServiceStatus
    var registerError: FixtureError?
    var didUnregister: (() -> Void)?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: BackgroundPromptServiceStatus) {
        self.status = status
    }

    var controller: LoginItemController {
        let path = Bundle.main.bundleURL.path
        return LoginItemController(
            readStatus: { self.status },
            readApplicationOwnership: {
                BackgroundPromptApplicationOwnership(currentApplicationPath: path, authoritativeApplicationPath: path)
            },
            invalidateApplicationOwnershipCache: {},
            hasEmbeddedAgent: { true },
            register: {
                self.registerCalls += 1
                if let error = self.registerError {
                    throw error
                }
                self.status = .enabled
            },
            unregister: {
                self.unregisterCalls += 1
                self.status = .notRegistered
                await Task.yield()
                self.didUnregister?()
            }
        )
    }
}

private actor TestSleeps {
    private var pending: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    private var stopped = false
    private(set) var cancelled: [Duration] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if stopped || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pending[id] = (duration, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func isWaiting(for duration: Duration) -> Bool {
        pending.values.contains { $0.0 == duration }
    }

    func hasRetryDelay() -> Bool {
        pending.values.contains { $0.0 > .seconds(8) }
    }

    func resume(_ duration: Duration) -> Bool {
        resumeSleep { $0 == duration }
    }

    func resumeRetryDelay() -> Bool {
        resumeSleep { $0 > .seconds(8) }
    }

    private func resumeSleep(where matches: (Duration) -> Bool) -> Bool {
        guard let id = pending.first(where: { matches($0.value.0) })?.key,
              let (_, continuation) = pending.removeValue(forKey: id) else {
            return false
        }
        continuation.resume()
        return true
    }

    private func cancel(_ id: UUID) {
        if let (duration, continuation) = pending.removeValue(forKey: id) {
            cancelled.append(duration)
            continuation.resume(throwing: CancellationError())
        }
    }

    func stop() {
        stopped = true
        for id in Array(pending.keys) {
            cancel(id)
        }
    }
}

@MainActor
private func waitUntil(_ predicate: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
        try #require(clock.now < deadline, "AppModel did not reach the expected state")
        try await Task.sleep(for: .milliseconds(2))
    }
}
