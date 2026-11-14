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
    public let modificationTimeEpochSeconds: Int64?
    public let mediaKind: MediaKind
    public let fingerprint: String?
    public let captureDate: String?
    public let decision: FileDecision
    public let knownSource: KnownFileSource?
    public let destinationDirectory: String?
    public let plannedDestinationPath: String?
    public let finalDestinationPath: String?
    public let copyStatus: CopyStatus
    public let error: String?
    public let portableReceiptOverride: Bool?
    public let completedAt: Date?

    public var isPendingImport: Bool {
        (decision == .new || decision == .conflict) && (copyStatus == .pending || copyStatus == .failed)
    }

    public init(
        id: Int64? = nil,
        jobID: String,
        sourcePath: String,
        relativePath: String?,
        filename: String,
        ext: String,
        size: Int64,
        modificationDateString: String,
        modificationTimeEpochSeconds: Int64? = nil,
        mediaKind: MediaKind,
        fingerprint: String?,
        captureDate: String?,
        decision: FileDecision,
        knownSource: KnownFileSource? = nil,
        destinationDirectory: String?,
        plannedDestinationPath: String?,
        finalDestinationPath: String? = nil,
        copyStatus: CopyStatus,
        error: String? = nil,
        portableReceiptOverride: Bool? = nil,
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
        self.modificationTimeEpochSeconds = modificationTimeEpochSeconds
        self.mediaKind = mediaKind
        self.fingerprint = fingerprint
        self.captureDate = captureDate
        self.decision = decision
        self.knownSource = knownSource
        self.destinationDirectory = destinationDirectory
        self.plannedDestinationPath = plannedDestinationPath
        self.finalDestinationPath = finalDestinationPath
        self.copyStatus = copyStatus
        self.error = error
        self.portableReceiptOverride = portableReceiptOverride
        self.completedAt = completedAt
    }
}
