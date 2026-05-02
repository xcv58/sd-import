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
}
