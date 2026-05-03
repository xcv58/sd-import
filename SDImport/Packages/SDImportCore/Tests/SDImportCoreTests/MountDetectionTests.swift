import Foundation
import Testing

@testable import SDImportCore

@Suite("Mount detection")
struct MountDetectionTests {
    @Test("volume detector accepts likely removable volumes")
    func detectorAcceptsLikelyRemovableVolumes() {
        let detector = VolumeDetector()
        let volume = MountedVolume(
            id: "card",
            name: "CARD",
            mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
            volumeUUID: nil,
            isRemovable: true
        )

        #expect(detector.isLikelyImportVolume(volume))
    }

    @Test("volume detector accepts cards from internal readers")
    func detectorAcceptsCardsFromInternalReaders() {
        let detector = VolumeDetector()
        let volume = MountedVolume(
            id: "card",
            name: "Untitled",
            mountURL: URL(fileURLWithPath: "/Volumes/Untitled", isDirectory: true),
            volumeUUID: nil,
            isRemovable: true,
            isInternal: true
        )

        #expect(detector.isLikelyImportVolume(volume))
    }

    @Test("volume detector ignores disk images backup names and system volumes")
    func detectorIgnoresDiskImagesBackupNamesAndSystemVolumes() {
        let detector = VolumeDetector()
        let diskImage = MountedVolume(
            id: "image",
            name: "Installer.dmg",
            mountURL: URL(fileURLWithPath: "/Volumes/Installer.dmg", isDirectory: true),
            volumeUUID: nil,
            isRemovable: true
        )
        let backup = MountedVolume(
            id: "backup",
            name: "Time Machine Backups",
            mountURL: URL(fileURLWithPath: "/Volumes/Time Machine Backups", isDirectory: true),
            volumeUUID: nil,
            isRemovable: true
        )
        let recovery = MountedVolume(
            id: "recovery",
            name: "Recovery",
            mountURL: URL(fileURLWithPath: "/Volumes/Recovery", isDirectory: true),
            volumeUUID: nil,
            isRemovable: true
        )
        let nonRemovableVolumePath = MountedVolume(
            id: "non-removable",
            name: "Mounted System Volume",
            mountURL: URL(fileURLWithPath: "/Volumes/Mounted System Volume", isDirectory: true),
            volumeUUID: nil,
            isRemovable: false
        )

        #expect(detector.isLikelyImportVolume(diskImage) == false)
        #expect(detector.isLikelyImportVolume(backup) == false)
        #expect(detector.isLikelyImportVolume(recovery) == false)
        #expect(detector.isLikelyImportVolume(nonRemovableVolumePath) == false)
    }

    @Test("volume detector sorts likely import volumes and removes ignored volumes")
    func detectorSortsLikelyImportVolumesAndRemovesIgnoredVolumes() {
        let detector = VolumeDetector()
        let volumes = [
            MountedVolume(
                id: "backup",
                name: "Time Machine Backups",
                mountURL: URL(fileURLWithPath: "/Volumes/Time Machine Backups", isDirectory: true),
                volumeUUID: nil,
                isRemovable: true
            ),
            MountedVolume(
                id: "b",
                name: "B CARD",
                mountURL: URL(fileURLWithPath: "/Volumes/B CARD", isDirectory: true),
                volumeUUID: nil,
                isRemovable: true
            ),
            MountedVolume(
                id: "a",
                name: "A CARD",
                mountURL: URL(fileURLWithPath: "/Volumes/A CARD", isDirectory: true),
                volumeUUID: nil,
                isRemovable: true
            ),
            MountedVolume(
                id: "disk-image",
                name: "Installer.dmg",
                mountURL: URL(fileURLWithPath: "/Volumes/Installer.dmg", isDirectory: true),
                volumeUUID: nil,
                isRemovable: true
            )
        ]

        let likelyVolumes = detector.likelyImportVolumes(from: volumes)

        #expect(likelyVolumes.map(\.name) == ["A CARD", "B CARD"])
    }

    @Test("mount debouncer suppresses repeated paths inside interval")
    func debouncerSuppressesRepeatedPaths() {
        var debouncer = MountDebouncer(interval: 10)
        let volume = MountedVolume(
            id: "card",
            name: "CARD",
            mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
            volumeUUID: nil,
            isRemovable: true
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = debouncer.shouldAccept(volume, now: start)
        let second = debouncer.shouldAccept(volume, now: start.addingTimeInterval(2))
        let third = debouncer.shouldAccept(volume, now: start.addingTimeInterval(11))

        #expect(first)
        #expect(second == false)
        #expect(third)
    }
}
