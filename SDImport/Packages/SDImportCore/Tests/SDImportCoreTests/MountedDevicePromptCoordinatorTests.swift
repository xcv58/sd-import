import Foundation
import Testing

@testable import SDImportCore

@Suite("Mounted device prompts")
struct MountedDevicePromptCoordinatorTests {
    private let internalStorage = MountedDevicePromptCoordinatorTests.volume("Pocket4", disk: "disk4")
    private let card = MountedDevicePromptCoordinatorTests.volume("Untitled", disk: "disk5")

    @Test("a staggered sibling joins the open prompt with the same presentation identity")
    func staggeredSiblingJoinsOpenPrompt() throws {
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(internalStorage, among: [internalStorage], canPresent: true) == .present)
        let initialPrompt = try #require(coordinator.pendingPrompt)
        #expect(initialPrompt.deviceGroup.volumes == [internalStorage])

        let both = [internalStorage, card]
        coordinator.updateMountedVolumes(both)
        #expect(coordinator.receive(card, among: both, canPresent: false) == .alreadyPresented)
        let updatedPrompt = try #require(coordinator.pendingPrompt)
        #expect(updatedPrompt.id == initialPrompt.id)
        #expect(updatedPrompt.deviceGroup.volumes == both)
        #expect(updatedPrompt.contains(internalStorage))
        #expect(updatedPrompt.contains(card))
    }

    @Test("a sibling arriving after the choice leaves the prompt dismissed", arguments: [false, true])
    func lateSiblingAfterUserChoice(isWorking: Bool) throws {
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(internalStorage, among: [internalStorage], canPresent: true) == .present)
        let prompt = try #require(coordinator.pendingPrompt)
        let didDismiss = coordinator.dismiss(prompt.id)
        #expect(didDismiss)

        let both = [internalStorage, card]
        coordinator.updateMountedVolumes(both)
        #expect(coordinator.receive(card, among: both, canPresent: !isWorking) == .alreadyPresented)
        #expect(coordinator.pendingPrompt == nil)
    }

    @Test("a different USB device keeps its own queued prompt even with the same product name")
    func unrelatedDeviceKeepsOwnPrompt() throws {
        let otherCamera = Self.volume("Pocket4 2", disk: "disk6", device: "other-usb-device")
        var coordinator = MountedDevicePromptCoordinator()
        let both = [internalStorage, otherCamera]
        #expect(coordinator.receive(internalStorage, among: both, canPresent: true) == .present)
        let first = try #require(coordinator.pendingPrompt)
        #expect(coordinator.receive(otherCamera, among: both, canPresent: false) == .deferred)
        #expect(coordinator.pendingPrompt?.deviceGroup.volumes == [internalStorage])

        let didDismiss = coordinator.dismiss(first.id)
        #expect(didDismiss)
        #expect(coordinator.receive(otherCamera, among: both, canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.deviceGroup.volumes == [otherCamera])
        let dismissedReplacement = coordinator.dismiss(first.id)
        #expect(!dismissedReplacement)
    }

    @Test("unmounting one volume keeps its sibling available and disconnecting clears the prompt")
    func unmountAndReconnect() throws {
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(internalStorage, among: [internalStorage, card], canPresent: true) == .present)
        let first = try #require(coordinator.pendingPrompt)

        coordinator.updateMountedVolumes([card])
        let remaining = try #require(coordinator.pendingPrompt)
        #expect(remaining.id == first.id)
        #expect(remaining.deviceGroup.volumes == [card])
        #expect(!remaining.contains(internalStorage))

        coordinator.updateMountedVolumes([])
        #expect(coordinator.pendingPrompt == nil)
        #expect(coordinator.receive(card, among: [card], canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.id != first.id)
    }

    @Test("a different volume at the same path invalidates the earlier selection")
    func replacementInvalidatesSelection() throws {
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(card, among: [internalStorage, card], canPresent: true) == .present)
        let replacement = Self.volume("Untitled", disk: "disk5", uuid: "replacement")
        coordinator.updateMountedVolumes([internalStorage, replacement])
        let updated = try #require(coordinator.pendingPrompt)
        #expect(!updated.contains(card))
        #expect(updated.contains(replacement))
    }

    private static func volume(
        _ name: String,
        disk: String,
        device: String = "camera-usb-device",
        uuid: String? = nil
    ) -> MountedVolume {
        MountedVolume(
            id: uuid ?? name,
            name: name,
            mountURL: URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true),
            volumeUUID: uuid ?? name,
            isRemovable: true,
            wholeDiskIdentifier: disk,
            deviceGroupIdentifier: device,
            deviceVendorName: "DJI",
            deviceProductName: "Osmo Pocket 4"
        )
    }
}
