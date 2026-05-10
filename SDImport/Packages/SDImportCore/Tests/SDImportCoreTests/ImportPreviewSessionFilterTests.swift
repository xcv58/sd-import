import Foundation
import Testing

@testable import SDImportCore

@Suite("ImportPreviewSessionFilter")
struct ImportPreviewSessionFilterTests {
    @Test("hides dates that only contain known files")
    func hidesKnownOnlyDates() {
        let files = [
            jobFile(id: 1, filename: "IMG_0001.JPG", captureDate: "2026-05-07", decision: .known),
            jobFile(id: 2, filename: "IMG_0002.JPG", captureDate: "2026-05-10", decision: .new)
        ]
        let sessions = [
            session(date: "2026-05-07", photoCount: 1),
            session(date: "2026-05-10", photoCount: 1)
        ]
        let plans = plans(files: files, sessions: sessions)

        let visibleSessions = ImportPreviewSessionFilter().visibleSessions(
            files: files,
            plans: plans,
            sessions: sessions,
            importMediaSelection: .photosOnly,
            organizationPreset: .classicDatedFolders
        )

        #expect(visibleSessions.map(\.date) == ["2026-05-10"])
        #expect(visibleSessions.map(\.photoCount) == [1])
    }

    @Test("counts only import-selectable files on mixed known and new dates")
    func countsOnlyImportSelectableFiles() {
        let files = [
            jobFile(id: 1, filename: "IMG_0001.JPG", captureDate: "2026-05-10", decision: .known),
            jobFile(id: 2, filename: "IMG_0002.JPG", captureDate: "2026-05-10", decision: .new)
        ]
        let sessions = [
            session(date: "2026-05-10", photoCount: 2)
        ]
        let plans = plans(files: files, sessions: sessions)

        let visibleSessions = ImportPreviewSessionFilter().visibleSessions(
            files: files,
            plans: plans,
            sessions: sessions,
            importMediaSelection: .photosOnly,
            organizationPreset: .classicDatedFolders
        )

        #expect(visibleSessions.map(\.date) == ["2026-05-10"])
        #expect(visibleSessions.first?.photoCount == 1)
    }

    @Test("keeps session-excluded files visible so they can be re-enabled")
    func keepsSessionExcludedFilesVisible() {
        let files = [
            jobFile(id: 1, filename: "IMG_0001.JPG", captureDate: "2026-05-10", decision: .new)
        ]
        let sessions = [
            session(date: "2026-05-10", photoCount: 1, includePhotos: false)
        ]
        let plans = plans(files: files, sessions: sessions, organizationPreset: .shootSessionsByDate)

        let visibleSessions = ImportPreviewSessionFilter().visibleSessions(
            files: files,
            plans: plans,
            sessions: sessions,
            importMediaSelection: .photosAndVideos,
            organizationPreset: .shootSessionsByDate
        )

        #expect(plans.first?.status == "Excluded")
        #expect(visibleSessions.map(\.date) == ["2026-05-10"])
        #expect(visibleSessions.first?.photoCount == 1)
    }

    @Test("hides files excluded by global media selection")
    func hidesGloballyExcludedFiles() {
        let files = [
            jobFile(
                id: 1,
                filename: "C0001.MP4",
                mediaKind: .video,
                captureDate: "2026-05-10",
                decision: .new
            )
        ]
        let sessions = [
            session(date: "2026-05-10", videoCount: 1, includeVideos: false)
        ]
        let plans = plans(files: files, sessions: sessions, organizationPreset: .shootSessionsByDate)

        let visibleSessions = ImportPreviewSessionFilter().visibleSessions(
            files: files,
            plans: plans,
            sessions: sessions,
            importMediaSelection: .photosOnly,
            organizationPreset: .shootSessionsByDate
        )

        #expect(plans.first?.status == "Excluded")
        #expect(visibleSessions.isEmpty)
    }

    private func plans(
        files: [JobFileRecord],
        sessions: [ImportPlanSession],
        organizationPreset: ImportOrganizationPreset = .classicDatedFolders
    ) -> [ImportFilePlan] {
        ImportPlanBuilder(
            sessions: sessions,
            organizationPreset: organizationPreset,
            roots: DestinationRoots(
                photosURL: URL(fileURLWithPath: "/Photos", isDirectory: true),
                videosURL: URL(fileURLWithPath: "/Videos", isDirectory: true)
            ),
            fallbackLocation: "Taipei",
            volumeName: "CARD"
        ).plans(files: files)
    }

    private func session(
        date: String,
        photoCount: Int = 0,
        videoCount: Int = 0,
        includePhotos: Bool = true,
        includeVideos: Bool = true
    ) -> ImportPlanSession {
        ImportPlanSession(
            date: date,
            label: "Taipei",
            photoCount: photoCount,
            videoCount: videoCount,
            unsupportedCount: 0,
            includePhotos: includePhotos,
            includeVideos: includeVideos,
            includeSidecars: false
        )
    }

    private func jobFile(
        id: Int64,
        filename: String,
        mediaKind: MediaKind = .photo,
        captureDate: String,
        decision: FileDecision
    ) -> JobFileRecord {
        let ext = ".\(URL(fileURLWithPath: filename).pathExtension.lowercased())"
        return JobFileRecord(
            id: id,
            jobID: "job-1",
            sourcePath: "/Volumes/CARD/\(filename)",
            relativePath: filename,
            filename: filename,
            ext: ext,
            size: 1024,
            modificationDateString: "\(captureDate)T10:00:00",
            mediaKind: mediaKind,
            fingerprint: "v2:\(id)",
            captureDate: captureDate,
            decision: decision,
            destinationDirectory: nil,
            plannedDestinationPath: nil,
            copyStatus: .pending
        )
    }
}
