import Foundation

public struct ImportWorkflowRecommender: Sendable {
    private let dominantThreshold: Double

    public init(dominantThreshold: Double = 0.9) {
        self.dominantThreshold = dominantThreshold
    }

    public func recommend(
        photoCount: Int,
        videoCount: Int,
        sidecarCount: Int,
        unsupportedCount: Int,
        rememberedProfile: ImportWorkflowProfile? = nil,
        fallbackProfile: ImportWorkflowProfile = .mixedShootSession
    ) -> MediaContentProfile {
        let supportedCount = photoCount + videoCount

        guard supportedCount > 0 else {
            return MediaContentProfile(
                photoCount: photoCount,
                videoCount: videoCount,
                sidecarCount: sidecarCount,
                unsupportedCount: unsupportedCount,
                recommendedWorkflow: rememberedProfile ?? fallbackProfile,
                confidence: .empty
            )
        }

        if photoCount > 0, videoCount == 0 {
            return profile(
                .photoImport,
                confidence: .exact,
                photoCount: photoCount,
                videoCount: videoCount,
                sidecarCount: sidecarCount,
                unsupportedCount: unsupportedCount
            )
        }

        if videoCount > 0, photoCount == 0 {
            return profile(
                .footageBackup,
                confidence: .exact,
                photoCount: photoCount,
                videoCount: videoCount,
                sidecarCount: sidecarCount,
                unsupportedCount: unsupportedCount
            )
        }

        let photoShare = Double(photoCount) / Double(supportedCount)
        let videoShare = Double(videoCount) / Double(supportedCount)

        if photoShare >= dominantThreshold {
            return profile(
                .photoImport,
                confidence: .dominant,
                photoCount: photoCount,
                videoCount: videoCount,
                sidecarCount: sidecarCount,
                unsupportedCount: unsupportedCount
            )
        }

        if videoShare >= dominantThreshold {
            return profile(
                .footageBackup,
                confidence: .dominant,
                photoCount: photoCount,
                videoCount: videoCount,
                sidecarCount: sidecarCount,
                unsupportedCount: unsupportedCount
            )
        }

        if let rememberedProfile,
           rememberedProfile.isCompatible(photoCount: photoCount, videoCount: videoCount) {
            return profile(
                rememberedProfile,
                confidence: .remembered,
                photoCount: photoCount,
                videoCount: videoCount,
                sidecarCount: sidecarCount,
                unsupportedCount: unsupportedCount
            )
        }

        return profile(
            .mixedShootSession,
            confidence: .mixed,
            photoCount: photoCount,
            videoCount: videoCount,
            sidecarCount: sidecarCount,
            unsupportedCount: unsupportedCount
        )
    }

    public func recommend(
        files: [JobFileRecord],
        rememberedProfile: ImportWorkflowProfile? = nil,
        fallbackProfile: ImportWorkflowProfile = .mixedShootSession
    ) -> MediaContentProfile {
        let videoCount = files.filter { $0.mediaKind == .video }.count
        let likelyVideoPreviewJPEGCount = videoCount > 0
            ? files.filter(MediaFileHeuristics.isLikelyVideoPreviewJPEG).count
            : 0
        let photoCount = files.filter { $0.mediaKind == .photo }.count - likelyVideoPreviewJPEGCount
        let unsupportedCount = files.filter { $0.mediaKind == .unsupported }.count
        return recommend(
            photoCount: photoCount,
            videoCount: videoCount,
            sidecarCount: unsupportedCount + likelyVideoPreviewJPEGCount,
            unsupportedCount: unsupportedCount + likelyVideoPreviewJPEGCount,
            rememberedProfile: rememberedProfile,
            fallbackProfile: fallbackProfile
        )
    }

    private func profile(
        _ workflow: ImportWorkflowProfile,
        confidence: RecommendationConfidence,
        photoCount: Int,
        videoCount: Int,
        sidecarCount: Int,
        unsupportedCount: Int
    ) -> MediaContentProfile {
        MediaContentProfile(
            photoCount: photoCount,
            videoCount: videoCount,
            sidecarCount: sidecarCount,
            unsupportedCount: unsupportedCount,
            recommendedWorkflow: workflow,
            confidence: confidence
        )
    }
}
