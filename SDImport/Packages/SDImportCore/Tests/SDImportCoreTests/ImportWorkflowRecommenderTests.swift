import Testing

@testable import SDImportCore

@Suite("Import workflow recommender")
struct ImportWorkflowRecommenderTests {
    @Test("recommends photo import for photo-only cards")
    func recommendsPhotoImportForPhotoOnlyCards() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 42,
            videoCount: 0,
            sidecarCount: 0,
            unsupportedCount: 0
        )

        #expect(profile.recommendedWorkflow == .photoImport)
        #expect(profile.confidence == .exact)
        #expect(profile.supportedCount == 42)
    }

    @Test("recommends footage backup for video-only cards")
    func recommendsFootageBackupForVideoOnlyCards() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 0,
            videoCount: 7,
            sidecarCount: 2,
            unsupportedCount: 2
        )

        #expect(profile.recommendedWorkflow == .footageBackup)
        #expect(profile.confidence == .exact)
        #expect(profile.sidecarCount == 2)
        #expect(!profile.recommendedWorkflow.includesSidecarsByDefault)
    }

    @Test("ignores tiny JPEG previews when recommending video workflows")
    func ignoresTinyJPEGPreviewsWhenRecommendingVideoWorkflows() {
        let profile = ImportWorkflowRecommender().recommend(
            files: [
                file(filename: "C0001.MP4", ext: ".mp4", size: 80_000_000, mediaKind: .video),
                file(filename: "C0001.JPG", ext: ".jpg", size: 240_000, mediaKind: .photo),
                file(filename: "C0002.jpeg", ext: ".jpeg", size: 999_999, mediaKind: .photo)
            ]
        )

        #expect(profile.recommendedWorkflow == .footageBackup)
        #expect(profile.confidence == .exact)
        #expect(profile.photoCount == 0)
        #expect(profile.videoCount == 1)
        #expect(profile.sidecarCount == 2)
    }

    @Test("keeps tiny JPEGs as photos on photo-only cards")
    func keepsTinyJPEGsAsPhotosOnPhotoOnlyCards() {
        let profile = ImportWorkflowRecommender().recommend(
            files: [
                file(filename: "IMG_0001.JPG", ext: ".jpg", size: 240_000, mediaKind: .photo)
            ]
        )

        #expect(profile.recommendedWorkflow == .photoImport)
        #expect(profile.confidence == .exact)
        #expect(profile.photoCount == 1)
        #expect(profile.sidecarCount == 0)
    }

    @Test("counts a current Insta360 master and proxy as one video")
    func countsCurrentInsta360RecordingOnce() {
        let profile = ImportWorkflowRecommender().recommend(
            files: [
                file(filename: "VID_20181001_210458_00_002.insv", ext: ".insv", size: 400_000_000, mediaKind: .video),
                file(filename: "LRV_20181001_210458_01_002.lrv", ext: ".lrv", size: 30_000_000, mediaKind: .unsupported)
            ]
        )

        #expect(profile.videoCount == 1)
        #expect(profile.sidecarCount == 0)
        #expect(profile.unsupportedCount == 0)
        #expect(profile.recommendedWorkflow == .footageBackup)
    }

    @Test("counts an older dual-master Insta360 set as one video")
    func countsDualMasterInsta360RecordingOnce() {
        let profile = ImportWorkflowRecommender().recommend(
            files: [
                file(filename: "VID_20181001_210458_00_007.insv", ext: ".insv", size: 400_000_000, mediaKind: .video),
                file(filename: "VID_20181001_210458_10_007.insv", ext: ".insv", size: 400_000_000, mediaKind: .video),
                file(filename: "LRV_20181001_210458_01_007.lrv", ext: ".lrv", size: 30_000_000, mediaKind: .unsupported),
                file(filename: "LRV_20181001_210458_11_007.lrv", ext: ".lrv", size: 30_000_000, mediaKind: .unsupported)
            ]
        )

        #expect(profile.videoCount == 1)
        #expect(profile.sidecarCount == 0)
        #expect(profile.unsupportedCount == 0)
    }

    @Test("a pending Insta360 proxy retains the known recording count")
    func countsPendingProxyWithKnownMaster() {
        let profile = ImportWorkflowRecommender().recommend(
            files: [
                file(filename: "VID_20181001_210458_00_002.insv", ext: ".insv", size: 400_000_000, mediaKind: .video, decision: .known),
                file(filename: "LRV_20181001_210458_01_002.lrv", ext: ".lrv", size: 30_000_000, mediaKind: .unsupported, decision: .unsupported)
            ]
        )

        #expect(profile.videoCount == 1)
        #expect(profile.sidecarCount == 0)
    }

    @Test("leaves an orphan Insta360 proxy unsupported")
    func orphanInsta360ProxyRemainsUnsupported() {
        let profile = ImportWorkflowRecommender().recommend(
            files: [
                file(filename: "LRV_20181001_210458_01_002.lrv", ext: ".lrv", size: 30_000_000, mediaKind: .unsupported)
            ]
        )

        #expect(profile.videoCount == 0)
        #expect(profile.sidecarCount == 1)
        #expect(profile.unsupportedCount == 1)
    }

    @Test("keeps mixed cards on mixed workflow even when one media type dominates")
    func keepsMixedCardsOnMixedWorkflowEvenWhenOneMediaTypeDominates() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 5,
            videoCount: 95,
            sidecarCount: 0,
            unsupportedCount: 0
        )

        #expect(profile.recommendedWorkflow == .mixedShootSession)
        #expect(profile.confidence == .mixed)
    }

    @Test("ignores remembered partial workflow for mixed cards")
    func ignoresRememberedPartialWorkflowForMixedCards() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 50,
            videoCount: 50,
            sidecarCount: 0,
            unsupportedCount: 0,
            rememberedProfile: .photoImport
        )

        #expect(profile.recommendedWorkflow == .mixedShootSession)
        #expect(profile.confidence == .mixed)
    }

    @Test("uses remembered mixed workflow for mixed cards")
    func usesRememberedMixedWorkflowForMixedCards() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 50,
            videoCount: 50,
            sidecarCount: 0,
            unsupportedCount: 0,
            rememberedProfile: .mixedShootSession
        )

        #expect(profile.recommendedWorkflow == .mixedShootSession)
        #expect(profile.confidence == .remembered)
    }

    @Test("falls back to mixed sessions for balanced cards without a memory")
    func fallsBackToMixedSessionsForBalancedCardsWithoutMemory() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 12,
            videoCount: 9,
            sidecarCount: 1,
            unsupportedCount: 1
        )

        #expect(profile.recommendedWorkflow == .mixedShootSession)
        #expect(profile.confidence == .mixed)
    }

    @Test("uses fallback profile for empty scans")
    func usesFallbackProfileForEmptyScans() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 0,
            videoCount: 0,
            sidecarCount: 3,
            unsupportedCount: 3,
            fallbackProfile: .footageBackup
        )

        #expect(profile.recommendedWorkflow == .footageBackup)
        #expect(profile.confidence == .empty)
    }

    private func file(
        filename: String,
        ext: String,
        size: Int64,
        mediaKind: MediaKind,
        decision: FileDecision = .new
    ) -> JobFileRecord {
        JobFileRecord(
            jobID: "job-1",
            sourcePath: "/Volumes/CARD/\(filename)",
            relativePath: filename,
            filename: filename,
            ext: ext,
            size: size,
            modificationDateString: "2026-05-09T10:00:00",
            mediaKind: mediaKind,
            fingerprint: "v2:\(filename)",
            captureDate: "2026-05-09",
            decision: decision,
            destinationDirectory: nil,
            plannedDestinationPath: nil,
            copyStatus: .pending
        )
    }
}
