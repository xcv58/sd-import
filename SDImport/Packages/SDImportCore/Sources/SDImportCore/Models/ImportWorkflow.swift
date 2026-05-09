import Foundation

public enum ImportMediaSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case photosAndVideos
    case photosOnly
    case videosOnly

    public var id: String { rawValue }

    public func includes(_ mediaKind: MediaKind) -> Bool {
        switch (self, mediaKind) {
        case (.photosAndVideos, .photo), (.photosAndVideos, .video):
            return true
        case (.photosOnly, .photo):
            return true
        case (.videosOnly, .video):
            return true
        default:
            return false
        }
    }
}

public enum ImportOrganizationPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case classicDatedFolders
    case shootSessionsByDate
    case footageBackup

    public var id: String { rawValue }
}

public enum ImportFolderGrouping: String, Codable, CaseIterable, Identifiable, Sendable {
    case byDay
    case oneShootFolder

    public var id: String { rawValue }
}

public enum ImportWorkflowProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case photoImport
    case footageBackup
    case mixedShootSession

    public var id: String { rawValue }

    public var mediaSelection: ImportMediaSelection {
        switch self {
        case .photoImport:
            return .photosOnly
        case .footageBackup:
            return .videosOnly
        case .mixedShootSession:
            return .photosAndVideos
        }
    }

    public var organizationPreset: ImportOrganizationPreset {
        switch self {
        case .photoImport:
            return .classicDatedFolders
        case .footageBackup:
            return .footageBackup
        case .mixedShootSession:
            return .shootSessionsByDate
        }
    }

    public var includesSidecarsByDefault: Bool {
        false
    }

    public static func matching(
        mediaSelection: ImportMediaSelection,
        organizationPreset: ImportOrganizationPreset
    ) -> ImportWorkflowProfile? {
        allCases.first {
            $0.mediaSelection == mediaSelection
                && $0.organizationPreset == organizationPreset
        }
    }

    public func isCompatible(photoCount: Int, videoCount: Int) -> Bool {
        switch self {
        case .photoImport:
            return photoCount > 0
        case .footageBackup:
            return videoCount > 0
        case .mixedShootSession:
            return photoCount > 0 && videoCount > 0
        }
    }
}

public enum RecommendationConfidence: String, Codable, Sendable {
    case exact
    case dominant
    case mixed
    case remembered
    case empty
}

public struct MediaContentProfile: Equatable, Sendable {
    public let photoCount: Int
    public let videoCount: Int
    public let sidecarCount: Int
    public let unsupportedCount: Int
    public let recommendedWorkflow: ImportWorkflowProfile
    public let confidence: RecommendationConfidence

    public init(
        photoCount: Int,
        videoCount: Int,
        sidecarCount: Int,
        unsupportedCount: Int,
        recommendedWorkflow: ImportWorkflowProfile,
        confidence: RecommendationConfidence
    ) {
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.sidecarCount = sidecarCount
        self.unsupportedCount = unsupportedCount
        self.recommendedWorkflow = recommendedWorkflow
        self.confidence = confidence
    }

    public var supportedCount: Int {
        photoCount + videoCount
    }
}

public struct JobFilePlanUpdate: Sendable {
    public let id: Int64
    public let decision: FileDecision
    public let destinationDirectory: String?
    public let plannedDestinationPath: String?
    public let copyStatus: CopyStatus
    public let error: String?

    public init(
        id: Int64,
        decision: FileDecision,
        destinationDirectory: String?,
        plannedDestinationPath: String?,
        copyStatus: CopyStatus,
        error: String?
    ) {
        self.id = id
        self.decision = decision
        self.destinationDirectory = destinationDirectory
        self.plannedDestinationPath = plannedDestinationPath
        self.copyStatus = copyStatus
        self.error = error
    }
}
