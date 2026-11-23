import Foundation
import Testing

@testable import SDImportCore

#if DEBUG
@Suite("Background prompt runtime QA boundary")
struct BackgroundPromptRuntimeQATests {
    @Test("parses only explicit debug QA arguments")
    func parsesExplicitArguments() {
        #expect(
            BackgroundPromptRuntimeQA.preparesApplication(
                arguments: ["agent", BackgroundPromptRuntimeQA.prepareApplicationArgument],
                distribution: .macAppStore
            )
        )
        #expect(
            BackgroundPromptRuntimeQA.unregistersHelper(
                arguments: ["agent", BackgroundPromptRuntimeQA.unregisterHelperArgument],
                distribution: .macAppStore
            )
        )
        #expect(
            BackgroundPromptRuntimeQA.consumesInjectedHandoff(
                arguments: ["app", BackgroundPromptRuntimeQA.consumeHandoffArgument],
                distribution: .macAppStore
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.permitsRegistrationReconciliation(
                arguments: ["app", BackgroundPromptRuntimeQA.consumeHandoffArgument],
                distribution: .macAppStore
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.permitsRegistrationReconciliation(
                arguments: ["app", BackgroundPromptRuntimeQA.prepareApplicationArgument],
                distribution: .macAppStore
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.permitsRegistrationReconciliation(
                arguments: ["app", BackgroundPromptRuntimeQA.unregisterHelperArgument],
                distribution: .macAppStore
            )
        )
        #expect(
            BackgroundPromptRuntimeQA.permitsRegistrationReconciliation(
                arguments: ["app"],
                distribution: .macAppStore
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.permitsRegistrationReconciliation(
                arguments: ["app"],
                distribution: .macAppStore,
                helperLifecycleIsActive: true
            )
        )
        #expect(
            BackgroundPromptRuntimeQA.permitsRegistrationReconciliation(
                arguments: ["app", BackgroundPromptRuntimeQA.consumeHandoffArgument],
                distribution: .direct,
                helperLifecycleIsActive: true
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.preparesApplication(
                arguments: ["agent"],
                distribution: .macAppStore
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.consumesInjectedHandoff(
                arguments: ["app", BackgroundPromptRuntimeQA.consumeHandoffArgument],
                distribution: .direct
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.unregistersHelper(
                arguments: ["agent"],
                distribution: .macAppStore
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.preparesApplication(
                arguments: ["agent", BackgroundPromptRuntimeQA.prepareApplicationArgument],
                distribution: .direct
            )
        )
    }

    @Test("preparation enables and persists the physical-card prompt prerequisites")
    func preparesPersistentApplicationConfiguration() throws {
        let pool = try migratedPool()
        let repository = SettingsRepository(pool: pool)
        let configuration = AppConfiguration.defaultConfiguration(
            homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        let prepared = try #require(
            BackgroundPromptRuntimeQA.preparedApplicationConfiguration(
                configuration,
                arguments: ["app", BackgroundPromptRuntimeQA.prepareApplicationArgument],
                distribution: .macAppStore
            )
        )
        #expect(prepared.autoPromptEnabled)
        #expect(prepared.hasCompletedOnboarding)

        try repository.saveConfiguration(prepared)
        let persisted = try #require(try repository.fetchConfiguration())
        #expect(persisted.autoPromptEnabled)
        #expect(persisted.hasCompletedOnboarding)

        #expect(
            BackgroundPromptRuntimeQA.preparedApplicationConfiguration(
                configuration,
                arguments: ["app", BackgroundPromptRuntimeQA.prepareApplicationArgument],
                distribution: .direct
            ) == nil
        )
        #expect(
            BackgroundPromptRuntimeQA.preparedApplicationConfiguration(
                configuration,
                arguments: ["app", BackgroundPromptRuntimeQA.consumeHandoffArgument],
                distribution: .macAppStore
            ) == nil
        )
    }

    @Test("shares an exact, short-lived helper lifecycle marker")
    func sharesHelperLifecycleMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markerURL = root.appendingPathComponent("runtime-qa-active.json")
        let appURL = URL(fileURLWithPath: "/Applications/SD Import for Mac Helper QA.app")
        let otherAppURL = URL(fileURLWithPath: "/Applications/Another Copy.app")
        let markedAt = Date(timeIntervalSince1970: 1_800_000_000)

        try BackgroundPromptRuntimeQA.markHelperLifecycleActive(
            targetApplicationURL: appURL,
            markerURL: markerURL,
            now: markedAt
        )

        #expect(
            BackgroundPromptRuntimeQA.helperLifecycleIsActive(
                targetApplicationURL: appURL,
                markerURL: markerURL,
                now: markedAt.addingTimeInterval(60)
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.helperLifecycleIsActive(
                targetApplicationURL: otherAppURL,
                markerURL: markerURL,
                now: markedAt.addingTimeInterval(60)
            )
        )
        #expect(
            !BackgroundPromptRuntimeQA.helperLifecycleIsActive(
                targetApplicationURL: appURL,
                markerURL: markerURL,
                now: markedAt.addingTimeInterval(
                    BackgroundPromptRuntimeQA.lifecycleMarkerMaximumAge + 1
                )
            )
        )

        try BackgroundPromptRuntimeQA.clearHelperLifecycleMarker(markerURL: markerURL)
        #expect(
            !BackgroundPromptRuntimeQA.helperLifecycleIsActive(
                targetApplicationURL: appURL,
                markerURL: markerURL,
                now: markedAt.addingTimeInterval(60)
            )
        )
    }

    @Test("accepts only mounted-volume paths for injected post-detection events")
    func parsesMountedVolumePath() {
        let mountURL = BackgroundPromptRuntimeQA.injectedMountURL(
            arguments: [
                "agent",
                BackgroundPromptRuntimeQA.injectedMountArgument,
                "/Volumes/SDIMPORT_QA_CARD",
            ],
            distribution: .macAppStore
        )
        #expect(mountURL?.path == "/Volumes/SDIMPORT_QA_CARD")
        #expect(
            BackgroundPromptRuntimeQA.injectedMountURL(
                arguments: [
                    "agent",
                    BackgroundPromptRuntimeQA.injectedMountArgument,
                    "/private/tmp/not-a-volume",
                ],
                distribution: .macAppStore
            ) == nil
        )
        #expect(
            BackgroundPromptRuntimeQA.injectedMountURL(
                arguments: ["agent", BackgroundPromptRuntimeQA.injectedMountArgument],
                distribution: .macAppStore
            ) == nil
        )
        #expect(
            BackgroundPromptRuntimeQA.injectedMountURL(
                arguments: [
                    "agent",
                    BackgroundPromptRuntimeQA.injectedMountArgument,
                    "/Volumes/SDIMPORT_QA_CARD",
                ],
                distribution: .direct
            ) == nil
        )
    }

    @Test("injected event starts after detection without capacity or media data")
    func createsPostDetectionEvent() throws {
        let mountURL = try #require(
            BackgroundPromptRuntimeQA.injectedMountURL(
                arguments: [
                    "agent",
                    BackgroundPromptRuntimeQA.injectedMountArgument,
                    "/Volumes/SDIMPORT_QA_CARD",
                ],
                distribution: .macAppStore
            )
        )
        let volume = BackgroundPromptRuntimeQA.injectedPostDetectionVolume(at: mountURL)

        #expect(volume.mountURL == mountURL)
        #expect(volume.name == "SDIMPORT_QA_CARD")
        #expect(volume.isRemovable)
        #expect(!volume.isDiskImage)
        #expect(volume.totalCapacityBytes == nil)
        #expect(volume.availableCapacityBytes == nil)
    }

    @Test("the admitted debug fixture survives a Source refresh while its mount is current")
    func replenishesLiveFixtureInPromptSnapshot() throws {
        let fixture = BackgroundPromptRuntimeQA.injectedPostDetectionVolume(
            at: URL(fileURLWithPath: "/Volumes/SDIMPORT_QA_CARD", isDirectory: true)
        )
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(fixture, among: [], canPresent: true) == .present)
        let promptID = try #require(coordinator.pendingPrompt?.id)

        let whileMounted = BackgroundPromptRuntimeQA.retainingLivePromptVolume(fixture, in: []) { $0 == fixture }
        coordinator.updateMountedVolumes(whileMounted)
        #expect(coordinator.pendingPrompt?.id == promptID)
        #expect(coordinator.pendingPrompt?.contains(fixture) == true)
        #expect(BackgroundPromptRuntimeQA.retainingLivePromptVolume(fixture, in: [fixture]) { _ in true } == [fixture])

        let afterUnmount = BackgroundPromptRuntimeQA.retainingLivePromptVolume(fixture, in: []) { _ in false }
        coordinator.updateMountedVolumes(afterUnmount)
        #expect(coordinator.pendingPrompt == nil)
    }
}
#endif
