import Foundation
import Testing

@testable import SDImportCore

@Suite("ImportPlanBuilder")
struct ImportPlanBuilderTests {
    @Test("copied files are not rewritten during replanning")
    func copiedFilesDoNotProducePlanUpdates() {
        let originalDestination = "/Original/Photos/IMG_0001.JPG"
        let file = JobFileRecord(
            id: 42,
            jobID: "job-copied",
            sourcePath: "/Volumes/CARD/DCIM/IMG_0001.JPG",
            relativePath: "DCIM/IMG_0001.JPG",
            filename: "IMG_0001.JPG",
            ext: ".jpg",
            size: 1024,
            modificationDateString: "2024-07-15T10:00:00",
            mediaKind: .photo,
            fingerprint: "v2:fingerprint",
            captureDate: "2024-07-15",
            decision: .new,
            destinationDirectory: "/Original/Photos",
            plannedDestinationPath: originalDestination,
            finalDestinationPath: originalDestination,
            copyStatus: .copied,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let builder = ImportPlanBuilder(
            sessions: [
                ImportPlanSession(
                    date: "2024-07-15",
                    label: "Changed Session",
                    photoCount: 1,
                    videoCount: 0,
                    unsupportedCount: 0,
                    includePhotos: true,
                    includeVideos: false,
                    includeSidecars: false
                )
            ],
            organizationPreset: .shootSessionsByDate,
            roots: DestinationRoots(
                photosURL: URL(fileURLWithPath: "/Changed/Photos", isDirectory: true),
                videosURL: URL(fileURLWithPath: "/Changed/Videos", isDirectory: true)
            ),
            fallbackLocation: "Changed Location",
            volumeName: "CARD"
        )

        let plan = builder.plan(file: file)

        #expect(plan.update == nil)
        #expect(plan.willCopy == false)
        #expect(plan.status == "Copied")
        #expect(plan.destinationPath == originalDestination)
        #expect(builder.updates(files: [file]).isEmpty)
    }

    @Test("one shoot folder uses a date range and flat destinations")
    func oneShootFolderUsesDateRangeAndFlatDestinations() throws {
        let files = [
            jobFile(
                id: 1,
                filename: "IMG_0001.JPG",
                relativePath: "DCIM/100/IMG_0001.JPG",
                mediaKind: .photo,
                captureDate: "2026-05-02"
            ),
            jobFile(
                id: 2,
                filename: "C0001.MP4",
                relativePath: "PRIVATE/M4ROOT/CLIP/C0001.MP4",
                mediaKind: .video,
                captureDate: "2026-05-04"
            )
        ]
        let builder = ImportPlanBuilder(
            sessions: [
                session(date: "2026-05-02", photoCount: 1, videoCount: 0),
                session(date: "2026-05-04", photoCount: 0, videoCount: 1)
            ],
            organizationPreset: .shootSessionsByDate,
            folderGrouping: .oneShootFolder,
            roots: DestinationRoots(
                photosURL: URL(fileURLWithPath: "/Library", isDirectory: true),
                videosURL: URL(fileURLWithPath: "/Footage", isDirectory: true)
            ),
            fallbackLocation: "Launch Weekend",
            volumeName: "CARD"
        )

        let plans = builder.plans(files: files)

        #expect(plans.map(\.destinationPath) == [
            "/Library/2026-05-02 to 2026-05-04 Launch Weekend/IMG_0001.JPG",
            "/Library/2026-05-02 to 2026-05-04 Launch Weekend/C0001.MP4"
        ])
    }

    @Test("one shoot folder renames duplicate filenames within the same import")
    func oneShootFolderRenamesDuplicateFilenamesInBatch() throws {
        let files = [
            jobFile(
                id: 1,
                filename: "C0001.MP4",
                relativePath: "DAY1/C0001.MP4",
                mediaKind: .video,
                captureDate: "2026-05-02"
            ),
            jobFile(
                id: 2,
                filename: "C0001.MP4",
                relativePath: "DAY2/C0001.MP4",
                mediaKind: .video,
                captureDate: "2026-05-03"
            )
        ]
        let builder = ImportPlanBuilder(
            sessions: [
                session(date: "2026-05-02", photoCount: 0, videoCount: 1),
                session(date: "2026-05-03", photoCount: 0, videoCount: 1)
            ],
            organizationPreset: .footageBackup,
            folderGrouping: .oneShootFolder,
            roots: DestinationRoots(
                photosURL: URL(fileURLWithPath: "/Library", isDirectory: true),
                videosURL: URL(fileURLWithPath: "/Footage", isDirectory: true)
            ),
            fallbackLocation: "Race Weekend",
            volumeName: "CARD"
        )

        let plans = builder.plans(files: files)

        #expect(plans.map(\.destinationPath) == [
            "/Footage/2026-05-02 to 2026-05-03 Race Weekend/C0001.MP4",
            "/Footage/2026-05-02 to 2026-05-03 Race Weekend/C0001-copy-1.MP4"
        ])
        #expect(plans[1].status == "Rename")
        #expect(plans[1].update?.error == "destination file name repeats in this import")
    }

    @Test("footage backup renames duplicate filenames in flat day folder")
    func footageBackupRenamesDuplicateFilenamesInFlatDayFolder() throws {
        let files = [
            jobFile(
                id: 1,
                filename: "C0001.MP4",
                relativePath: "PRIVATE/M4ROOT/CLIP/C0001.MP4",
                mediaKind: .video,
                captureDate: "2026-05-06"
            ),
            jobFile(
                id: 2,
                filename: "C0001.MP4",
                relativePath: "PRIVATE/M4ROOT/CLIP2/C0001.MP4",
                mediaKind: .video,
                captureDate: "2026-05-06"
            )
        ]
        let builder = ImportPlanBuilder(
            sessions: [
                session(date: "2026-05-06", label: "XXX", photoCount: 0, videoCount: 2)
            ],
            organizationPreset: .footageBackup,
            roots: DestinationRoots(
                photosURL: URL(fileURLWithPath: "/Library", isDirectory: true),
                videosURL: URL(fileURLWithPath: "/Footage", isDirectory: true)
            ),
            fallbackLocation: "XXX",
            volumeName: "CARD"
        )

        let plans = builder.plans(files: files)

        #expect(plans.map(\.destinationPath) == [
            "/Footage/2026-05-06 XXX/C0001.MP4",
            "/Footage/2026-05-06 XXX/C0001-copy-1.MP4"
        ])
        #expect(plans[1].status == "Rename")
        #expect(plans[1].update?.error == "destination file name repeats in this import")
    }

    private func session(
        date: String,
        label: String = "Ignored Per-Day Label",
        photoCount: Int,
        videoCount: Int
    ) -> ImportPlanSession {
        ImportPlanSession(
            date: date,
            label: label,
            photoCount: photoCount,
            videoCount: videoCount,
            unsupportedCount: 0,
            includePhotos: true,
            includeVideos: true,
            includeSidecars: false
        )
    }

    private func jobFile(
        id: Int64,
        filename: String,
        relativePath: String,
        mediaKind: MediaKind,
        captureDate: String
    ) -> JobFileRecord {
        JobFileRecord(
            id: id,
            jobID: "job-1",
            sourcePath: "/Volumes/CARD/\(relativePath)",
            relativePath: relativePath,
            filename: filename,
            ext: ".\(URL(fileURLWithPath: filename).pathExtension.lowercased())",
            size: 1024,
            modificationDateString: "\(captureDate)T10:00:00",
            mediaKind: mediaKind,
            fingerprint: "v2:\(id)",
            captureDate: captureDate,
            decision: .new,
            destinationDirectory: nil,
            plannedDestinationPath: nil,
            copyStatus: .pending
        )
    }
}
