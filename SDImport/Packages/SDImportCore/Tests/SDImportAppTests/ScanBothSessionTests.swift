import Foundation
import SDImportCore
import Testing

@testable import SDImportApp

@Suite("Scan both camera volumes")
@MainActor
struct ScanBothSessionTests {
    private let internalStorage = Self.volume("Z Internal", disk: "disk4")
    private let card = Self.volume("SD Card", disk: "disk5")

    @Test("a verified sibling arriving later enables Scan Both and internal storage goes first")
    func waitsForVerifiedSibling() throws {
        let otherCard = Self.volume("Other Card", disk: "disk6", device: "other-device")
        var coordinator = MountedDevicePromptCoordinator()
        _ = coordinator.receive(internalStorage, among: [internalStorage, otherCard], canPresent: true)
        let single = try #require(coordinator.pendingPrompt)
        #expect(ScanBothSession(prompt: single) == nil)

        let mounted = [internalStorage, card, otherCard]
        coordinator.updateMountedVolumes(mounted)
        _ = coordinator.receive(card, among: mounted, canPresent: false)
        let prompt = try #require(coordinator.pendingPrompt)
        let session = try #require(ScanBothSession(prompt: prompt))
        #expect(prompt.id == single.id)
        #expect(session.entries.map(\.volume) == [internalStorage, card])
    }

    @Test("a skipped source preserves the sibling's completed result", arguments: [true, false])
    func preservesSiblingResult(declineFirst: Bool) async throws {
        var coordinator = MountedDevicePromptCoordinator()
        _ = coordinator.receive(card, among: [card, internalStorage], canPresent: true)
        let prompt = try #require(coordinator.pendingPrompt)
        let session = try #require(ScanBothSession(prompt: prompt))
        let skippedVolume = declineFirst ? internalStorage : card
        let completedVolume = declineFirst ? card : internalStorage
        var states: [ScanBothSession.Entry.State] = [.waiting, .waiting]
        var order: [String] = []

        await session.scan { index, state in
            states[index] = state
        } volume: { volume in
            order.append(volume.name)
            if volume == card {
                if declineFirst {
                    guard case .skipped(.accessDeclined) = states[0] else {
                        Issue.record("The first source's decline must be recorded before the second starts")
                        throw ScanBothIssue.cancelled
                    }
                } else {
                    guard case .complete = states[0] else {
                        Issue.record("The first source must finish before the second starts")
                        throw ScanBothIssue.cancelled
                    }
                }
            }
            if volume == skippedVolume {
                throw declineFirst ? ScanBothIssue.accessDeclined : .removed
            }
            await Task.yield()
            return .complete(
                ScanSummary(
                    jobID: volume.name, mountPath: volume.mountPath, volumeName: volume.name,
                    volumeUUID: volume.volumeUUID, location: "Camera", scannedFiles: 1, newFiles: 1,
                    knownFiles: 0, unsupportedFiles: 0, conflictFiles: 0
                ),
                ["clip.mp4"],
                nil
            )
        }

        #expect(order == [internalStorage.name, card.name])
        let completed = states[declineFirst ? 1 : 0]
        let skipped = states[declineFirst ? 0 : 1]
        if case .complete(let summary, let filenames, _) = completed {
            #expect(summary.volumeName == completedVolume.name)
            #expect(filenames == ["clip.mp4"])
        } else {
            Issue.record("Expected the sibling's scan result")
        }
        switch skipped {
        case .skipped(.accessDeclined): #expect(declineFirst)
        case .skipped(.removed): #expect(!declineFirst)
        default: Issue.record("Expected the source's skip reason")
        }
    }

    private static func volume(_ name: String, disk: String, device: String = "camera") -> MountedVolume {
        MountedVolume(
            id: name, name: name, mountURL: URL(fileURLWithPath: "/Volumes/\(name)"),
            volumeUUID: name, isRemovable: true, wholeDiskIdentifier: disk, deviceGroupIdentifier: device
        )
    }
}
