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
