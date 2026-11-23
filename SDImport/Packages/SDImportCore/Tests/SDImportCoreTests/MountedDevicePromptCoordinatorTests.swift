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

    @Test("unmounting one volume keeps its sibling and reconnecting with a new USB ID prompts again")
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
        let reconnectedCard = Self.volume("Untitled", disk: "disk5", device: "reconnected-camera")
        #expect(coordinator.receive(reconnectedCard, among: [reconnectedCard], canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.id != first.id)
    }

    @Test("a mount after all volumes disappear can prompt again on the same USB device")
    func gapBetweenMountedVolumes() throws {
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(internalStorage, among: [internalStorage], canPresent: true) == .present)
        let prompt = try #require(coordinator.pendingPrompt)
        let didDismiss = coordinator.dismiss(prompt.id)
        #expect(didDismiss)

        coordinator.updateMountedVolumes([])
        coordinator.updateMountedVolumes([card])
        #expect(coordinator.receive(card, among: [card], canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.id != prompt.id)
    }

    @Test("an attached reader prompts for its replacement card after all prior volumes unmount", arguments: ["disk4", "disk6"])
    func cardSwapInConnectedReader(replacementDisk: String) throws {
        let original = Self.volume("First", disk: "disk4", device: "reader")
        let replacement = Self.volume("Second", disk: replacementDisk, device: "reader")
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(original, among: [original], canPresent: true) == .present)
        let prompt = try #require(coordinator.pendingPrompt)

        coordinator.updateMountedVolumes([])
        coordinator.updateMountedVolumes([replacement])
        #expect(coordinator.receive(replacement, among: [replacement], canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.id != prompt.id)
    }

    @Test("the next snapshot can show a different card at the same path without an empty snapshot")
    func samePathCardSwapWithoutGap() throws {
        let original = Self.volume("CARD", disk: "disk4", device: "reader", uuid: "first")
        let replacement = Self.volume("CARD", disk: "disk4", device: "reader", uuid: "second")
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(original, among: [original], canPresent: true) == .present)
        let previous = try #require(coordinator.pendingPrompt)

        coordinator.updateMountedVolumes([replacement])
        #expect(coordinator.pendingPrompt == nil)
        #expect(coordinator.receive(original, among: [replacement], canPresent: true) == .stale)
        #expect(coordinator.receive(replacement, among: [replacement], canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.id != previous.id)
    }

    @Test("a reader prompts again after a card with multiple partitions is replaced")
    func replacesPartitionedCard() throws {
        let firstPartition = Self.volume("First", disk: "disk4", device: "reader")
        let secondPartition = Self.volume("Other", disk: "disk4", device: "reader")
        let replacement = Self.volume("Second", disk: "disk4", device: "reader")
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(firstPartition, among: [firstPartition, secondPartition], canPresent: true) == .present)
        let previous = try #require(coordinator.pendingPrompt)
        let didDismiss = coordinator.dismiss(previous.id)
        #expect(didDismiss)

        coordinator.updateMountedVolumes([])
        #expect(coordinator.receive(replacement, among: [replacement], canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.deviceGroup.volumes == [replacement])
    }

    @Test("replacing a card after dismissal prompts even while a previously offered sibling remains", arguments: [false, true])
    func replacementWithSurvivingSibling(sawUnmountSeparately: Bool) throws {
        let replacement = Self.volume("NewCard", disk: "disk6")
        let afterSwap = [internalStorage, replacement]
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(card, among: [internalStorage, card], canPresent: true) == .present)
        let previous = try #require(coordinator.pendingPrompt)
        let didDismiss = coordinator.dismiss(previous.id)
        #expect(didDismiss)

        if sawUnmountSeparately { coordinator.updateMountedVolumes([internalStorage]) }
        coordinator.updateMountedVolumes(afterSwap)
        #expect(coordinator.receive(internalStorage, among: afterSwap, canPresent: true) == .alreadyPresented)
        #expect(coordinator.receive(replacement, among: afterSwap, canPresent: false) == .deferred)
        #expect(coordinator.receive(replacement, among: afterSwap, canPresent: true) == .present)
        let updated = try #require(coordinator.pendingPrompt)
        #expect(updated.id != previous.id)
        #expect(updated.contains(replacement))
    }

    @Test("a partition of an offered replacement disk stays in Source after dismissal")
    func latePartitionOfOfferedReplacement() throws {
        let replacement = Self.volume("NewCard", disk: "disk6")
        let latePartition = Self.volume("SecondPartition", disk: "disk6")
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(card, among: [internalStorage, card], canPresent: true) == .present)
        let initial = try #require(coordinator.pendingPrompt)

        coordinator.updateMountedVolumes([internalStorage])
        coordinator.updateMountedVolumes([internalStorage, replacement])
        #expect(coordinator.pendingPrompt?.contains(replacement) == true)
        let dismissed = coordinator.dismiss(initial.id)
        #expect(dismissed)

        let allVolumes = [internalStorage, replacement, latePartition]
        #expect(coordinator.receive(latePartition, among: allVolumes, canPresent: true) == .alreadyPresented)
        #expect(coordinator.pendingPrompt == nil)
    }

    @Test("an unmount invalidates a UUID-less selection even if its path and disk number are reused", arguments: ["disk5", "disk6"])
    func replacementWithoutUUIDHasNewMountID(replacementDisk: String) throws {
        func card(on disk: String) -> MountedVolume {
            MountedVolume(
                id: "/Volumes/CARD",
                name: "CARD",
                mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
                volumeUUID: nil,
                isRemovable: true,
                wholeDiskIdentifier: disk,
                deviceGroupIdentifier: internalStorage.deviceGroupIdentifier
            )
        }

        let original = card(on: "disk5")
        let replacement = card(on: replacementDisk)
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(original, among: [internalStorage, original], canPresent: true) == .present)
        let initial = try #require(coordinator.pendingPrompt)
        let originalMountID = try #require(initial.mountID(for: original))
        let internalMountID = try #require(initial.mountID(for: internalStorage))

        coordinator.updateMountedVolumes([internalStorage])
        #expect(coordinator.pendingPrompt?.mountID(for: original) == nil)
        coordinator.updateMountedVolumes([internalStorage, replacement])
        let updated = try #require(coordinator.pendingPrompt)
        let replacementMountID = try #require(updated.mountID(for: replacement))
        #expect(updated.id == initial.id)
        #expect(updated.mountID(for: internalStorage) == internalMountID)
        #expect(replacementMountID != originalMountID)
    }

    @Test("a different live media ID expires a UUID-less choice without an unmount snapshot")
    func mediaChangeExpiresChoiceBeforeUnmountDelivery() throws {
        func card(media: UInt64?) -> MountedVolume {
            MountedVolume(
                id: "/Volumes/CARD",
                name: "CARD",
                mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
                volumeUUID: nil,
                isRemovable: true,
                wholeDiskIdentifier: "disk5",
                deviceGroupIdentifier: internalStorage.deviceGroupIdentifier,
                mediaRegistryID: media
            )
        }
        let original = card(media: 1)
        let replacement = card(media: 2)
        let unverified = card(media: nil)
        #expect(original.hasVerifiedMediaContinuity(with: original))
        #expect(!replacement.hasVerifiedMediaContinuity(with: original))
        #expect(!unverified.hasVerifiedMediaContinuity(with: original))
        #expect(!unverified.hasVerifiedMediaContinuity(with: unverified))

        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(original, among: [internalStorage, original], canPresent: true) == .present)
        let initial = try #require(coordinator.pendingPrompt)
        let originalMountID = try #require(initial.mountID(for: original))

        coordinator.updateMountedVolumes([internalStorage, replacement])
        let updated = try #require(coordinator.pendingPrompt)
        #expect(updated.id == initial.id)
        #expect(updated.mountID(for: original) == nil)
        #expect(updated.mountID(for: replacement) != originalMountID)
    }

    @Test("cloned UUIDs without a shared hardware identity get separate prompts")
    func clonedVolumesStaySeparate() throws {
        let first = Self.volume("CloneOne", disk: nil, device: nil, uuid: "cloned")
        let second = Self.volume("CloneTwo", disk: nil, device: nil, uuid: "cloned")
        let volumes = [first, second]
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(first, among: volumes, canPresent: true) == .present)
        let initial = try #require(coordinator.pendingPrompt)
        #expect(initial.deviceGroup.volumes == [first])
        let dismissed = coordinator.dismiss(initial.id)
        #expect(dismissed)
        #expect(coordinator.receive(second, among: volumes, canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.deviceGroup.volumes == [second])
    }

    @Test("learning the USB ID preserves an open or dismissed prompt", arguments: [false, true])
    func resolvesUSBIdentity(dismissed: Bool) throws {
        let provisional = Self.volume("Pocket4", disk: "disk4", device: nil)
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(provisional, among: [provisional], canPresent: true) == .present)
        let prompt = try #require(coordinator.pendingPrompt)
        if dismissed { _ = coordinator.dismiss(prompt.id) }

        let both = [internalStorage, card]
        coordinator.updateMountedVolumes(both)
        #expect(coordinator.receive(card, among: both, canPresent: true) == .alreadyPresented)
        if dismissed {
            #expect(coordinator.pendingPrompt == nil)
        } else {
            #expect(coordinator.pendingPrompt?.id == prompt.id)
            #expect(coordinator.pendingPrompt?.deviceGroup.volumes == both)
        }
    }

    @Test("a reused disk number and mount path with a different UUID starts a fresh prompt")
    func reusedFallbackIsDistinct() throws {
        let previous = Self.volume("Untitled", disk: "disk5", device: nil, uuid: "old")
        let replacement = Self.volume("Untitled", disk: "disk5", device: nil, uuid: "new")
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(previous, among: [previous], canPresent: true) == .present)
        let prompt = try #require(coordinator.pendingPrompt)

        coordinator.updateMountedVolumes([replacement])
        #expect(coordinator.pendingPrompt == nil)
        #expect(coordinator.receive(previous, among: [replacement], canPresent: true) == .stale)
        #expect(coordinator.receive(replacement, among: [replacement], canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.id != prompt.id)
    }

    @Test("a handoff without a UUID uses the current volume once")
    func missingHandoffUUIDDoesNotDuplicateSource() {
        let unverified = MountedVolume(
            id: internalStorage.mountPath,
            name: internalStorage.name,
            mountURL: internalStorage.mountURL,
            volumeUUID: nil,
            isRemovable: true,
            wholeDiskIdentifier: internalStorage.wholeDiskIdentifier,
            deviceGroupIdentifier: internalStorage.deviceGroupIdentifier
        )
        var coordinator = MountedDevicePromptCoordinator()
        #expect(coordinator.receive(unverified, among: [internalStorage], canPresent: true) == .present)
        #expect(coordinator.pendingPrompt?.deviceGroup.volumes == [internalStorage])
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
        disk: String?,
        device: String? = "camera-usb-device",
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
