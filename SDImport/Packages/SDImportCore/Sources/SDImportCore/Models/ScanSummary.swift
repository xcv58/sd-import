import Foundation

public struct ScanSummary: Hashable, Codable, Sendable {
    public let jobID: String
    public let mountPath: String
    public let volumeName: String?
    public let volumeUUID: String?
    public let location: String
    public let scannedFiles: Int
    public let newFiles: Int
    public let knownFiles: Int
    public let unsupportedFiles: Int
    public let conflictFiles: Int

    public init(
        jobID: String,
        mountPath: String,
        volumeName: String?,
        volumeUUID: String?,
        location: String,
        scannedFiles: Int,
        newFiles: Int,
        knownFiles: Int,
        unsupportedFiles: Int,
        conflictFiles: Int
    ) {
        self.jobID = jobID
        self.mountPath = mountPath
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.location = location
        self.scannedFiles = scannedFiles
        self.newFiles = newFiles
        self.knownFiles = knownFiles
        self.unsupportedFiles = unsupportedFiles
        self.conflictFiles = conflictFiles
    }
}
