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

    @Test("uses dominant content when one media type clearly wins")
    func usesDominantContentWhenOneMediaTypeClearlyWins() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 5,
            videoCount: 95,
            sidecarCount: 0,
            unsupportedCount: 0
        )

        #expect(profile.recommendedWorkflow == .footageBackup)
        #expect(profile.confidence == .dominant)
    }

    @Test("uses remembered workflow for compatible mixed cards")
    func usesRememberedWorkflowForCompatibleMixedCards() {
        let profile = ImportWorkflowRecommender().recommend(
            photoCount: 50,
            videoCount: 50,
            sidecarCount: 0,
            unsupportedCount: 0,
            rememberedProfile: .photoImport
        )

        #expect(profile.recommendedWorkflow == .photoImport)
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
        mediaKind: MediaKind
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
            decision: .new,
            destinationDirectory: nil,
            plannedDestinationPath: nil,
            copyStatus: .pending
        )
    }
}
