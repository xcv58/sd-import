import Foundation
import Testing

@testable import SDImportCore

@Suite("DestinationPlanner")
struct DestinationPlannerTests {
    @Test("plans photo and video destination directories")
    func plansDestinationDirectories() throws {
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: "/tmp/photos", isDirectory: true),
            videosURL: URL(fileURLWithPath: "/tmp/videos", isDirectory: true)
        )
        let planner = DestinationPlanner()

        let photoURL = planner.destinationURL(
            filename: "IMG_0001.JPG",
            mediaKind: .photo,
            captureDate: "2024-07-15",
            location: "TEST",
            roots: roots
        )
        let videoURL = planner.destinationURL(
            filename: "VID_0001.MP4",
            mediaKind: .video,
            captureDate: "2024-07-15",
            location: "TEST",
            roots: roots
        )

        #expect(photoURL?.path == "/tmp/photos/2024-07-15 TEST/IMG_0001.JPG")
        #expect(videoURL?.path == "/tmp/videos/tmp-2024-07-15-videos/VID_0001.MP4")
    }

    @Test("uses Untitled for blank photo locations")
    func usesUntitledForBlankPhotoLocations() {
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: "/tmp/photos", isDirectory: true),
            videosURL: URL(fileURLWithPath: "/tmp/videos", isDirectory: true)
        )
        let planner = DestinationPlanner()

        let photoURL = planner.destinationURL(
            filename: "IMG_0001.JPG",
            mediaKind: .photo,
            captureDate: "2024-07-15",
            location: " ",
            roots: roots
        )

        #expect(photoURL?.path == "/tmp/photos/2024-07-15 Untitled/IMG_0001.JPG")
    }

    @Test("plans shoot session folders under one library root")
    func plansShootSessionFolders() {
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true),
            videosURL: URL(fileURLWithPath: "/tmp/videos", isDirectory: true)
        )
        let planner = DestinationPlanner()

        let photoURL = planner.destinationURL(
            filename: "IMG_0001.JPG",
            mediaKind: .photo,
            captureDate: "2026-04-29",
            sessionLabel: "Gardens by the Bay",
            roots: roots,
            organizationPreset: .shootSessionsByDate
        )
        let videoURL = planner.destinationURL(
            filename: "C0001.MP4",
            mediaKind: .video,
            captureDate: "2026-04-29",
            sessionLabel: "Gardens by the Bay",
            roots: roots,
            organizationPreset: .shootSessionsByDate
        )

        #expect(photoURL?.path == "/tmp/library/2026-04-29 Gardens by the Bay/Photos/IMG_0001.JPG")
        #expect(videoURL?.path == "/tmp/library/2026-04-29 Gardens by the Bay/Video/C0001.MP4")
    }

    @Test("plans one shoot folders as flat destinations")
    func plansOneShootFolders() {
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true),
            videosURL: URL(fileURLWithPath: "/tmp/footage", isDirectory: true)
        )
        let planner = DestinationPlanner()

        let photoURL = planner.destinationURL(
            filename: "IMG_0001.JPG",
            mediaKind: .photo,
            captureDate: "2026-04-29 to 2026-04-30",
            sessionLabel: "Gardens by the Bay",
            roots: roots,
            organizationPreset: .shootSessionsByDate,
            folderGrouping: .oneShootFolder
        )
        let videoURL = planner.destinationURL(
            filename: "C0001.MP4",
            mediaKind: .video,
            captureDate: "2026-04-29 to 2026-04-30",
            sessionLabel: "Singapore Trip",
            roots: roots,
            organizationPreset: .footageBackup,
            folderGrouping: .oneShootFolder,
            relativePath: "PRIVATE/M4ROOT/CLIP/C0001.MP4",
            volumeName: "Untitled"
        )

        #expect(photoURL?.path == "/tmp/library/2026-04-29 to 2026-04-30 Gardens by the Bay/IMG_0001.JPG")
        #expect(videoURL?.path == "/tmp/footage/2026-04-29 to 2026-04-30 Singapore Trip/C0001.MP4")
    }

    @Test("plans flat footage backup by card")
    func plansFootageBackup() {
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true),
            videosURL: URL(fileURLWithPath: "/tmp/footage", isDirectory: true)
        )
        let planner = DestinationPlanner()

        let videoURL = planner.destinationURL(
            filename: "C0001.MP4",
            mediaKind: .video,
            captureDate: "2026-04-30",
            sessionLabel: "Singapore Trip",
            roots: roots,
            organizationPreset: .footageBackup,
            relativePath: "PRIVATE/M4ROOT/CLIP/C0001.MP4",
            volumeName: "Untitled"
        )

        #expect(videoURL?.path == "/tmp/footage/2026-04-30 Singapore Trip/Card Untitled/C0001.MP4")
    }

    @Test("plans flat footage backup sidecars by card")
    func plansFootageBackupSidecars() {
        let roots = DestinationRoots(
            photosURL: URL(fileURLWithPath: "/tmp/library", isDirectory: true),
            videosURL: URL(fileURLWithPath: "/tmp/footage", isDirectory: true)
        )
        let planner = DestinationPlanner()

        let sidecarURL = planner.destinationURL(
            filename: "C0001.XML",
            mediaKind: .unsupported,
            captureDate: "2026-04-30",
            sessionLabel: "Singapore Trip",
            roots: roots,
            organizationPreset: .footageBackup,
            relativePath: "PRIVATE/M4ROOT/CLIP/C0001.XML",
            volumeName: "Untitled"
        )

        #expect(sidecarURL?.path == "/tmp/footage/2026-04-30 Singapore Trip/Card Untitled/C0001.XML")
    }
}
