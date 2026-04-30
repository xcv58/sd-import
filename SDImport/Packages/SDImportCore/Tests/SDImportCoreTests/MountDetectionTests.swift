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

    @Test("volume detector ignores disk images and backup names")
    func detectorIgnoresDiskImagesAndBackupNames() {
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

        #expect(detector.isLikelyImportVolume(diskImage) == false)
        #expect(detector.isLikelyImportVolume(backup) == false)
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
