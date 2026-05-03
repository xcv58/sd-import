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
        #expect(profile.recommendedWorkflow.includesSidecarsByDefault)
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
}
