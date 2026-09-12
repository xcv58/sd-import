import Foundation
import Testing

@testable import SDImportCore

@Suite("Background prompt registration")
struct BackgroundPromptRegistrationTests {
    @Test("registration policy covers every desired-state and service-state combination")
    func registrationPolicyMatrix() {
        let enabledExpectations: [BackgroundPromptServiceStatus: BackgroundPromptReconciliationAction] = [
            .notRegistered: .register,
            .enabled: .none,
            .requiresApproval: .requestApproval,
            .notFound: .register,
            .unknown: .none
        ]
        let disabledExpectations: [BackgroundPromptServiceStatus: BackgroundPromptReconciliationAction] = [
            .notRegistered: .none,
            .enabled: .unregister,
            .requiresApproval: .unregister,
            .notFound: .none,
            .unknown: .none
        ]

        for status in BackgroundPromptServiceStatus.allCases {
            #expect(
                BackgroundPromptRegistrationPolicy.action(
                    desiredEnabled: true,
                    serviceStatus: status
                ) == enabledExpectations[status]
            )
            #expect(
                BackgroundPromptRegistrationPolicy.action(
                    desiredEnabled: false,
                    serviceStatus: status
                ) == disabledExpectations[status]
            )
        }

        #expect(
            BackgroundPromptRegistrationPolicy.action(
                desiredEnabled: true,
                serviceStatus: .notFound,
                embeddedHelperExists: false
            ) == .reportMissingHelper
        )
        #expect(
            BackgroundPromptRegistrationPolicy.action(
                desiredEnabled: true,
                serviceStatus: .notFound,
                embeddedHelperExists: true,
                allowNotFoundRegistration: false
            ) == .none
        )
    }

    @Test("helper refresh policy repairs missing, old-build, and wrong-copy agents once per app identity")
    func helperRefreshPolicy() {
        let expectedPath = "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        let expectedIdentity = BackgroundPromptRepairIdentity(
            appBuild: "44",
            applicationPath: "/Applications/SD Import.app",
            agentBundlePath: expectedPath
        )
        let matchingState = BackgroundPromptAgentState(
            agentBuild: "44",
            agentBundlePath: expectedPath,
            launchedAt: Date()
        )
        let oldState = BackgroundPromptAgentState(
            agentBuild: "43",
            agentBundlePath: expectedPath,
            launchedAt: Date()
        )
        let wrongCopyState = BackgroundPromptAgentState(
            agentBuild: "44",
            agentBundlePath: "/Users/tester/Downloads/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app",
            launchedAt: Date()
        )

        #expect(shouldRefresh(state: nil, lastRepairIdentity: nil))
        #expect(shouldRefresh(state: oldState, lastRepairIdentity: nil))
        #expect(shouldRefresh(state: wrongCopyState, lastRepairIdentity: nil))
        #expect(!shouldRefresh(state: matchingState, lastRepairIdentity: nil))
        #expect(!shouldRefresh(state: nil, lastRepairIdentity: expectedIdentity))
        #expect(
            shouldRefresh(
                state: nil,
                lastRepairIdentity: BackgroundPromptRepairIdentity(
                    appBuild: "44",
                    applicationPath: "/Users/tester/Downloads/SD Import.app",
                    agentBundlePath: "/Users/tester/Downloads/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
                )
            )
        )
        #expect(
            BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
                desiredEnabled: true,
                serviceStatus: .notFound,
                embeddedHelperExists: true,
                state: nil,
                expectedIdentity: expectedIdentity,
                lastRepairIdentity: nil
            )
        )
        #expect(
            !BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
                desiredEnabled: true,
                serviceStatus: .notFound,
                embeddedHelperExists: false,
                state: nil,
                expectedIdentity: expectedIdentity,
                lastRepairIdentity: nil
            )
        )
        #expect(
            !BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
                desiredEnabled: false,
                serviceStatus: .enabled,
                state: oldState,
                expectedIdentity: expectedIdentity,
                lastRepairIdentity: nil
            )
        )

        func shouldRefresh(
            state: BackgroundPromptAgentState?,
            lastRepairIdentity: BackgroundPromptRepairIdentity?
        ) -> Bool {
            BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
                desiredEnabled: true,
                serviceStatus: .enabled,
                state: state,
                expectedIdentity: expectedIdentity,
                lastRepairIdentity: lastRepairIdentity
            )
        }
    }

    @Test("installed-copy ownership prefers system Applications and the canonical app name")
    func installedCopyOwnershipIsDeterministic() {
        let userRoot = "/Users/tester/Applications"
        let paths = [
            "/Users/tester/Downloads/SD Import.app",
            "/Users/tester/Applications/Renamed SD Import.app",
            "/Users/tester/Applications/SD Import.app",
            "/Applications/Renamed SD Import.app",
            "/Applications/SD Import.app"
        ]

        let ownership = BackgroundPromptApplicationOwnershipPolicy.ownership(
            currentApplicationPath: paths[0],
            candidateApplicationPaths: paths,
            userApplicationsPath: userRoot
        )

        #expect(ownership.authoritativeApplicationPath == "/Applications/SD Import.app")
        #expect(!ownership.isCurrentApplicationAuthoritative)
    }

    @Test("installed-copy ownership matches Applications roots case-insensitively")
    func installedCopyOwnershipMatchesRootCaseInsensitively() {
        let ownership = BackgroundPromptApplicationOwnershipPolicy.ownership(
            currentApplicationPath: "/case-insensitive-root/SD Import.app",
            candidateApplicationPaths: ["/case-insensitive-root/SD Import.app"],
            systemApplicationsPath: "/CASE-INSENSITIVE-ROOT",
            userApplicationsPath: "/Users/tester/Applications"
        )

        #expect(
            ownership.authoritativeApplicationPath == "/case-insensitive-root/SD Import.app"
        )
        #expect(ownership.isCurrentApplicationAuthoritative)
    }

    @Test("an uninstalled copy cannot become authoritative without an installed candidate")
    func uninstalledCopyRequiresInstallation() {
        let ownership = BackgroundPromptApplicationOwnershipPolicy.ownership(
            currentApplicationPath: "/Users/tester/Downloads/SD Import.app",
            candidateApplicationPaths: ["/Users/tester/Downloads/SD Import.app"],
            userApplicationsPath: "/Users/tester/Applications"
        )

        #expect(ownership.authoritativeApplicationPath == nil)
        #expect(!ownership.isCurrentApplicationAuthoritative)
    }

    @Test("same-build copies have distinct repair identities and live registration ownership")
    func repairIdentityIncludesApplicationPath() {
        let installedIdentity = BackgroundPromptRepairIdentity(
            appBuild: "44",
            applicationPath: "/Applications/SD Import.app",
            agentBundlePath: "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        )
        let downloadedIdentity = BackgroundPromptRepairIdentity(
            appBuild: "44",
            applicationPath: "/Users/tester/Downloads/SD Import.app",
            agentBundlePath: "/Users/tester/Downloads/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        )
        let liveState = BackgroundPromptAgentState(
            agentBuild: "44",
            agentBundlePath: installedIdentity.agentBundlePath,
            launchedAt: Date()
        )

        #expect(installedIdentity != downloadedIdentity)
        #expect(
            BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
                identity: installedIdentity,
                serviceStatus: .enabled,
                liveAgentState: liveState
            )
        )
        #expect(
            !BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
                identity: downloadedIdentity,
                serviceStatus: .enabled,
                liveAgentState: liveState
            )
        )
    }

    @Test("registration ownership requires a launch after the latest registration attempt")
    func registrationOwnershipRequiresFreshLaunch() {
        let identity = BackgroundPromptRepairIdentity(
            appBuild: "44",
            applicationPath: "/Applications/SD Import.app",
            agentBundlePath: "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        )
        let oldLaunch = Date(timeIntervalSince1970: 1_800_000_000)
        let attempt = oldLaunch.addingTimeInterval(30)
        let oldState = BackgroundPromptAgentState(
            agentBuild: "44",
            agentBundlePath: identity.agentBundlePath,
            launchedAt: oldLaunch,
            launchedAtEpoch: oldLaunch.timeIntervalSince1970
        )
        let freshState = BackgroundPromptAgentState(
            agentBuild: "44",
            agentBundlePath: identity.agentBundlePath,
            launchedAt: attempt.addingTimeInterval(1),
            launchedAtEpoch: attempt.addingTimeInterval(1).timeIntervalSince1970
        )

        #expect(
            !BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
                identity: identity,
                serviceStatus: .enabled,
                liveAgentState: oldState,
                minimumLaunchAt: attempt
            )
        )
        #expect(
            BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
                identity: identity,
                serviceStatus: .enabled,
                liveAgentState: freshState,
                minimumLaunchAt: attempt
            )
        )
    }

    @Test("same-second pre-attempt launch is not accepted as fresh")
    func launchFreshnessPreservesSubsecondOrdering() throws {
        let directory = try temporaryDirectory()
        let agentPath = "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        let identity = BackgroundPromptRepairIdentity(
            appBuild: "44",
            applicationPath: "/Applications/SD Import.app",
            agentBundlePath: agentPath
        )
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let second = 1_800_000_000.0
        let oldLaunch = Date(timeIntervalSince1970: second + 0.1)
        let attempt = Date(timeIntervalSince1970: second + 0.8)
        try store.recordLaunch(agentBuild: "44", agentBundlePath: agentPath, now: oldLaunch)
        let loadedOldState = try store.load()
        let oldState = try #require(loadedOldState)

        #expect(oldState.launchedAtEpoch == oldLaunch.timeIntervalSince1970)
        #expect(
            !BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
                identity: identity,
                serviceStatus: .enabled,
                liveAgentState: oldState,
                minimumLaunchAt: attempt
            )
        )

        let freshLaunch = Date(timeIntervalSince1970: second + 0.9)
        try store.recordLaunch(agentBuild: "44", agentBundlePath: agentPath, now: freshLaunch)
        let loadedFreshState = try store.load()
        let freshState = try #require(loadedFreshState)
        #expect(freshState.launchedAtEpoch == freshLaunch.timeIntervalSince1970)
        #expect(
            BackgroundPromptApplicationOwnershipPolicy.ownsRegistration(
                identity: identity,
                serviceStatus: .enabled,
                liveAgentState: freshState,
                minimumLaunchAt: attempt
            )
        )
    }

    @Test("repair waits for unregister completion before registering")
    func repairSequenceWaitsForUnregister() async throws {
        let recorder = RepairOperationRecorder()

        try await BackgroundPromptRepairSequence.execute(
            BackgroundPromptRepairSequence.operations(for: .enabled)
        ) { operation in
            switch operation {
            case .unregister:
                await recorder.append("unregister-start")
                try await Task.sleep(for: .milliseconds(20))
                await recorder.append("unregister-finished")
            case .register:
                await recorder.append("register")
            }
        }

        let operations = await recorder.values
        #expect(operations == ["unregister-start", "unregister-finished", "register"])
    }

    @Test("agent errors surface until a later handoff is acknowledged")
    func agentErrorsSurfaceAndRecover() throws {
        let directory = try temporaryDirectory()
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        try store.recordLaunch(
            agentBuild: "44",
            agentBundlePath: "/Applications/SD Import.app/Agent.app",
            now: launch
        )
        try store.recordError(
            agentBuild: "44",
            agentBundlePath: "/Applications/SD Import.app/Agent.app",
            message: "Could not launch the containing SD Import application",
            now: launch.addingTimeInterval(1)
        )

        let loadedState = try store.load()
        let failedState = try #require(loadedState)
        #expect(
            BackgroundPromptHealth.effectiveError(appError: nil, agentState: failedState)
                == L10n.tr("Could not launch the containing SD Import application")
        )
        #expect(
            BackgroundPromptHealth.appErrorAfterRefresh(
                existingError: BackgroundPromptHealth.missingLaunchError,
                agentState: failedState
            ) == nil
        )
        try store.recordLaunch(
            agentBuild: "44",
            agentBundlePath: "/Applications/SD Import.app/Agent.app",
            now: launch.addingTimeInterval(1.5)
        )
        #expect(try store.load()?.lastError != nil)

        try store.recordHandoff(
            agentBuild: "44",
            agentBundlePath: "/Applications/SD Import.app/Agent.app",
            eventSequence: 1,
            now: launch.addingTimeInterval(2)
        )
        #expect(try store.load()?.lastError != nil)
        try store.recordSuccessfulDelivery(
            agentBuild: "44",
            agentBundlePath: "/Users/tester/Downloads/SD Import.app/Agent.app",
            eventSequence: 2
        )
        #expect(try store.load()?.lastError != nil)
        try store.recordSuccessfulDelivery(
            agentBuild: "44",
            agentBundlePath: "/Applications/SD Import.app/Agent.app",
            eventSequence: 2
        )
        #expect(try store.load()?.lastError == nil)
    }

    @Test("a stale refresh cannot erase a newer app error")
    func staleRefreshCannotEraseNewError() {
        var generations = BackgroundPromptHealthRefreshGeneration()
        let staleGeneration = generations.begin()
        generations.invalidate()
        let newerError = "Could not acknowledge a background prompt event"

        #expect(!generations.isCurrent(staleGeneration))
        #expect(
            BackgroundPromptHealth.appErrorAfterRefresh(
                existingError: newerError,
                agentState: nil
            ) == newerError
        )
    }

    @Test("agent state records launch and later handoff without losing launch time")
    func agentStateLifecycle() throws {
        let directory = try temporaryDirectory()
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let handoff = launch.addingTimeInterval(30)

        let bundlePath = "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        try store.recordLaunch(agentBuild: "44", agentBundlePath: bundlePath, now: launch)
        try store.recordHandoff(
            agentBuild: "44",
            agentBundlePath: bundlePath,
            eventSequence: 1,
            now: handoff
        )

        let loadedState = try store.load()
        let state = try #require(loadedState)
        #expect(state.agentBuild == "44")
        #expect(state.agentBundlePath == bundlePath)
        #expect(state.launchedAt == launch)
        #expect(state.lastHandoffAt == handoff)
        #expect(state.lastError == nil)
    }

    @Test("agent state remains compatible with records written before bundle paths were tracked")
    func legacyAgentStateDecodes() throws {
        let data = Data(
            """
            {
              "agentBuild": "43",
              "launchedAt": "2026-07-25T20:00:00Z"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let state = try decoder.decode(BackgroundPromptAgentState.self, from: data)

        #expect(state.agentBuild == "43")
        #expect(state.agentBundlePath == nil)
        #expect(state.lastIssuedSequence == 0)
        #expect(state.lastErrorSequence == nil)
        #expect(state.lastSuccessfulSequence == nil)
    }

    @Test("an older acknowledgement cannot erase a newer helper error")
    func acknowledgementClearsOnlyCausallyOlderErrors() throws {
        let directory = try temporaryDirectory()
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let path = "/Applications/SD Import.app/Agent.app"
        try store.recordLaunch(agentBuild: "44", agentBundlePath: path)
        let first = try store.issueEventSequence(agentBuild: "44", agentBundlePath: path)
        let second = try store.issueEventSequence(agentBuild: "44", agentBundlePath: path)
        try store.recordError(
            agentBuild: "44",
            agentBundlePath: path,
            message: "newer failure",
            eventSequence: second
        )

        try store.recordSuccessfulDelivery(
            agentBuild: "44",
            agentBundlePath: path,
            eventSequence: first
        )
        #expect(try store.load()?.lastError == "newer failure")

        let third = try store.issueEventSequence(agentBuild: "44", agentBundlePath: path)
        try store.recordSuccessfulDelivery(
            agentBuild: "44",
            agentBundlePath: path,
            eventSequence: third
        )
        #expect(try store.load()?.lastError == nil)
    }

    @Test("an older error callback cannot replace a newer helper error")
    func olderErrorCannotReplaceNewerError() throws {
        let directory = try temporaryDirectory()
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let path = "/Applications/SD Import.app/Agent.app"
        try store.recordLaunch(agentBuild: "44", agentBundlePath: path)
        let first = try store.issueEventSequence(agentBuild: "44", agentBundlePath: path)
        let second = try store.issueEventSequence(agentBuild: "44", agentBundlePath: path)

        try store.recordError(
            agentBuild: "44",
            agentBundlePath: path,
            message: "newer failure",
            eventSequence: second
        )
        try store.recordError(
            agentBuild: "44",
            agentBundlePath: path,
            message: "delayed older failure",
            eventSequence: first
        )

        #expect(try store.load()?.lastError == "newer failure")
        #expect(try store.load()?.lastErrorSequence == second)
    }

    @Test("an unsequenced error reserves a barrier after issued events")
    func unsequencedErrorReservesCausalBarrier() throws {
        let directory = try temporaryDirectory()
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let path = "/Applications/SD Import.app/Agent.app"
        try store.recordLaunch(agentBuild: "44", agentBundlePath: path)
        let oldEvent = try store.issueEventSequence(agentBuild: "44", agentBundlePath: path)

        try store.recordError(
            agentBuild: "44",
            agentBundlePath: path,
            message: "mailbox failed after the event was issued"
        )
        let errorSequence = try #require(store.load()?.lastErrorSequence)
        #expect(errorSequence > oldEvent)

        try store.recordSuccessfulDelivery(
            agentBuild: "44",
            agentBundlePath: path,
            eventSequence: oldEvent
        )
        #expect(try store.load()?.lastError == "mailbox failed after the event was issued")

        let futureEvent = try store.issueEventSequence(agentBuild: "44", agentBundlePath: path)
        #expect(futureEvent > errorSequence)
        try store.recordSuccessfulDelivery(
            agentBuild: "44",
            agentBundlePath: path,
            eventSequence: futureEvent
        )
        #expect(try store.load()?.lastError == nil)
    }

    @Test("retry policy waits only for the remaining cooldown")
    func retryPolicyUsesRemainingCooldown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = BackgroundPromptRegistrationPolicy.notFoundRepairRetryInterval

        #expect(BackgroundPromptRetryPolicy.remainingDelay(lastAttemptAt: nil, now: now) == 0)
        #expect(
            BackgroundPromptRetryPolicy.remainingDelay(
                lastAttemptAt: now.addingTimeInterval(-60),
                now: now
            ) == interval - 60
        )
        #expect(
            BackgroundPromptRetryPolicy.remainingDelay(
                lastAttemptAt: now.addingTimeInterval(-interval),
                now: now
            ) == 0
        )
    }

    @Test("current-build missing registration retries with a cooldown")
    func missingCurrentBuildRegistrationRetriesWithCooldown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = BackgroundPromptRepairIdentity(
            appBuild: "44",
            applicationPath: "/Applications/SD Import.app",
            agentBundlePath: "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        )

        #expect(
            BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
                desiredEnabled: true,
                serviceStatus: .notFound,
                state: nil,
                expectedIdentity: identity,
                lastRepairIdentity: identity,
                lastNotFoundRepairAttemptAt: nil,
                now: now
            )
        )
        #expect(
            !BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
                desiredEnabled: true,
                serviceStatus: .notFound,
                state: nil,
                expectedIdentity: identity,
                lastRepairIdentity: identity,
                lastNotFoundRepairAttemptAt: now,
                now: now.addingTimeInterval(60)
            )
        )
        #expect(
            BackgroundPromptRegistrationPolicy.shouldRefreshHelper(
                desiredEnabled: true,
                serviceStatus: .notFound,
                state: nil,
                expectedIdentity: identity,
                lastRepairIdentity: identity,
                lastNotFoundRepairAttemptAt: now,
                now: now.addingTimeInterval(
                    BackgroundPromptRegistrationPolicy.notFoundRepairRetryInterval
                )
            )
        )
        #expect(
            !BackgroundPromptRegistrationPolicy.allowsNotFoundRegistration(
                lastAttemptAt: now,
                now: now.addingTimeInterval(60)
            )
        )
        #expect(
            !BackgroundPromptRegistrationPolicy.shouldAttemptMissingRegistration(
                desiredEnabled: true,
                serviceStatus: .notFound,
                lastAttemptAt: now,
                now: now.addingTimeInterval(60)
            )
        )
        #expect(
            !BackgroundPromptRegistrationPolicy.shouldAttemptMissingRegistration(
                desiredEnabled: true,
                serviceStatus: .notRegistered,
                lastAttemptAt: now,
                now: now.addingTimeInterval(60)
            )
        )
        #expect(
            BackgroundPromptRegistrationPolicy.allowsNotFoundRegistration(
                lastAttemptAt: now,
                now: now.addingTimeInterval(
                    BackgroundPromptRegistrationPolicy.notFoundRepairRetryInterval
                )
            )
        )
    }

    @Test("authoritative app observes repair-window mounts and defers while busy")
    func deliveryPolicyCoversRepairWindowAndBusyState() {
        #expect(
            BackgroundPromptDeliveryPolicy.canObserveDirectMount(
                desiredEnabled: true,
                hasCompletedOnboarding: true,
                isAuthoritativeApplication: true
            )
        )
        #expect(
            !BackgroundPromptDeliveryPolicy.canCommitPrompt(
                desiredEnabled: true,
                hasCompletedOnboarding: true,
                isWorking: true,
                hasPendingPrompt: false
            )
        )
        #expect(
            !BackgroundPromptDeliveryPolicy.canCommitPrompt(
                desiredEnabled: true,
                hasCompletedOnboarding: true,
                isWorking: false,
                hasPendingPrompt: true
            )
        )
        #expect(
            BackgroundPromptDeliveryPolicy.canCommitPrompt(
                desiredEnabled: true,
                hasCompletedOnboarding: true,
                isWorking: false,
                hasPendingPrompt: false
            )
        )
    }

    @Test("a same-event success clears an earlier error for that event")
    func sameEventSuccessClearsError() throws {
        let directory = try temporaryDirectory()
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let path = "/Applications/SD Import.app/Agent.app"
        try store.recordLaunch(agentBuild: "44", agentBundlePath: path)
        let sequence = try store.issueEventSequence(agentBuild: "44", agentBundlePath: path)
        try store.recordError(
            agentBuild: "44",
            agentBundlePath: path,
            message: "launch reported an error",
            eventSequence: sequence
        )

        try store.recordSuccessfulDelivery(
            agentBuild: "44",
            agentBundlePath: path,
            eventSequence: sequence
        )

        #expect(try store.load()?.lastError == nil)

        try store.recordError(
            agentBuild: "44",
            agentBundlePath: path,
            message: "delayed obsolete failure",
            eventSequence: sequence
        )
        #expect(try store.load()?.lastError == nil)
    }

    @Test("late callbacks from an old helper cannot replace the current helper identity")
    func staleHelperCallbacksAreIgnored() throws {
        let directory = try temporaryDirectory()
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let oldPath = "/Users/tester/Downloads/SD Import.app/Agent.app"
        let currentPath = "/Applications/SD Import.app/Agent.app"
        try store.authorize(agentBuild: "44", agentBundlePath: currentPath)
        try store.recordLaunch(agentBuild: "44", agentBundlePath: currentPath)
        try store.recordError(
            agentBuild: "44",
            agentBundlePath: currentPath,
            message: "current-helper failure",
            eventSequence: 1
        )

        var rejectedOldSequence = false
        var rejectedOldLaunch = false
        do {
            try store.recordLaunch(agentBuild: "43", agentBundlePath: oldPath)
        } catch BackgroundPromptAgentStateStore.StoreError.staleAgentIdentity {
            rejectedOldLaunch = true
        }
        do {
            _ = try store.issueEventSequence(agentBuild: "43", agentBundlePath: oldPath)
        } catch BackgroundPromptAgentStateStore.StoreError.staleAgentIdentity {
            rejectedOldSequence = true
        }
        try store.recordHandoff(
            agentBuild: "43",
            agentBundlePath: oldPath,
            eventSequence: 99
        )
        try store.recordError(
            agentBuild: "43",
            agentBundlePath: oldPath,
            message: "late old-helper failure",
            eventSequence: 99
        )

        let loadedState = try store.load()
        let state = try #require(loadedState)
        #expect(rejectedOldLaunch)
        #expect(rejectedOldSequence)
        #expect(state.agentBuild == "44")
        #expect(state.agentBundlePath == currentPath)
        #expect(state.lastError == "current-helper failure")
    }

    @Test("authorization blocks a late old-helper acknowledgement before current launch")
    func staleHelperAcknowledgementIsIgnored() throws {
        let directory = try temporaryDirectory()
        let store = BackgroundPromptAgentStateStore(
            fileURL: directory.appendingPathComponent("agent-state.json")
        )
        let oldPath = "/Users/tester/Downloads/SD Import.app/Agent.app"
        let currentPath = "/Applications/SD Import.app/Agent.app"
        try store.recordLaunch(agentBuild: "43", agentBundlePath: oldPath)
        try store.recordError(
            agentBuild: "43",
            agentBundlePath: oldPath,
            message: "old-helper failure",
            eventSequence: 1
        )
        try store.authorize(agentBuild: "44", agentBundlePath: currentPath)

        try store.recordSuccessfulDelivery(
            agentBuild: "43",
            agentBundlePath: oldPath,
            eventSequence: 1
        )

        let loadedState = try store.load()
        let state = try #require(loadedState)
        #expect(state.agentBuild == "43")
        #expect(state.lastError == "old-helper failure")
    }

    @Test("runtime app errors clear only after a causally current success")
    func runtimeAppErrorCausality() {
        #expect(
            !BackgroundPromptHealth.shouldRecordRuntimeAppError(
                existingSequence: 4,
                candidateSequence: 3
            )
        )
        #expect(
            BackgroundPromptHealth.shouldRecordRuntimeAppError(
                existingSequence: 4,
                candidateSequence: 5
            )
        )
        #expect(
            BackgroundPromptHealth.shouldPreferAgentError(
                appErrorSequence: 4,
                agentErrorSequence: 5
            )
        )
        #expect(
            !BackgroundPromptHealth.shouldPreferAgentError(
                appErrorSequence: 5,
                agentErrorSequence: 4
            )
        )
        #expect(
            !BackgroundPromptHealth.shouldClearRuntimeAppError(
                errorSequence: 3,
                successfulSequence: 2
            )
        )
        #expect(
            BackgroundPromptHealth.shouldClearRuntimeAppError(
                errorSequence: 3,
                successfulSequence: 3
            )
        )
        #expect(
            BackgroundPromptHealth.shouldClearRuntimeAppError(
                errorSequence: 3,
                successfulSequence: 4
            )
        )
        #expect(
            !BackgroundPromptHealth.shouldClearRuntimeAppError(
                errorSequence: nil,
                successfulSequence: 4
            )
        )
    }

    @Test("helper health retries beyond the former timeout and diagnoses nil and stale state")
    func helperHealthRetryWindow() {
        #expect(BackgroundPromptHealth.refreshDelayMilliseconds.reduce(0, +) > 2_500)
        let identity = BackgroundPromptRepairIdentity(
            appBuild: "44",
            applicationPath: "/Applications/SD Import.app",
            agentBundlePath: "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app"
        )
        let staleState = BackgroundPromptAgentState(
            agentBuild: "43",
            agentBundlePath: "/Applications/SD Import.app/Contents/Library/LoginItems/SDImportAgent.app",
            launchedAt: Date()
        )

        #expect(
            BackgroundPromptHealth.ownershipTimeoutError(
                state: nil,
                expectedIdentity: identity
            ) == BackgroundPromptHealth.missingLaunchError
        )
        #expect(
            BackgroundPromptHealth.ownershipTimeoutError(
                state: staleState,
                expectedIdentity: identity
            ).contains("older or different")
        )
    }
}

private actor RepairOperationRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
