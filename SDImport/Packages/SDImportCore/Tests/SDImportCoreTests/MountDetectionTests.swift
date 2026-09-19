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
        let namedDiskImage = MountedVolume(
            id: "named-image",
            name: "Gemini 1.72.2.419",
            mountURL: URL(fileURLWithPath: "/Volumes/Gemini 1.72.2.419", isDirectory: true),
            volumeUUID: nil,
            isRemovable: true,
            isDiskImage: true
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
        #expect(detector.isLikelyImportVolume(namedDiskImage) == false)
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

    @Test("volume detector ignores zero important usage capacity when normal capacity is available")
    func detectorIgnoresZeroImportantUsageCapacity() {
        let available = VolumeDetector.sourceAvailableCapacity(
            available: 128_000_000_000,
            importantUsage: 0
        )

        #expect(available == 128_000_000_000)
    }

    @Test("volume detector falls back to important usage capacity")
    func detectorFallsBackToImportantUsageCapacity() {
        let available = VolumeDetector.sourceAvailableCapacity(
            available: nil,
            importantUsage: 64_000_000_000
        )

        #expect(available == 64_000_000_000)
    }

    @Test("mounted volume decoding treats older payloads as non disk images")
    func mountedVolumeDecodingDefaultsDiskImageFlag() throws {
        let json = """
        {
          "id": "card",
          "name": "CARD",
          "mountURL": "file:///Volumes/CARD/",
          "volumeUUID": null,
          "isRemovable": true,
          "isInternal": false,
          "totalCapacityBytes": null,
          "availableCapacityBytes": null
        }
        """

        let volume = try JSONDecoder().decode(MountedVolume.self, from: Data(json.utf8))

        #expect(volume.isDiskImage == false)
        #expect(volume.wholeDiskIdentifier == nil)
        #expect(volume.deviceGroupIdentifier == nil)
        #expect(volume.deviceVendorName == nil)
        #expect(volume.deviceProductName == nil)
    }

    @Test("volume detector removes serial-like USB product suffixes")
    func detectorSanitizesUSBProductNames() {
        #expect(VolumeDetector.sanitizedDeviceProductName("OsmoPocket4-ANGZP380029ZAV") == "OsmoPocket4")
        #expect(VolumeDetector.sanitizedDeviceProductName("EOS-R5") == "EOS-R5")
        #expect(VolumeDetector.sanitizedDeviceProductName("Samsung-T7Shield") == "Samsung-T7Shield")
        #expect(VolumeDetector.sanitizedDeviceProductName("Extreme-PortableSSD") == "Extreme-PortableSSD")
        #expect(VolumeDetector.sanitizedDeviceProductName("  Camera  ") == "Camera")
    }

    @Test("volume detector accepts only whole-disk BSD identifiers")
    func detectorValidatesWholeDiskIdentifiers() {
        #expect(VolumeDetector.validatedWholeDiskIdentifier("disk4") == "disk4")
        #expect(VolumeDetector.validatedWholeDiskIdentifier("disk42") == "disk42")
        #expect(VolumeDetector.validatedWholeDiskIdentifier("disk5s1") == nil)
        #expect(VolumeDetector.validatedWholeDiskIdentifier("garbage") == nil)
        #expect(VolumeDetector.validatedWholeDiskIdentifier(nil) == nil)
    }

    @Test("volume detector finds importable media before prompting")
    func detectorFindsImportableMedia() throws {
        let directory = try temporaryDirectory()
        let mediaDirectory = directory.appendingPathComponent("DCIM", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: mediaDirectory.appendingPathComponent("IMG_0001.JPG"))

        #expect(VolumeDetector().containsImportableMedia(at: directory))
    }

    @Test("volume detector recognizes an Insta360 master")
    func detectorFindsInsta360Master() throws {
        let directory = try temporaryDirectory()
        try Data([1, 2, 3]).write(
            to: directory.appendingPathComponent("VID_20260919_120000_00_001.insv")
        )

        #expect(MediaClassifier().classify(extension: ".INSV") == .video)
        #expect(MediaClassifier().classify(extension: ".lrv") == .unsupported)
        #expect(VolumeDetector().containsImportableMedia(at: directory))
    }

    @Test("volume detector does not stop at early sidecar files")
    func detectorDoesNotStopAtEarlySidecarFiles() throws {
        let directory = try temporaryDirectory()
        for index in 0..<600 {
            try Data([1]).write(to: directory.appendingPathComponent("SIDE\(index).XML"))
        }
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("C0001.MOV"))

        #expect(VolumeDetector().containsImportableMedia(at: directory))
    }

    @Test("volume detector ignores volumes without importable media")
    func detectorIgnoresVolumesWithoutImportableMedia() throws {
        let directory = try temporaryDirectory()
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("notes.txt"))

        #expect(VolumeDetector().containsImportableMedia(at: directory) == false)
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

    @Test("mount debouncer records only committed prompt deliveries")
    func debouncerRecordsOnlyCommittedDeliveries() {
        var debouncer = MountDebouncer(interval: 10)
        let volume = MountedVolume(
            id: "card",
            name: "CARD",
            mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
            volumeUUID: nil,
            isRemovable: true
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(debouncer.hasRecentlyAccepted(volume, now: start) == false)
        #expect(debouncer.hasRecentlyAccepted(volume, now: start.addingTimeInterval(2)) == false)

        debouncer.recordAccepted(volume, now: start.addingTimeInterval(3))

        #expect(debouncer.hasRecentlyAccepted(volume, now: start.addingTimeInterval(4)))
        #expect(debouncer.hasRecentlyAccepted(volume, now: start.addingTimeInterval(14)) == false)
    }

    @Test("unmount clears legacy acceptance for an immediate remount")
    func debouncerForgetsUnmountedVolume() {
        var debouncer = MountDebouncer(interval: 10)
        let volume = MountedVolume(
            id: "card",
            name: "CARD",
            mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
            volumeUUID: "card",
            isRemovable: true,
            wholeDiskIdentifier: "disk4",
            deviceGroupIdentifier: "camera"
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        debouncer.recordAccepted(volume, now: start)

        debouncer.forget(mountURL: volume.mountURL)

        #expect(debouncer.hasRecentlyAccepted(volume, now: start.addingTimeInterval(1)) == false)
    }

    @Test("mount debouncer coalesces sibling volumes from one device")
    func debouncerCoalescesSiblingVolumes() {
        var debouncer = MountDebouncer(interval: 10)
        let first = MountedVolume(
            id: "card",
            name: "CARD",
            mountURL: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true),
            volumeUUID: "card",
            isRemovable: true,
            wholeDiskIdentifier: "disk4",
            deviceGroupIdentifier: "camera"
        )
        let second = MountedVolume(
            id: "internal",
            name: "INTERNAL",
            mountURL: URL(fileURLWithPath: "/Volumes/INTERNAL", isDirectory: true),
            volumeUUID: "internal",
            isRemovable: true,
            wholeDiskIdentifier: "disk5",
            deviceGroupIdentifier: "camera"
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let firstAccepted = debouncer.shouldAccept(first, now: start)
        let secondAccepted = debouncer.shouldAccept(second, now: start.addingTimeInterval(1))

        #expect(firstAccepted)
        #expect(secondAccepted == false)
    }
}
