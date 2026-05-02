import Foundation

public struct JobFileRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: Int64?
    public let jobID: String
    public let sourcePath: String
    public let relativePath: String?
    public let filename: String
    public let ext: String
    public let size: Int64
    public let modificationDateString: String
    public let mediaKind: MediaKind
    public let fingerprint: String?
    public let captureDate: String?
    public let decision: FileDecision
    public let destinationDirectory: String?
    public let plannedDestinationPath: String?
    public let finalDestinationPath: String?
    public let copyStatus: CopyStatus
    public let error: String?
    public let completedAt: Date?

    public init(
        id: Int64? = nil,
        jobID: String,
        sourcePath: String,
        relativePath: String?,
        filename: String,
        ext: String,
        size: Int64,
        modificationDateString: String,
        mediaKind: MediaKind,
        fingerprint: String?,
        captureDate: String?,
        decision: FileDecision,
        destinationDirectory: String?,
        plannedDestinationPath: String?,
        finalDestinationPath: String? = nil,
        copyStatus: CopyStatus,
        error: String? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.filename = filename
        self.ext = ext
        self.size = size
        self.modificationDateString = modificationDateString
        self.mediaKind = mediaKind
        self.fingerprint = fingerprint
        self.captureDate = captureDate
        self.decision = decision
        self.destinationDirectory = destinationDirectory
        self.plannedDestinationPath = plannedDestinationPath
        self.finalDestinationPath = finalDestinationPath
        self.copyStatus = copyStatus
        self.error = error
        self.completedAt = completedAt
    }
}
